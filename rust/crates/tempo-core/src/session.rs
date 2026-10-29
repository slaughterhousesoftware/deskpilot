//! The desk model between polls: the log so far, its clock, the live-move tracker, and
//! what today looks like. Pure: the service feeds it what it read and when, and asks it
//! what to read next and what to publish.

use jiff::tz::TimeZone;
use jiff::{SignedDuration, Timestamp};

use crate::clock::{HistoryClock, Observation as ClockObservation, ResyncReason};
use crate::coast::{CoastModel, Prediction};
use crate::history::{date_entries, decode_entries, Event, EventKind, RawEntry};
use crate::merge::merge_observed_moves;
use crate::model::{HistoryDocument, Settings};
use crate::motion::{MotionTracker, Observation as MotionObservation, ObservedMove};
use crate::registers::{addr, MINUTE_WRAP};
use crate::rollup::{self, CancelReason, CancelledMove, NextMove, RollupInput, TodayStats};
use crate::store::LiveCountdown;
use crate::time::{iso8601_seconds, minutes, seconds};

/// Seconds from reading the desk's COUNTDOWN entry to the motor starting. With the log read
/// every second: 13.2, ~14, ~14.5, ~14.5 and ~14.7 over five cycles on 2026-09-08/09, and
/// 14.3 on 2026-09-11 21:56 (the motor had already moved 1.1 in by the first moving
/// sample): the desk's 15 s countdown less the read latency. The last minute is read every
/// 0.3 s, so the entry is caught within ~0.15 s of being written, and 14.1 puts the zero on
/// the motor. The "countdown to motor" log line measures every cycle for tuning.
pub const COUNTDOWN_ENTRY_TO_MOTOR: SignedDuration = SignedDuration::from_millis(14_100);

/// How long past the announced motor time the announcement is still shown (as "now")
/// before it is treated as waved off: the move is then `CancelledMove`, and the interval
/// estimate takes back over. The motor has started 13.2-14.7 s after the entry was read
/// over every cycle measured, i.e. within 0.6 s of `COUNTDOWN_ENTRY_TO_MOTOR`, and the
/// status register is read every quarter second while a move is announced
/// (`status_poll_fast`), so four seconds of nothing is conclusive. It was 15 s until
/// 2026-10-29, which left "now" on screen for a quarter of a minute after a wave-off.
pub const ANNOUNCEMENT_GRACE: SignedDuration = seconds(4);

/// How long a cancelled move stays in `TodayStats` after it was concluded, for the menu bar
/// to show, before the countdown has the space back: long enough to be seen, not so long it
/// outstays the thing it confirms (two minutes did). The session owns this
/// lifetime so every reader drops the badge at the same moment, on the frame that drops it,
/// with no clock arithmetic of its own to disagree about. (The Swift `CancelledMove.displaySeconds`
/// mirrors it only as a guard against a stale frame.)
pub const CANCELLED_SHOWN_FOR: SignedDuration = seconds(5);

/// How long after an announcement a motor start that ends in the same posture still counts
/// as that move being reversed (the beep is 15 s and the travel ~8 s).
const REVERSAL_WINDOW: SignedDuration = seconds(45);

/// Observed moves older than this are dropped: only the last day matters to the countdown.
const OBSERVED_MOVE_RETENTION: SignedDuration = SignedDuration::from_hours(24);
/// How old a countdown read live may be and still be restored after a restart as the
/// desk's current one: longer than any cruise interval the desk offers.
const LIVE_COUNTDOWN_RETENTION: SignedDuration = SignedDuration::from_hours(2);

#[derive(Clone, Debug)]
pub struct SessionConfig {
    /// Chunks of 20 bytes per burst request. The phone app reads the log 100 bytes at a time.
    pub burst_chunks_per_request: usize,
    pub settle_grace: SignedDuration,
    pub countdown_entry_to_motor: SignedDuration,
    pub announcement_grace: SignedDuration,
    pub tz: TimeZone,
}

impl Default for SessionConfig {
    fn default() -> Self {
        Self {
            burst_chunks_per_request: 5,
            settle_grace: seconds(1),
            countdown_entry_to_motor: COUNTDOWN_ENTRY_TO_MOTOR,
            announcement_grace: ANNOUNCEMENT_GRACE,
            tz: TimeZone::system(),
        }
    }
}

/// One burst read to perform. The desk ignores the low two bits of a burst address and
/// always starts at the address rounded down to a multiple of 4 (docs/protocol.md,
/// "Register access"), so a read for `start` is requested from `address` and the first
/// `lead` bytes of the response are dropped; `usable` bytes after them are new log.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Burst {
    pub address: u32,
    pub chunks: usize,
    pub lead: usize,
    pub usable: usize,
}

impl Burst {
    pub const fn expected_bytes(&self) -> usize {
        self.chunks * 20
    }

    /// The new bytes within one response.
    pub fn slice<'a>(&self, data: &'a [u8]) -> &'a [u8] {
        let end = (self.lead + self.usable).min(data.len());
        &data[self.lead.min(end)..end]
    }
}

/// The bursts that read `[start, write_pointer)` of the history ring.
pub fn plan_bursts(start: usize, write_pointer: usize, chunks_per_request: usize) -> Vec<Burst> {
    let mut bursts = Vec::new();
    let mut start = start;
    while start < write_pointer {
        let aligned = start & !3;
        let lead = start - aligned;
        let remaining = write_pointer - start;
        let chunks = chunks_per_request
            .min((remaining + lead).div_ceil(20))
            .max(1);
        let usable = remaining.min(chunks * 20 - lead);
        bursts.push(Burst {
            address: addr::HISTORY_BASE + aligned as u32,
            chunks,
            lead,
            usable,
        });
        start += usable;
    }
    bursts
}

/// What a history poll's first half decided.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HistoryPoll {
    pub resync: Option<ResyncReason>,
    pub phase_locked: bool,
    pub bursts: Vec<Burst>,
}

/// What ingesting new bytes produced.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct Ingest {
    pub entries: usize,
    /// A COUNTDOWN entry stamped with the desk's current (or just-ended) minute arrived as
    /// new bytes: the desk is beeping right now.
    pub live_countdown: bool,
    pub reanchored: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct StatusNote {
    pub observation: MotionObservation,
    /// The observed-move list changed and should be persisted.
    pub moves_changed: bool,
    /// Where the desk is going to stop, while it moves or coasts.
    pub prediction: Option<Prediction>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Recompute {
    pub today: TodayStats,
    /// The merged event count changed since the last recompute.
    pub history_changed: bool,
}

#[derive(Clone, Debug)]
pub struct DeskSession {
    cfg: SessionConfig,
    raw_entries: Vec<RawEntry>,
    history_bytes_read: usize,
    clock: HistoryClock,
    tracker: MotionTracker,
    coast: CoastModel,
    /// The last announced move the user cancelled, until the desk announces or moves again.
    cancelled: Option<CancelledMove>,
    observed_moves: Vec<Event>,
    observed_revision: u64,
    /// The desk's most recent COUNTDOWN entry, dated by when it was *read*: the desk writes
    /// it when it starts beeping and the log is read every 0.3 s around a predicted move, so
    /// this is the beep's start to within a fraction of a second. Cleared by the move it
    /// announces.
    last_countdown_seen: Option<(Timestamp, bool)>,
    dated: Vec<Event>,
    dated_key: Option<(usize, u32, Timestamp, u32)>,
    merged: Vec<Event>,
    merged_key: Option<((usize, u32, Timestamp, u32), u64)>,
    merged_count_published: usize,
    last_today: Option<TodayStats>,
}

impl DeskSession {
    pub fn new(cfg: SessionConfig) -> Self {
        let tracker = MotionTracker::new(cfg.settle_grace);
        Self {
            cfg,
            raw_entries: Vec::new(),
            history_bytes_read: 0,
            clock: HistoryClock::new(),
            tracker,
            coast: CoastModel::new(),
            cancelled: None,
            observed_moves: Vec::new(),
            observed_revision: 0,
            last_countdown_seen: None,
            dated: Vec::new(),
            dated_key: None,
            merged: Vec::new(),
            merged_key: None,
            merged_count_published: 0,
            last_today: None,
        }
    }

    pub const fn config(&self) -> &SessionConfig {
        &self.cfg
    }

    pub fn decoded_entry_count(&self) -> usize {
        self.raw_entries.len()
    }

    pub const fn history_bytes_read(&self) -> usize {
        self.history_bytes_read
    }

    pub fn observed_moves(&self) -> &[Event] {
        &self.observed_moves
    }

    pub const fn tracker(&self) -> &MotionTracker {
        &self.tracker
    }

    pub const fn coast(&self) -> &CoastModel {
        &self.coast
    }

    pub const fn cancelled(&self) -> Option<CancelledMove> {
        self.cancelled
    }

    pub const fn clock(&self) -> &HistoryClock {
        &self.clock
    }

    pub const fn last_countdown_seen(&self) -> Option<(Timestamp, bool)> {
        self.last_countdown_seen
    }

    /// Re-anchors the history clock to the wall clock (register 32 just read as `minutes`).
    pub fn anchor_clock(&mut self, minutes: u32, now: Timestamp) {
        self.clock.anchor(minutes, now);
        tracing::info!(minutes, date = %iso8601_seconds::format(now), "anchor");
    }

    /// Drops everything derived from the current boot session's log, including the
    /// live-move bookkeeping: after a reconnect or a power cycle we no longer know what the
    /// desk did while we were away, and the next status poll re-establishes the posture.
    pub fn forget(&mut self) {
        self.raw_entries.clear();
        self.history_bytes_read = 0;
        self.observed_moves.clear();
        self.observed_revision += 1;
        self.tracker.forget();
        self.coast.forget_motion();
        self.last_countdown_seen = None;
        self.cancelled = None;
    }

    /// After the link dropped and came back without the desk rebooting (a reboot is caught
    /// by the next history poll, which then forgets everything): the log position, the
    /// moves seen live, the latest countdown and a cancel all still hold - a reconnect a
    /// minute after a wave-off used to lose the cancel, and with it the restarted timer,
    /// until the log's resolution window passed. Only the motion tracking starts over: the
    /// desk may have moved while the link was down.
    pub fn reconnected(&mut self) {
        self.tracker.forget();
        self.coast.forget_motion();
    }

    /// The latest countdown as read live, with its cancel, for a restart to pick up.
    pub fn live_countdown(&self) -> Option<LiveCountdown> {
        let (seen_at, to_standing) = self.last_countdown_seen?;
        Some(LiveCountdown {
            seen_at,
            to_standing,
            cancelled_at: self.cancelled.map(|c| c.at),
            reversed: self.cancelled.is_some_and(|c| c.reason == CancelReason::Reversed),
        })
    }

    /// Brings back the countdown read live before the last restart, if it is recent enough
    /// to still be the desk's current one, so the countdown keeps its anchor - and a cancel
    /// is neither lost nor reported a second time.
    pub fn restore_countdown(&mut self, countdown: LiveCountdown, now: Timestamp) {
        if now.duration_since(countdown.seen_at) > LIVE_COUNTDOWN_RETENTION
            || self.last_countdown_seen.is_some()
        {
            return;
        }
        tracing::info!(seen_at = %iso8601_seconds::format(countdown.seen_at), cancelled = countdown.cancelled_at.is_some(), "restored live countdown");
        self.last_countdown_seen = Some((countdown.seen_at, countdown.to_standing));
        self.cancelled = countdown.cancelled_at.map(|at| CancelledMove {
            at,
            to_standing: countdown.to_standing,
            reason: if countdown.reversed { CancelReason::Reversed } else { CancelReason::WavedOff },
        });
    }

    /// Brings back the moves observed live before the last restart, so the countdown keeps
    /// its second-accurate anchor instead of falling back to the log's minute stamps. Only
    /// the last day is kept.
    pub fn restore_observed_moves(&mut self, moves: Vec<Event>, now: Timestamp) {
        let cutoff = now - OBSERVED_MOVE_RETENTION;
        let restored: Vec<Event> = moves.into_iter().filter(|m| m.date >= cutoff).collect();
        if restored.is_empty() {
            return;
        }
        tracing::info!(count = restored.len(), "restored observed moves");
        self.observed_moves = restored;
        self.observed_revision += 1;
    }

    /// First half of a history poll: registers 44 and 32 were just read. Detects a reboot
    /// (and forgets the old session), phase-locks the clock on the first observed tick, and
    /// plans the bursts needed to read what is new. Returns `resync` so the caller can clear
    /// its persisted observed moves: the desk's timer restarted with the reboot.
    pub fn begin_history_poll(
        &mut self,
        minutes: u32,
        write_pointer: usize,
        now: Timestamp,
    ) -> HistoryPoll {
        let ClockObservation {
            resync,
            phase_locked,
        } = self
            .clock
            .observe(minutes, write_pointer, self.history_bytes_read, now);
        if let Some(reason) = resync {
            tracing::info!(
                ?reason,
                ptr = write_pointer,
                read = self.history_bytes_read,
                minutes,
                "history resync"
            );
            self.forget();
        }
        if phase_locked {
            tracing::info!(minutes, anchor = %iso8601_seconds::format(self.clock.anchor_date()), "phase lock");
        }
        let bursts = plan_bursts(
            self.history_bytes_read,
            write_pointer,
            self.cfg.burst_chunks_per_request,
        );
        HistoryPoll {
            resync,
            phase_locked,
            bursts,
        }
    }

    /// Second half: the bytes the planned bursts collected, `[history_bytes_read, write_pointer)`.
    pub fn ingest(&mut self, collected: &[u8], write_pointer: usize, now: Timestamp) -> Ingest {
        let mut out = Ingest::default();
        if !collected.is_empty() && write_pointer > self.history_bytes_read {
            // Entries arriving on the very first read of a session are the whole log, not
            // news: a countdown the desk wrote an hour ago must not start a timer now.
            let initial = self.history_bytes_read == 0;
            let decoded = decode_entries(collected, self.history_bytes_read);
            let minutes = self.clock.latest_minutes();
            let current = (minutes % MINUTE_WRAP) as u8;
            let last = ((minutes + MINUTE_WRAP - 1) % MINUTE_WRAP) as u8;
            for entry in &decoded {
                if !initial && (entry.minute_byte == current || entry.minute_byte == last) {
                    if let EventKind::Countdown { to_standing } = entry.kind {
                        self.last_countdown_seen = Some((now, to_standing));
                        self.cancelled = None;
                        out.live_countdown = true;
                    }
                }
            }
            let described: Vec<String> = decoded.iter().map(describe).collect();
            tracing::info!(ptr = write_pointer, read = self.history_bytes_read, bytes = collected.len(), entries = %described.join(","), "history ingest");
            out.entries = decoded.len();
            self.raw_entries.extend(decoded);
            // Keep the byte position even: a trailing odd byte is re-read with its partner.
            self.history_bytes_read += collected.len() & !1;
        }
        // New entries changed what "now" means for the timeline, so re-anchoring would
        // normally be correct, except that it shifts every event by the seconds-of-minute
        // jitter; keep the anchor until it is nearly stale.
        if self.clock.is_stale(now) {
            self.anchor_clock(self.clock.latest_minutes(), now);
            out.reanchored = true;
        }
        out
    }

    /// One status sample. `wall` must always advance (settle timing); `now` dates moves.
    pub fn note_status(
        &mut self,
        word: crate::registers::StatusWord,
        settings: Option<&Settings>,
        now: Timestamp,
        wall: Timestamp,
    ) -> StatusNote {
        let presets = settings.map(Settings::presets);
        let observation = self.tracker.observe(word, presets, now, wall);
        if let Some(travelled) = observation.motor_started {
            // How the desk's countdown actually ran, for tuning `COUNTDOWN_ENTRY_TO_MOTOR`:
            // the motor started before this sample by however far the height has already
            // moved (the desk travels ~1.5 in/s, 15 tenths per second). Only for an entry
            // read this cycle; a dismissed one lingers until the next observed move.
            if let Some((seen_at, _)) = self
                .last_countdown_seen
                .filter(|(at, _)| now.duration_since(*at) < seconds(60))
            {
                let started = now - SignedDuration::from_secs_f64(f64::from(travelled) / 15.0);
                tracing::info!(
                    after_entry_s = format!("{:.2}", started.duration_since(seen_at).as_secs_f64()),
                    sample_s = format!("{:.2}", now.duration_since(seen_at).as_secs_f64()),
                    travelled,
                    "countdown to motor"
                );
            }
        }
        let mut moves_changed = false;
        if let Some(moved) = observation.moved {
            self.record_observed_move(moved, now);
            moves_changed = true;
        }
        if observation.aborted {
            // The motor ran during an announced move and the posture didn't change: the
            // user reversed it before it reached the other preset.
            if let Some((seen_at, to_standing)) = self
                .last_countdown_seen
                .filter(|(at, _)| now.duration_since(*at) < REVERSAL_WINDOW)
            {
                if self.cancelled.is_none() {
                    tracing::info!(
                        after_entry_s = format!("{:.1}", now.duration_since(seen_at).as_secs_f64()),
                        to_standing,
                        "announced move reversed"
                    );
                    self.cancelled = Some(CancelledMove {
                        at: now,
                        to_standing,
                        reason: CancelReason::Reversed,
                    });
                }
            }
        }
        let (prediction, lesson) = self.coast.observe(word, wall);
        if let Some(lesson) = lesson {
            tracing::info!(
                direction = ?lesson.direction,
                released = lesson.released_at_tenths,
                settled = lesson.settled_tenths,
                coast = lesson.coast_tenths,
                predicted = lesson.predicted_tenths,
                error = i32::from(lesson.predicted_tenths) - i32::from(lesson.settled_tenths),
                speed = lesson.speed_tenths_per_s.map(|v| format!("{v:.1}")),
                model = self.coast.describe(),
                "coast"
            );
        }
        StatusNote {
            observation,
            moves_changed,
            prediction,
        }
    }

    /// True while the desk is announcing a move (or should be about to move): the status
    /// register deserves the moving cadence so the motor start, or its absence, is seen at
    /// once rather than up to a second late.
    pub fn status_poll_fast(&self, now: Timestamp) -> bool {
        self.last_countdown_seen.is_some_and(|(seen_at, _)| {
            let elapsed = now.duration_since(seen_at);
            elapsed >= SignedDuration::ZERO
                && elapsed
                    < self.cfg.countdown_entry_to_motor + self.cfg.announcement_grace + seconds(2)
        })
    }

    fn record_observed_move(&mut self, moved: ObservedMove, now: Timestamp) {
        self.last_countdown_seen = None;
        self.cancelled = None;
        self.observed_moves
            .retain(|m| m.date >= now - OBSERVED_MOVE_RETENTION);
        self.observed_moves.push(Event::synthetic(
            moved.at,
            EventKind::Move {
                to_standing: moved.to_standing,
            },
        ));
        self.observed_revision += 1;
        tracing::info!(
            to = if moved.to_standing {
                "standing"
            } else {
                "sitting"
            },
            height = moved.settled_height,
            prev = moved.previous_height,
            settled = moved.settled,
            jumped = moved.jumped,
            "observed move"
        );
    }

    fn dated_events(&mut self) -> &[Event] {
        let key = (
            self.raw_entries.len(),
            self.clock.anchor_minutes(),
            self.clock.anchor_date(),
            self.clock.latest_minutes(),
        );
        if self.dated_key != Some(key) {
            // Event dates come from the fixed anchor, so they stay put between polls; only
            // the rollup's "now" advances. `date_entries` walks backward assuming every entry
            // is at or before its reference minute, so dating against the pinned anchor
            // would misdate by a 256-minute wrap any entry stamped after the anchor was
            // taken; projecting the anchor forward by the counter's ticks fixes that while
            // leaving already-dated entries untouched.
            self.dated = date_entries(
                &self.raw_entries,
                self.clock.latest_minutes(),
                self.clock.projected_now(),
            );
            self.dated_key = Some(key);
        }
        &self.dated
    }

    /// The merged timeline: the log's events plus the live-detected moves, duplicates
    /// dropped once the log catches up. Cached until the log, the clock or the observed
    /// moves change.
    pub fn merged_events(&mut self) -> &[Event] {
        let key = (
            self.raw_entries.len(),
            self.clock.anchor_minutes(),
            self.clock.anchor_date(),
            self.clock.latest_minutes(),
        );
        let merged_key = (key, self.observed_revision);
        if self.merged_key != Some(merged_key) {
            self.dated_events();
            self.merged = merge_observed_moves(&self.dated, &self.observed_moves);
            self.merged_key = Some(merged_key);
        }
        &self.merged
    }

    /// When the app read the desk's latest COUNTDOWN entry live and then watched the motor
    /// not start: `last_countdown_seen` is only cleared by an observed move, so one still
    /// standing past the announcement grace (with no motion under way) is a countdown the
    /// user waved off.
    fn dismissed_countdown_at(&mut self, now: Timestamp, is_moving: bool) -> Option<Timestamp> {
        let (seen_at, to_standing) = self.last_countdown_seen?;
        let elapsed = now.duration_since(seen_at);
        let dismissed = self.tracker.motion_started_at().is_none()
            && !is_moving
            && elapsed >= self.cfg.countdown_entry_to_motor + self.cfg.announcement_grace;
        if dismissed && self.cancelled.is_none() {
            tracing::info!(
                after_entry_s = format!("{:.1}", elapsed.as_secs_f64()),
                to_standing,
                "announced move waved off"
            );
            self.cancelled = Some(CancelledMove {
                at: now,
                to_standing,
                reason: CancelReason::WavedOff,
            });
        }
        dismissed.then_some(seen_at)
    }

    /// Today's numbers from the merged timeline, the live height and the live countdown.
    pub fn recompute(
        &mut self,
        now: Timestamp,
        settings: &Settings,
        height_tenths: Option<u16>,
        is_moving: bool,
    ) -> Recompute {
        let dismissed_countdown_at = self.dismissed_countdown_at(now, is_moving);
        let presets = settings.presets();
        let threshold = presets.standing_threshold_inches();
        let day_start = rollup::day_start(now, &self.cfg.tz, settings.middle_of_night_hour);
        let cruise = settings.active_cruise();
        let paused = settings.paused();
        let entry_to_motor = self.cfg.countdown_entry_to_motor;
        let grace = self.cfg.announcement_grace;
        let last_countdown_seen = self.last_countdown_seen;
        let observed_count = self.observed_moves.len();
        let previous_count = self.merged_count_published;
        let events = self.merged_events();
        // A logged move only gets to set the posture live readings are compared against
        // once it has taken its place in the merged, date-sorted timeline: otherwise a log
        // entry older than a move already observed live would overwrite the known posture
        // with a stale value and the next genuine live move would be skipped.
        let last_logged_posture = events.iter().rev().find_map(|e| match e.kind {
            EventKind::Move { to_standing } => Some(to_standing),
            _ => None,
        });
        let mut today = rollup::compute(RollupInput {
            events,
            now,
            day_start,
            cruise,
            paused,
            standing_threshold_inches: threshold,
            dismissed_countdown_at,
        });
        let logged_moves = events.iter().filter(|e| e.kind.is_move()).count();
        let history_changed = events.len() != previous_count;
        self.merged_count_published = events.len();
        if let Some(posture) = last_logged_posture {
            self.tracker.set_known_posture(posture);
        }
        // The timeline says what the desk last *did*; the status register says where it
        // *is*. When they disagree (the user lowered the desk by hand after an automatic
        // stand) trust the live height. `next_move` stays timeline-based.
        if let Some(posture) = height_tenths.and_then(|h| presets.posture(h)) {
            today.is_standing = Some(posture);
        }
        // The desk has announced the move: its own timing takes over from the estimate,
        // while it is still the move the rollup expects and recent. It expires
        // `announcement_grace` after the motor was due: a waved-off countdown must not
        // leave "now" on screen.
        if let (Some((seen_at, to_standing)), Some(next)) = (last_countdown_seen, today.next_move) {
            if next.to_standing == to_standing
                && !is_moving
                && self.cancelled.is_none()
                && now.duration_since(seen_at) < entry_to_motor + grace
            {
                today.next_move = Some(NextMove::announced(
                    seen_at + entry_to_motor,
                    to_standing,
                    seen_at,
                ));
            }
        }
        // The finding is kept (so it is never reported twice, and a restart can restore it);
        // what is shown expires.
        today.cancelled_move = self
            .cancelled
            .filter(|c| now.duration_since(c.at) < CANCELLED_SHOWN_FOR);
        if self.last_today.map(|t| (t.stands, t.next_move)) != Some((today.stands, today.next_move))
        {
            tracing::info!(
                stands = today.stands,
                standing = ?today.is_standing,
                next = today.next_move.map(|n| iso8601_seconds::format(n.at)).unwrap_or_else(|| "nil".into()),
                to_standing = ?today.next_move.map(|n| n.to_standing),
                merged_moves = logged_moves,
                observed = observed_count,
                "today"
            );
        }
        self.last_today = Some(today);
        Recompute {
            today,
            history_changed,
        }
    }

    /// The merged, dated history for dashboards: the same list `recompute` uses, the
    /// standing threshold in whole inches, and the middle-of-night hour.
    pub fn history_document(&mut self, now: Timestamp, settings: &Settings) -> HistoryDocument {
        let threshold = settings.standing_threshold_inches();
        let events = self.merged_events().to_vec();
        HistoryDocument {
            written_at: now,
            standing_threshold_inches: threshold,
            middle_of_night_hour: settings.middle_of_night_hour,
            events,
        }
    }

    /// The history poll cadence the timeline calls for, given the base interval. The desk
    /// writes its COUNTDOWN entry when it starts beeping, ~15 s before it moves, so around
    /// the predicted move the log is read far more often: every 1 s from ten minutes ahead
    /// (the desk holds its timer for absences it never logs, so an overdue estimate stays
    /// overdue for as long as it likes) and every 0.3 s inside the last minute and for as
    /// long as it runs overdue (a 1 s cadence put the timer up to a second behind the beep).
    pub fn history_poll_interval(
        today: Option<&TodayStats>,
        is_moving: bool,
        now: Timestamp,
        base: SignedDuration,
    ) -> SignedDuration {
        let Some(next) = today.and_then(|t| t.next_move).filter(|_| !is_moving) else {
            return base;
        };
        let until = next.at.duration_since(now);
        if until < seconds(60) {
            SignedDuration::from_millis(300).min(base)
        } else if until < minutes(10) {
            seconds(1).min(base)
        } else {
            base
        }
    }
}

/// `t<minute>:<kind>` for diagnostics, e.g. `t33:countdown(down)`.
fn describe(entry: &RawEntry) -> String {
    let kind = match entry.kind {
        EventKind::Presence { present } => {
            format!("presence({})", if present { "present" } else { "absent" })
        }
        EventKind::Countdown { to_standing } => {
            format!("countdown({})", if to_standing { "up" } else { "down" })
        }
        EventKind::Move { to_standing } => {
            format!("move({})", if to_standing { "up" } else { "down" })
        }
        EventKind::HeightChange { inches } => format!("height({inches})"),
        EventKind::UserChange { user } => format!("user({user})"),
        EventKind::Nop { raw } => format!("nop({raw})"),
    };
    format!("t{}:{kind}", entry.minute_byte)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cruise::CruiseSlot;
    use crate::registers::StatusWord;
    use crate::rollup::{CancelReason, MOVE_LEAD};

    fn now() -> Timestamp {
        Timestamp::from_second(1_800_000_000).unwrap()
    }

    fn settings() -> Settings {
        Settings {
            firmware: "1.0.5".into(),
            user_index: 0,
            flags: 0x1E3,
            active_cruise_slot: 1,
            cruise: Some(CruiseSlot::new(1200, 1200)),
            countdown_timing: None,
            middle_of_night_hour: 4,
            standing_height_tenths: 411,
            sitting_height_tenths: 266,
            custom_height_one_tenths: 0,
            custom_height_two_tenths: 0,
            user_name: None,
            preset_name_one: None,
            preset_name_two: None,
        }
    }

    /// An in-memory ring that serves bursts the way the desk does: aligned down to 4 bytes,
    /// zero-padded past the end.
    struct Ring {
        bytes: Vec<u8>,
        minutes: u32,
    }

    impl Ring {
        fn serve(&self, burst: &Burst) -> Vec<u8> {
            let start = (burst.address - addr::HISTORY_BASE) as usize;
            (0..burst.expected_bytes())
                .map(|i| self.bytes.get(start + i).copied().unwrap_or(0))
                .collect()
        }
    }

    struct Harness {
        session: DeskSession,
        ring: Ring,
        settings: Settings,
    }

    impl Harness {
        fn new(bytes: &[u8], minutes: u32) -> Self {
            let mut h = Harness {
                session: DeskSession::new(SessionConfig {
                    tz: TimeZone::UTC,
                    ..Default::default()
                }),
                ring: Ring {
                    bytes: bytes.to_vec(),
                    minutes,
                },
                settings: settings(),
            };
            h.session.anchor_clock(minutes, now());
            h.poll(now());
            h
        }

        fn poll(&mut self, at: Timestamp) -> (HistoryPoll, Ingest) {
            let plan =
                self.session
                    .begin_history_poll(self.ring.minutes, self.ring.bytes.len(), at);
            let mut collected = Vec::new();
            for burst in &plan.bursts {
                let data = self.ring.serve(burst);
                collected.extend_from_slice(burst.slice(&data));
            }
            let ingest = self.session.ingest(&collected, self.ring.bytes.len(), at);
            (plan, ingest)
        }

        fn append(&mut self, bytes: &[u8]) {
            self.ring.bytes.extend_from_slice(bytes);
        }

        fn status(&mut self, raw: u32, at: Timestamp) -> StatusNote {
            self.session
                .note_status(StatusWord::from_raw(raw), Some(&self.settings), at, at)
        }

        fn today(&mut self, at: Timestamp, height: Option<u16>, moving: bool) -> TodayStats {
            self.session
                .recompute(at, &self.settings, height, moving)
                .today
        }
    }

    #[test]
    fn plan_bursts_aligns_down_and_drops_the_lead() {
        assert_eq!(
            plan_bursts(0, 4, 5),
            [Burst {
                address: addr::HISTORY_BASE,
                chunks: 1,
                lead: 0,
                usable: 4
            }]
        );
        assert_eq!(
            plan_bursts(6, 8, 5),
            [Burst {
                address: addr::HISTORY_BASE + 4,
                chunks: 1,
                lead: 2,
                usable: 2
            }]
        );
        let big = plan_bursts(0, 250, 5);
        assert_eq!(big.len(), 3);
        assert_eq!(
            big[0],
            Burst {
                address: addr::HISTORY_BASE,
                chunks: 5,
                lead: 0,
                usable: 100
            }
        );
        assert_eq!(
            big[2],
            Burst {
                address: addr::HISTORY_BASE + 200,
                chunks: 3,
                lead: 0,
                usable: 50
            }
        );
        assert!(plan_bursts(8, 8, 5).is_empty());
        let burst = Burst {
            address: 0,
            chunks: 1,
            lead: 2,
            usable: 2,
        };
        assert_eq!(burst.slice(&[1, 2, 3, 4, 5, 6]), [3, 4]);
    }

    #[test]
    fn connect_reads_history_and_live_height_wins_posture() {
        let mut h = Harness::new(&[0xE7, 0x51, 0xE7, 0x5D], 5883);
        assert_eq!(h.session.decoded_entry_count(), 2);
        let today = h.today(now(), Some(267), false);
        assert_eq!(today.stands, 1);
        assert_eq!(
            today.is_standing,
            Some(false),
            "the log says up, the desk is at 26.7 in: the live height wins"
        );
        assert!(today.is_present);
        assert_eq!(
            today.next_move,
            Some(NextMove::new(now() + MOVE_LEAD, false))
        );
        let standing = h.today(now(), Some(411), false);
        assert_eq!(standing.is_standing, Some(true));
        assert_eq!(
            standing.next_move, today.next_move,
            "next_move stays log-based"
        );
    }

    #[test]
    fn poll_picks_up_new_entries() {
        let mut h = Harness::new(&[0xE7, 0x51, 0xE7, 0x5D], 5883);
        h.append(&[0xFB, 0x5C]);
        let (_, ingest) = h.poll(now());
        assert_eq!(ingest.entries, 1);
        let today = h.today(now(), Some(267), false);
        assert_eq!(today.stands, 1);
        assert_eq!(
            today.next_move,
            Some(NextMove::new(now() + seconds(1200) + MOVE_LEAD, true))
        );
    }

    #[test]
    fn entries_newer_than_the_anchor_are_dated_forward() {
        let mut h = Harness::new(&[0xE7, 0x51, 0xE7, 0x5D], 5883);
        h.ring.minutes = 5885;
        h.append(&[0xFD, 0x5C]);
        h.poll(now() + seconds(130));
        let today = h.today(now() + seconds(130), Some(267), false);
        assert_eq!(
            today.next_move,
            Some(NextMove::new(
                now() + minutes(2) + seconds(1200) + MOVE_LEAD,
                true
            ))
        );
        assert_eq!(today.stands, 1);
        assert!((today.at_desk_seconds - seconds(1200 + 130)).abs() <= seconds(1));
    }

    #[test]
    fn incremental_read_is_aligned_to_four_bytes() {
        let mut h = Harness::new(&[0xE7, 0x51, 0xE7, 0x5D, 0xE8, 0x00], 5883);
        assert_eq!(h.session.history_bytes_read(), 6);
        h.append(&[0xFB, 0x5C]);
        let (plan, ingest) = h.poll(now());
        assert_eq!(
            plan.bursts,
            [Burst {
                address: addr::HISTORY_BASE + 4,
                chunks: 1,
                lead: 2,
                usable: 2
            }]
        );
        assert_eq!(ingest.entries, 1);
        let today = h.today(now(), Some(267), false);
        assert_eq!(
            today.stands, 1,
            "the pre-existing move up must not be decoded twice"
        );
        assert_eq!(today.next_move.map(|n| n.to_standing), Some(true));
    }

    #[test]
    fn odd_write_pointer_leaves_the_half_entry_for_the_next_poll() {
        let mut h = Harness::new(&[0xE7, 0x51, 0xE7], 5883);
        assert_eq!(h.session.decoded_entry_count(), 1);
        assert_eq!(h.session.history_bytes_read(), 2);
        h.append(&[0x5D]);
        let (_, ingest) = h.poll(now());
        assert_eq!(ingest.entries, 1);
        assert_eq!(h.today(now(), Some(411), false).stands, 1);
    }

    #[test]
    fn resyncs_when_the_desk_reboots() {
        let mut h = Harness::new(&[0xE7, 0x51, 0xE7, 0x5D], 5883);
        h.ring = Ring {
            bytes: vec![0x05, 0x40, 0x05, 0x51, 0x0A, 0x5C],
            minutes: 10,
        };
        let (plan, _) = h.poll(now() + seconds(5));
        assert_eq!(plan.resync, Some(ResyncReason::Minutes));
        let today = h.today(now() + seconds(5), Some(267), false);
        assert_eq!(
            today.stands, 0,
            "the pre-reboot standing entry must be discarded"
        );
        assert_eq!(
            today.next_move,
            Some(NextMove::new(
                now() + seconds(5) + seconds(1200) + MOVE_LEAD,
                true
            ))
        );
    }

    #[test]
    fn resync_with_an_empty_log_does_not_repeatedly_wipe_observed_moves() {
        let mut h = Harness::new(&[0xE7, 0x51, 0xE7, 0x5D], 5883);
        h.ring = Ring {
            bytes: vec![],
            minutes: 3,
        };
        assert!(h.poll(now()).0.resync.is_some());
        for i in 1..5 {
            assert_eq!(
                h.poll(now() + seconds(i)).0.resync,
                None,
                "only the first poll resyncs"
            );
        }
        h.status(0x010B, now());
        h.status(0x8000_0150, now() + seconds(1));
        h.status(0x019B, now() + seconds(2));
        assert!(h.status(0x019B, now() + seconds(3)).moves_changed);
        h.poll(now() + seconds(4));
        let today = h.today(now() + seconds(4), Some(411), false);
        assert_eq!(
            (today.is_standing, today.stands),
            (Some(true), 1),
            "the observed stand must survive the resync"
        );
    }

    #[test]
    fn next_move_anchor_is_stable_between_polls() {
        let mut h = Harness::new(&[0xE7, 0x51, 0xE7, 0x5D], 5883);
        let first = h.today(now(), Some(267), false);
        h.ring.minutes = 5884;
        h.poll(now() + seconds(30));
        let later = h.today(now() + seconds(30), Some(267), false);
        assert_eq!(
            later.next_move, first.next_move,
            "the countdown target must not move with the clock"
        );
        assert!((later.at_desk_seconds - first.at_desk_seconds - seconds(30)).abs() <= seconds(1));
    }

    #[test]
    fn observed_move_anchors_next_move_before_the_log_catches_up_then_dedupes() {
        let mut h = Harness::new(&[0xFB, 0x5C], 5883);
        let sitting = h.today(now(), Some(267), false);
        assert_eq!((sitting.stands, sitting.is_standing), (0, Some(false)));
        h.status(0x010B, now());
        h.status(0x8000_0150, now() + seconds(1));
        h.status(0x019B, now() + seconds(9));
        let note = h.status(0x019B, now() + seconds(10));
        assert!(note.moves_changed);
        let standing = h.today(now() + seconds(10), Some(411), false);
        assert_eq!((standing.stands, standing.is_standing), (1, Some(true)));
        let next = standing.next_move.unwrap();
        assert!(
            !next.to_standing,
            "the live stand must restart the sit countdown"
        );
        assert_eq!(
            next.at,
            now() + seconds(1) + seconds(1200) + MOVE_LEAD,
            "dated at the motor start"
        );

        // Minutes later the desk writes the move it already made, stamped with the current minute.
        h.append(&[0xFB, 0x59, 0xFB, 0x35, 0xFB, 0x5D]);
        h.poll(now() + seconds(60));
        let today = h.today(now() + seconds(60), Some(411), false);
        assert_eq!(
            today.stands, 1,
            "the logged move is the one already seen live"
        );
        assert_eq!(today.is_standing, Some(true));
        assert_eq!(today.next_move.map(|n| n.to_standing), Some(false));
        let doc = h.session.history_document(now() + seconds(60), &settings());
        assert_eq!(
            doc.events.iter().filter(|e| e.kind.is_move()).count(),
            2,
            "one logged sit, one merged stand"
        );
        assert_eq!(doc.standing_threshold_inches, Some(34));
        assert_eq!(doc.middle_of_night_hour, 4);
    }

    #[test]
    fn stale_logged_move_does_not_suppress_live_detection() {
        let mut h = Harness::new(&[0xE7, 0x51, 0xE7, 0x5D], 5883);
        h.today(now(), Some(267), false);
        h.status(0x010B, now());
        h.status(0x8000_0150, now() + seconds(1));
        h.status(0x019B, now() + seconds(2));
        h.status(0x019B, now() + seconds(3));
        assert_eq!(
            h.today(now() + seconds(3), Some(411), false).is_standing,
            Some(true)
        );
        h.status(0x8000_0150, now() + seconds(4));
        h.status(0x010A, now() + seconds(5));
        h.status(0x010A, now() + seconds(6));
        assert_eq!(
            h.today(now() + seconds(6), Some(266), false)
                .next_move
                .map(|n| n.to_standing),
            Some(true)
        );
        // The desk finally logs the stand, one minute stale.
        h.append(&[((5883 % 256) - 1) as u8, 0x5D]);
        h.poll(now() + seconds(7));
        h.today(now() + seconds(7), Some(266), false);
        // Well past the dedupe window, a fresh live stand must still be detected.
        let t = now() + seconds(300);
        h.status(0x8000_0150, t);
        h.status(0x019B, t + seconds(1));
        assert!(
            h.status(0x019B, t + seconds(2)).moves_changed,
            "the stale logged entry must not hide the live stand"
        );
        let today = h.today(t + seconds(2), Some(411), false);
        assert_eq!(today.is_standing, Some(true));
        let next = today.next_move.unwrap();
        assert!(!next.to_standing);
        assert_eq!(next.at, t + seconds(1200) + MOVE_LEAD);
    }

    #[test]
    fn countdown_entry_hands_timing_to_the_desk_until_the_move() {
        let mut h = Harness::new(&[0xE7, 0x51, 0xE7, 0x5D], 5883);
        h.today(now(), Some(411), false);
        h.status(0x019B, now());
        h.append(&[0xFB, 0x58]);
        let (_, ingest) = h.poll(now());
        assert!(ingest.live_countdown);
        let announced = h.today(now(), Some(411), false);
        assert_eq!(
            announced.next_move,
            Some(NextMove::announced(
                now() + COUNTDOWN_ENTRY_TO_MOTOR,
                false,
                now()
            ))
        );
        assert_eq!(announced.next_move.unwrap().announce_at(), now());
        // The motor starts 13 s later and the desk settles 8 s after that.
        h.status(0x8000_0150, now() + seconds(13));
        assert_eq!(
            h.today(now() + seconds(13), Some(336), true)
                .next_move
                .map(|n| n.is_announced()),
            Some(false),
            "not while moving"
        );
        h.status(0x010A, now() + seconds(21));
        h.status(0x010A, now() + seconds(22));
        let moved = h.today(now() + seconds(22), Some(266), false);
        assert_eq!(
            moved.next_move,
            Some(NextMove::new(
                now() + seconds(13) + seconds(1200) + MOVE_LEAD,
                true
            ))
        );
    }

    #[test]
    fn dismissed_countdown_restarts_the_interval_once_the_grace_expires() {
        let mut h = Harness::new(&[0xE7, 0x51, 0xE7, 0x5D], 5883);
        h.status(0x019B, now());
        h.append(&[0xFB, 0x58]);
        h.poll(now());
        assert!(h
            .today(now(), Some(411), false)
            .next_move
            .unwrap()
            .is_announced());
        let later = now() + COUNTDOWN_ENTRY_TO_MOTOR + ANNOUNCEMENT_GRACE;
        let dismissed = h.today(later, Some(411), false);
        assert_eq!(dismissed.stands, 1, "no move happened");
        assert_eq!(
            dismissed.next_move,
            Some(NextMove::new(now() + seconds(1200) + MOVE_LEAD, false)),
            "a plain interval from the read time"
        );
    }

    #[test]
    fn waved_off_countdown_is_reported_cancelled_as_soon_as_the_grace_passes() {
        let mut h = Harness::new(&[0xE7, 0x51, 0xE7, 0x5D], 5883);
        h.status(0x019B, now());
        h.append(&[0xFB, 0x58]);
        h.poll(now());
        assert!(
            h.session.status_poll_fast(now()),
            "announced: watch the motor closely"
        );
        let before = now() + COUNTDOWN_ENTRY_TO_MOTOR + ANNOUNCEMENT_GRACE - seconds(1);
        h.status(0x019B, before);
        let still_announced = h.today(before, Some(411), false);
        assert!(still_announced.next_move.unwrap().is_announced());
        assert_eq!(still_announced.cancelled_move, None);
        let later = now() + COUNTDOWN_ENTRY_TO_MOTOR + ANNOUNCEMENT_GRACE;
        h.status(0x019B, later);
        let cancelled = h.today(later, Some(411), false);
        let c = cancelled.cancelled_move.expect("waved off");
        assert_eq!(
            (c.at, c.to_standing, c.reason),
            (later, false, CancelReason::WavedOff)
        );
        assert!(!cancelled.next_move.unwrap().is_announced());
        assert_eq!(
            cancelled.next_move.unwrap().at,
            now() + seconds(1200) + MOVE_LEAD
        );
        // Stable: the time of the finding doesn't creep with the clock.
        let even_later = later + seconds(2);
        assert_eq!(
            h.today(even_later, Some(411), false).cancelled_move,
            Some(c)
        );
        assert!(!h.session.status_poll_fast(even_later));
        // Shown briefly from the finding, then gone, so every reader drops it at
        // once - while the finding itself stays, so it is never reported a second time.
        let last_shown = later + CANCELLED_SHOWN_FOR - seconds(1);
        assert_eq!(h.today(last_shown, Some(411), false).cancelled_move, Some(c));
        assert_eq!(h.today(later + CANCELLED_SHOWN_FOR, Some(411), false).cancelled_move, None);
        let gone = h.today(later + CANCELLED_SHOWN_FOR + seconds(45), Some(411), false);
        assert_eq!(gone.cancelled_move, None);
        assert_eq!(h.session.cancelled(), Some(c), "the finding is kept, only its badge expires");
        assert_eq!(gone.next_move.unwrap().at, now() + seconds(1200) + MOVE_LEAD);
        // The link dropping and coming back keeps the cancel and its restarted timer.
        h.session.reconnected();
        let after_link = h.today(later + seconds(90), Some(411), false);
        assert_eq!(after_link.next_move.unwrap().at, now() + seconds(1200) + MOVE_LEAD);
        assert_eq!(h.session.cancelled(), Some(c));
        // And so does a restart, from what was persisted - without re-reporting the cancel.
        let live = h.session.live_countdown().expect("a live countdown to persist");
        assert_eq!((live.seen_at, live.to_standing, live.cancelled_at), (now(), false, Some(later)));
        // The restarted app reads the whole log at once, the countdown entry in it (not live),
        // then restores what it had seen.
        let mut fresh = Harness::new(&[0xE7, 0x51, 0xE7, 0x5D, 0xFB, 0x58], 5883);
        fresh.session.restore_countdown(live, later + seconds(90));
        fresh.status(0x019B, later + seconds(90));
        let restored = fresh.today(later + seconds(90), Some(411), false);
        assert_eq!(restored.next_move.unwrap().at, now() + seconds(1200) + MOVE_LEAD);
        assert_eq!(restored.cancelled_move, None, "the badge's display interval has passed");
        assert_eq!(fresh.session.cancelled(), Some(c));
        // The next announcement clears it.
        h.ring.minutes = 5884;
        h.append(&[0xFC, 0x58]);
        h.poll(even_later + seconds(1200));
        assert_eq!(
            h.today(even_later + seconds(1200), Some(411), false)
                .cancelled_move,
            None
        );
    }

    #[test]
    fn a_move_reversed_mid_travel_is_reported_cancelled() {
        let mut h = Harness::new(&[0xE7, 0x51, 0xE7, 0x5D], 5883);
        h.status(0x019B, now());
        h.append(&[0xFB, 0x58]);
        h.poll(now());
        // The motor starts down, the user reverses it, and it settles back at standing.
        h.status(0x8000_0190, now() + seconds(14));
        assert!(h
            .today(now() + seconds(14), Some(400), true)
            .cancelled_move
            .is_none());
        h.status(0x8000_0195, now() + seconds(16));
        h.status(0x019B, now() + seconds(18));
        let today = h.today(now() + seconds(18), Some(411), false);
        let c = today.cancelled_move.expect("reversed");
        assert_eq!((c.to_standing, c.reason), (false, CancelReason::Reversed));
        assert!(!today.next_move.unwrap().is_announced());
        assert_eq!(today.stands, 1, "no posture change, no new stand");
        // A completed move later clears it.
        h.status(0x8000_0150, now() + seconds(100));
        h.status(0x010A, now() + seconds(108));
        h.status(0x010A, now() + seconds(109));
        assert_eq!(
            h.today(now() + seconds(109), Some(266), false)
                .cancelled_move,
            None
        );
    }

    #[test]
    fn coast_prediction_rides_along_with_status_notes() {
        let mut h = Harness::new(&[0xE7, 0x51, 0xE7, 0x5D], 5883);
        assert!(h.status(0x010B, now()).prediction.is_none());
        h.status(0x8000_010F, now() + SignedDuration::from_millis(250));
        let note = h.status(0x8000_0113, now() + SignedDuration::from_millis(500));
        let p = note.prediction.expect("moving: a prediction");
        assert!(!p.coasting && p.final_tenths > 0x113);
        let note = h.status(0x0113, now() + SignedDuration::from_millis(750));
        assert!(note.prediction.unwrap().coasting);
    }

    #[test]
    fn a_live_countdown_is_recognised_across_the_minute_wrap() {
        let mut h = Harness::new(&[0xFF, 0x51], 255);
        h.ring.minutes = 256;
        h.append(&[0x00, 0x59]);
        let (_, ingest) = h.poll(now() + seconds(30));
        assert!(
            ingest.live_countdown,
            "minute byte 0 is the current minute when the counter reads 256"
        );
        h.ring.minutes = 257;
        h.append(&[0x00, 0x58]);
        assert!(
            h.poll(now() + seconds(90)).1.live_countdown,
            "minute byte 0 is the minute that just ended at 257"
        );
        h.ring.minutes = 258;
        h.append(&[0x00, 0x59]);
        assert!(
            !h.poll(now() + seconds(150)).1.live_countdown,
            "two minutes stale is not live"
        );
    }

    #[test]
    fn implausible_status_reading_changes_nothing() {
        let mut h = Harness::new(&[0xE7, 0x51, 0xE7, 0x5D], 5883);
        h.status(0x010B, now());
        let before = h.today(now(), Some(267), false);
        for i in 1..10 {
            let note = h.status(0xDEAD_BEEF, now() + seconds(i));
            assert!(!note.observation.publish && !note.moves_changed);
        }
        let after = h.today(now() + seconds(10), Some(267), false);
        assert_eq!(
            (after.stands, after.next_move),
            (before.stands, before.next_move)
        );
        assert_eq!(
            h.session.tracker().last_status(),
            Some(StatusWord::from_raw(0x010B))
        );
    }

    #[test]
    fn history_poll_interval_tightens_around_the_move() {
        let base = seconds(5);
        let next = |at: Timestamp| TodayStats {
            next_move: Some(NextMove::new(at, true)),
            ..Default::default()
        };
        assert_eq!(
            DeskSession::history_poll_interval(None, false, now(), base),
            base
        );
        assert_eq!(
            DeskSession::history_poll_interval(
                Some(&next(now() + minutes(20))),
                false,
                now(),
                base
            ),
            base
        );
        assert_eq!(
            DeskSession::history_poll_interval(Some(&next(now() + minutes(5))), false, now(), base),
            seconds(1)
        );
        assert_eq!(
            DeskSession::history_poll_interval(
                Some(&next(now() + seconds(30))),
                false,
                now(),
                base
            ),
            SignedDuration::from_millis(300)
        );
        assert_eq!(
            DeskSession::history_poll_interval(
                Some(&next(now() - minutes(30))),
                false,
                now(),
                base
            ),
            SignedDuration::from_millis(300),
            "overdue stays fast"
        );
        assert_eq!(
            DeskSession::history_poll_interval(Some(&next(now() + seconds(30))), true, now(), base),
            base,
            "not while moving"
        );
    }

    #[test]
    fn restored_observed_moves_keep_only_the_last_day() {
        let mut s = DeskSession::new(SessionConfig::default());
        let old = Event::synthetic(
            now() - SignedDuration::from_hours(25),
            EventKind::Move { to_standing: true },
        );
        let recent = Event::synthetic(
            now() - SignedDuration::from_hours(1),
            EventKind::Move { to_standing: false },
        );
        s.restore_observed_moves(vec![old, recent], now());
        assert_eq!(s.observed_moves(), [recent]);
    }
}
