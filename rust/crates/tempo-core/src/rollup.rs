//! Today's numbers and the next-move estimate, rolled up from a chronological event list.
//!
//! This is the part of the backend that took a month of field data to get right. Every
//! constant and rule below carries the observation that produced it; keep them together.

use jiff::tz::TimeZone;
use jiff::{SignedDuration, Timestamp};
use serde::{Deserialize, Serialize};

use crate::cruise::CruiseSlot;
use crate::history::{Event, EventKind};
use crate::time::{duration_seconds, iso8601_seconds, minutes, seconds};

/// How long the desk beeps before it moves: the "countdown" field of the user block
/// (offset 8, low 16 bits) reads 15, and the COUNTDOWN log entry, written when the beeping
/// starts, became readable 13.2 s before the motor started on 2026-09-08 with the log read
/// every second (docs/protocol.md, "Countdown accuracy").
pub const BEEP: SignedDuration = seconds(15);

/// Where the desk's next move lands past `last motor start + interval`: the beep began
/// 1197 s after the previous motor start on a 1200 s interval (2026-09-08, 16:39:57.9 ->
/// 16:59:54.97), about 5 s early, and the motor followed `BEEP` later. So the motor starts
/// roughly interval + 10 s after the previous one. Only an estimate: the desk also pauses
/// its timer for short absences it never logs (three sitting intervals on 2026-09-08 ran
/// 8 s, 68 s and 120 s long), which is why the estimate hands over to the desk's own
/// announcement (`NextMove::announced_at`) as soon as that is read.
pub const MOVE_LEAD: SignedDuration = seconds(10);

/// How long after the user leaves the desk writes "not present": its timer stopped when
/// they left, so a hold starts this much before the logged absence. Over the 63 cycles with
/// an absence from 2026-09-08 to 09-25, lags of 4-7 min fit about equally (mean error
/// 3.2-3.4 min, against 4.6 taking the entry at its word); 7 leaves the fewest estimates
/// early (7 of 63), and early is the costly side: the label reads "overdue", where late only
/// defers to the desk's own COUNTDOWN entry.
pub const ABSENCE_LOG_LAG: SignedDuration = minutes(7);

/// A `MOVE` entry within this many seconds of an immediately preceding `HEIGHT` entry is
/// treated as stamped the same minute (the desk logs `HEIGHT n` right before the `MOVE` it
/// produced).
pub(crate) const HEIGHT_MOVE_WINDOW: SignedDuration = seconds(90);

/// How long a countdown stays eligible to be resolved (completed or aborted) by the next
/// height change, and how long it keeps announcing the move. Beyond this it was dismissed: a
/// later height change is unrelated, a paddle nudge perhaps after an absence, not its abort.
const COUNTDOWN_RESOLUTION_WINDOW: SignedDuration = minutes(5);

/// How far a countdown's logged date may sit from `dismissed_countdown_at` and still be the
/// entry the app read live: the log dates entries to the minute from an anchor with up to a
/// minute of seconds-of-minute jitter.
const LIVE_COUNTDOWN_MATCH_WINDOW: SignedDuration = seconds(120);

/// Past this much after `at`, a move is "overdue" rather than "now".
const OVERDUE_AFTER: SignedDuration = seconds(90);

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NextMove {
    #[serde(with = "iso8601_seconds")]
    pub at: Timestamp,
    pub to_standing: bool,
    /// When the desk's own COUNTDOWN entry was read, if it has been: from then on `at` is
    /// the desk's timing (entry plus the entry-to-motor constant), good to a second or two,
    /// rather than the app's interval arithmetic. `None` while estimating.
    #[serde(
        with = "iso8601_seconds::option",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub announced_at: Option<Timestamp>,
}

impl NextMove {
    pub const fn new(at: Timestamp, to_standing: bool) -> Self {
        Self {
            at,
            to_standing,
            announced_at: None,
        }
    }

    pub const fn announced(at: Timestamp, to_standing: bool, announced_at: Timestamp) -> Self {
        Self {
            at,
            to_standing,
            announced_at: Some(announced_at),
        }
    }

    /// True once `now` is more than 90 s past `at`. The desk doesn't move the instant the
    /// cruise interval elapses and can run further behind depending on presence timing, so
    /// a plain "now" countdown reads as broken once it has sat at zero for a while; UIs
    /// switch to an "overdue" presentation instead.
    pub fn is_overdue(&self, now: Timestamp) -> bool {
        now > self.at + OVERDUE_AFTER
    }

    /// When the desk starts (or started) beeping: `BEEP` before `at`. This is the moment
    /// the user experiences as "the desk is moving", so it is what minute countdowns run
    /// down to; between here and `at` the desk is counting.
    pub fn announce_at(&self) -> Timestamp {
        self.announced_at.unwrap_or(self.at - BEEP)
    }

    /// True once the desk has actually announced this move (its COUNTDOWN entry was read).
    pub const fn is_announced(&self) -> bool {
        self.announced_at.is_some()
    }

    /// True while the desk should be running its own countdown (or moving).
    pub fn is_announced_at(&self, now: Timestamp) -> bool {
        now >= self.announce_at()
    }
}

/// Why an announced move came to nothing.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CancelReason {
    /// The desk beeped and the motor never started: the paddle waved it off.
    WavedOff,
    /// The motor started and the desk ended up in the same posture: reversed mid-move.
    Reversed,
}

/// The desk announced a move and the user stopped it. Stays in `TodayStats` until the
/// desk's next announcement or move, so a UI can say so for as long as it likes.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CancelledMove {
    /// When the app concluded the move was off.
    #[serde(with = "iso8601_seconds")]
    pub at: Timestamp,
    pub to_standing: bool,
    pub reason: CancelReason,
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct TodayStats {
    #[serde(with = "duration_seconds")]
    pub at_desk_seconds: SignedDuration,
    pub stands: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub is_standing: Option<bool>,
    pub is_present: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next_move: Option<NextMove>,
    /// The last announced move the user cancelled, while it is still the latest word from
    /// the desk. Set by the session, not the rollup.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cancelled_move: Option<CancelledMove>,
}

/// The desk splits days at `middle_of_night_hour` local time. Returns the most recent
/// boundary at or before `now`, on the calendar so a DST change doesn't shift it.
pub fn day_start(now: Timestamp, tz: &TimeZone, middle_of_night_hour: u8) -> Timestamp {
    let local = now.to_zoned(tz.clone());
    let hour = i8::try_from(middle_of_night_hour.min(23)).unwrap_or(4);
    let boundary = |date: jiff::civil::Date| {
        date.at(hour, 0, 0, 0)
            .to_zoned(tz.clone())
            .map(|z| z.timestamp())
    };
    let today = boundary(local.date()).unwrap_or(now);
    if now >= today {
        return today;
    }
    local
        .date()
        .yesterday()
        .ok()
        .and_then(|d| boundary(d).ok())
        .unwrap_or(today - SignedDuration::from_hours(24))
}

/// Everything `compute` needs. `events` must be in chronological order.
#[derive(Clone, Copy, Debug)]
pub struct RollupInput<'a> {
    pub events: &'a [Event],
    pub now: Timestamp,
    pub day_start: Timestamp,
    pub cruise: Option<CruiseSlot>,
    pub paused: bool,
    /// The whole-inch midpoint between the sitting and standing presets. When given, a
    /// move's actual resulting posture is derived from the `HEIGHT` entry the desk logs
    /// immediately before it rather than trusted from the raise bit: a paddle nudge that
    /// doesn't cross the threshold still logs `MOVE up`/`MOVE down` and must not count as a
    /// stand. `None` keeps the raise bit, e.g. for a live-observed move.
    pub standing_threshold_inches: Option<u8>,
    /// When the app read the desk's latest COUNTDOWN entry live and then watched the motor
    /// *not* start. The log alone can't tell a dismissed countdown from one about to move
    /// until the resolution window passes; this dismisses the matching countdown at once,
    /// anchored on the read time.
    pub dismissed_countdown_at: Option<Timestamp>,
}

impl<'a> RollupInput<'a> {
    pub const fn new(events: &'a [Event], now: Timestamp, day_start: Timestamp) -> Self {
        Self {
            events,
            now,
            day_start,
            cruise: None,
            paused: false,
            standing_threshold_inches: None,
            dismissed_countdown_at: None,
        }
    }
}

#[derive(Clone, Copy)]
struct Pending {
    date: Timestamp,
    to_standing: bool,
    absent_before: SignedDuration,
}

struct Walk {
    day_start: Timestamp,
    now: Timestamp,
    present: bool,
    present_since: Option<Timestamp>,
    at_desk: SignedDuration,
    stands: u32,
    is_standing: Option<bool>,
    /// Gates the stands counter, separately from `is_standing` (which must keep reflecting
    /// the desk's actual current posture even when its most recent move happened before
    /// today). Seeded once from `is_standing` as of just before the first event dated at or
    /// after `day_start`, so a move counts as a stand only when it is a genuine
    /// sitting->standing transition within today.
    is_standing_today: Option<bool>,
    seeded_today: bool,
    last_move: Option<(Timestamp, bool)>,
    /// Logged absences since the last move, summed: the desk holds its interval timer while
    /// it doesn't see you (2026-09-11: sat 12:41, away 13:04-13:12, and the stand due at
    /// 13:21 came at 13:33).
    absent_since_move: SignedDuration,
    absent_since: Option<Timestamp>,
    /// The desk's timer anchors on its own completed *or aborted* moves, and on manual ones.
    /// A countdown sets this; the next height change resolves it as a move at that height,
    /// and a move resolves it too. Still set at the end: nothing resolved it, and it anchors
    /// `next_move` directly.
    pending_countdown: Option<Pending>,
}

impl Walk {
    fn close_interval(&mut self, end: Timestamp) {
        if let Some(start) = self.present_since.take() {
            let clipped_start = start.max(self.day_start);
            let clipped_end = end.min(self.now);
            if clipped_end > clipped_start {
                self.at_desk += clipped_end.duration_since(clipped_start);
            }
        }
    }

    fn mark_present(&mut self, date: Timestamp) {
        if !self.present {
            self.present = true;
            self.present_since = Some(date);
        }
    }

    /// Records `date`/`to_standing` as the desk's latest move, counting a stand only on a
    /// genuine sitting->standing transition within today.
    fn apply_move(&mut self, date: Timestamp, to_standing: bool) {
        if date >= self.day_start {
            if to_standing && self.is_standing_today != Some(true) {
                self.stands += 1;
            }
            self.is_standing_today = Some(to_standing);
        }
        self.is_standing = Some(to_standing);
        self.last_move = Some((date, to_standing));
        self.absent_since_move = SignedDuration::ZERO;
        // A move while marked absent (a manual one): the hold counts from the move.
        if self.absent_since.is_some() {
            self.absent_since = Some(date);
        }
    }

    /// A countdown that never became a move or a height change was dismissed: the user waved
    /// it off, or walked away. The desk restarts its interval from that dismissal, not from
    /// the older move (2026-09-05: dismissed stand countdowns recurred at 00:57, 01:17, 01:38
    /// and 01:59, every interval plus about a minute, anchored ~`MOVE_LEAD` after each
    /// announcement). Posture is unchanged, so this is not a move and counts no stand.
    ///
    /// `anchor` is where the restarted interval counts from: the log's minute stamp plus
    /// `MOVE_LEAD` by default, or the live read time of the entry when the app watched the
    /// dismissal itself (2026-09-12: read 13:39:44.96, next motor 13:59:51.9).
    fn dismiss_countdown(&mut self, pending: Pending, anchor: Option<Timestamp>) {
        let posture = self.is_standing.unwrap_or(!pending.to_standing);
        self.last_move = Some((anchor.unwrap_or(pending.date + MOVE_LEAD), posture));
        // The timer restarts here, so only absences *since* the countdown hold it: the ones
        // before it were already part of the interval that just ran out.
        self.absent_since_move -= pending.absent_before;
    }

    /// The desk starts its interval afresh each day: every overnight cycle on record with no
    /// visit after the boundary moved one full interval after the morning's return. Posture
    /// carries over; only the timer restarts, as if at a move at `day_start`.
    fn restart_timer_at_day_start(&mut self) {
        if let Some(pending) = self.pending_countdown {
            if self.day_start.duration_since(pending.date) > COUNTDOWN_RESOLUTION_WINDOW {
                self.dismiss_countdown(pending, None);
                self.pending_countdown = None;
            }
        }
        if let Some((date, to_standing)) = self.last_move {
            if date < self.day_start {
                self.last_move = Some((self.day_start, to_standing));
                self.absent_since_move = SignedDuration::ZERO;
                if self.absent_since.is_some() {
                    self.absent_since = Some(self.day_start);
                }
            }
        }
    }
}

/// Posture a `MOVE` produced: from the `HEIGHT` entry immediately before it (same minute)
/// when a threshold is known, else the raise bit.
pub(crate) fn resolved_posture(
    events: &[Event],
    index: usize,
    raise_bit: bool,
    threshold: Option<u8>,
) -> bool {
    if let (Some(threshold), Some(previous)) = (threshold, index.checked_sub(1).map(|i| events[i]))
    {
        if let EventKind::HeightChange { inches } = previous.kind {
            if events[index].date.duration_since(previous.date).abs() <= HEIGHT_MOVE_WINDOW {
                return inches >= threshold;
            }
        }
    }
    raise_bit
}

/// Pure rollup of dated events.
pub fn compute(input: RollupInput<'_>) -> TodayStats {
    let RollupInput {
        events,
        now,
        day_start,
        cruise,
        paused,
        standing_threshold_inches,
        dismissed_countdown_at,
    } = input;
    let mut w = Walk {
        day_start,
        now,
        present: false,
        present_since: None,
        at_desk: SignedDuration::ZERO,
        stands: 0,
        is_standing: None,
        is_standing_today: None,
        seeded_today: false,
        last_move: None,
        absent_since_move: SignedDuration::ZERO,
        absent_since: None,
        pending_countdown: None,
    };

    for (index, event) in events.iter().enumerate() {
        if !w.seeded_today && event.date >= day_start {
            w.is_standing_today = w.is_standing;
            w.seeded_today = true;
            w.restart_timer_at_day_start();
        }
        match event.kind {
            EventKind::Presence { present: true } => {
                if let Some(since) = w.absent_since.take() {
                    w.absent_since_move += event.date.duration_since(since);
                }
                // The desk's authoritative presence signal: it always (re)anchors the
                // interval start, even if we were already marked present from a countdown.
                w.present = true;
                w.present_since = Some(event.date);
            }
            EventKind::Presence { present: false } => {
                if w.present {
                    // The timer stopped when the user left, `ABSENCE_LOG_LAG` before this
                    // entry - but not before this visit, move or countdown began.
                    let mut left = event.date - ABSENCE_LOG_LAG;
                    for floor in [
                        w.present_since,
                        w.last_move.map(|m| m.0),
                        w.pending_countdown.map(|p| p.date),
                    ]
                    .into_iter()
                    .flatten()
                    {
                        left = left.max(floor);
                    }
                    w.close_interval(event.date);
                    w.present = false;
                    w.absent_since = Some(left.min(event.date));
                }
            }
            EventKind::Countdown { to_standing } => {
                w.mark_present(event.date);
                if let Some(pending) = w.pending_countdown {
                    w.dismiss_countdown(pending, None);
                }
                w.pending_countdown = Some(Pending {
                    date: event.date,
                    to_standing,
                    absent_before: w.absent_since_move,
                });
            }
            EventKind::Move {
                to_standing: raise_bit,
            } => {
                w.mark_present(event.date);
                w.pending_countdown = None;
                let to_standing =
                    resolved_posture(events, index, raise_bit, standing_threshold_inches);
                w.apply_move(event.date, to_standing);
            }
            EventKind::HeightChange { inches } => {
                // Only meaningful right after an unresolved countdown (a HEIGHT entry with no
                // MOVE following, e.g. the user reversed the move before it completed), and
                // only within the resolution window of it.
                let Some(pending) = w.pending_countdown else {
                    continue;
                };
                if event.date.duration_since(pending.date) > COUNTDOWN_RESOLUTION_WINDOW {
                    w.dismiss_countdown(pending, None);
                    w.pending_countdown = None;
                    continue;
                }
                let to_standing =
                    standing_threshold_inches.map_or(pending.to_standing, |t| inches >= t);
                w.apply_move(event.date, to_standing);
                w.pending_countdown = None;
            }
            EventKind::UserChange { .. } | EventKind::Nop { .. } => {}
        }
    }
    if !w.seeded_today {
        w.restart_timer_at_day_start();
    }
    if w.present {
        w.close_interval(now);
    }
    if let Some(pending) = w.pending_countdown {
        let live = dismissed_countdown_at
            .filter(|d| pending.date.duration_since(*d).abs() < LIVE_COUNTDOWN_MATCH_WINDOW);
        if let Some(read_at) = live {
            // The app watched this very countdown come to nothing: dismissed now, on the
            // read time, rather than after the resolution window on the minute stamp.
            w.dismiss_countdown(pending, Some(read_at));
            w.pending_countdown = None;
        } else if now.duration_since(pending.date) > COUNTDOWN_RESOLUTION_WINDOW {
            // Old enough that its move would have been logged by now: dismissed, so it
            // re-anchors the timer rather than announcing.
            w.dismiss_countdown(pending, None);
            w.pending_countdown = None;
        }
    }

    let mut next_move = None;
    if let (Some(cruise), false, true) = (cruise, paused, w.present) {
        let wait = |to_standing: bool| {
            seconds(i64::from(if to_standing {
                cruise.standing_seconds
            } else {
                cruise.sitting_seconds
            }))
        };
        let from_interval = w.last_move.map(|(date, to_standing)| {
            NextMove::new(date + wait(to_standing) + MOVE_LEAD, !to_standing)
        });
        if let Some(pending) = w.pending_countdown {
            // The desk has announced this move and nothing has resolved it yet. The
            // announcement's own stamp is only good to the minute, so when the interval-based
            // prediction agrees with it to within a couple of minutes, keep that: it can be
            // anchored on a live-observed move and be good to the second. The announcement
            // only takes over when the interval prediction is clearly wrong, e.g. after an
            // absence.
            let announced = NextMove::new(pending.date + MOVE_LEAD, pending.to_standing);
            next_move = Some(match from_interval {
                Some(fi)
                    if fi.to_standing == announced.to_standing
                        && fi.at.duration_since(announced.at).abs() < seconds(120) =>
                {
                    fi
                }
                _ => announced,
            });
        } else if let Some((date, to_standing)) = w.last_move {
            // The desk holds its timer while it doesn't see you, so the plain interval runs
            // early by the absences since the move. Short pauses it never logs can still leave
            // the estimate early, and the fitted lag can leave it a few minutes late; either
            // way the desk's own COUNTDOWN entry takes over the moment it beeps.
            next_move = Some(NextMove::new(
                date + wait(to_standing) + w.absent_since_move + MOVE_LEAD,
                !to_standing,
            ));
        }
    }
    TodayStats {
        at_desk_seconds: w.at_desk,
        stands: w.stands,
        is_standing: w.is_standing,
        is_present: w.present,
        next_move,
        cancelled_move: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use jiff::civil::date;

    fn now() -> Timestamp {
        Timestamp::from_second(1_800_000_000).unwrap()
    }
    fn minutes_ago(m: f64) -> Timestamp {
        now() - SignedDuration::from_secs_f64(m * 60.0)
    }
    fn ev(m: f64, kind: EventKind) -> Event {
        Event::new(0, minutes_ago(m), kind)
    }
    const CRUISE: CruiseSlot = CruiseSlot::new(20 * 60, 20 * 60);
    fn present(p: bool) -> EventKind {
        EventKind::Presence { present: p }
    }
    fn mv(to_standing: bool) -> EventKind {
        EventKind::Move { to_standing }
    }
    fn countdown(to_standing: bool) -> EventKind {
        EventKind::Countdown { to_standing }
    }
    fn height(inches: u8) -> EventKind {
        EventKind::HeightChange { inches }
    }
    fn run(events: &[Event], day_start: Timestamp) -> TodayStats {
        compute(RollupInput {
            cruise: Some(CRUISE),
            ..RollupInput::new(events, now(), day_start)
        })
    }
    fn run_t(events: &[Event], day_start: Timestamp, threshold: u8) -> TodayStats {
        compute(RollupInput {
            cruise: Some(CRUISE),
            standing_threshold_inches: Some(threshold),
            ..RollupInput::new(events, now(), day_start)
        })
    }
    fn close(a: SignedDuration, b: SignedDuration) -> bool {
        (a - b).abs() <= seconds(1)
    }

    #[test]
    fn day_start_uses_middle_of_night_hour() {
        let tz = TimeZone::get("America/Los_Angeles").unwrap();
        let at = |y, m, d, h| {
            date(y, m, d)
                .at(h, 0, 0, 0)
                .to_zoned(tz.clone())
                .unwrap()
                .timestamp()
        };
        assert_eq!(day_start(at(2026, 9, 4, 15), &tz, 4), at(2026, 9, 4, 4));
        assert_eq!(day_start(at(2026, 9, 4, 2), &tz, 4), at(2026, 9, 3, 4));
    }

    #[test]
    fn counts_stands_and_sums_presence_since_day_start() {
        let events = [
            ev(600.0, mv(true)),
            ev(400.0, mv(false)),
            ev(120.0, present(true)),
            ev(90.0, countdown(true)),
            ev(89.0, mv(true)),
            ev(69.0, mv(false)),
            ev(30.0, present(false)),
            ev(10.0, present(true)),
        ];
        let stats = run(&events, minutes_ago(300.0));
        assert_eq!(stats.stands, 1);
        assert_eq!(stats.is_standing, Some(false));
        assert!(stats.is_present);
        assert!(close(stats.at_desk_seconds, minutes(100)));
        // last move to sitting 69 min ago; the desk held its timer through the absence
        // -37..-10 (logged at -30, ABSENCE_LOG_LAG late), so next stand at -69 + 20 + 27 min.
        assert_eq!(
            stats.next_move,
            Some(NextMove::new(minutes_ago(22.0) + MOVE_LEAD, true))
        );
    }

    #[test]
    fn presence_interval_is_clipped_to_day_start() {
        let stats = run(&[ev(500.0, present(true))], minutes_ago(60.0));
        assert!(close(stats.at_desk_seconds, minutes(60)));
        assert_eq!(stats.next_move, None);
    }

    #[test]
    fn move_implies_presence() {
        let stats = run(
            &[ev(40.0, present(false)), ev(5.0, mv(true))],
            minutes_ago(60.0),
        );
        assert!(stats.is_present);
        assert!(close(stats.at_desk_seconds, minutes(5)));
    }

    #[test]
    fn nudge_within_presets_does_not_count_as_stand() {
        let events = [
            ev(5.0, height(29)),
            ev(5.0, mv(true)),
            ev(4.0, height(26)),
            ev(4.0, mv(false)),
        ];
        let stats = run_t(&events, minutes_ago(60.0), 34);
        assert_eq!(stats.stands, 0);
        assert_eq!(stats.is_standing, Some(false));
    }

    #[test]
    fn real_stand_derived_from_height_counts_once() {
        let stats = run_t(
            &[ev(3.0, height(41)), ev(3.0, mv(true))],
            minutes_ago(60.0),
            34,
        );
        assert_eq!(stats.stands, 1);
        assert_eq!(stats.is_standing, Some(true));
    }

    #[test]
    fn consecutive_moves_to_the_same_posture_count_once() {
        let stats = run(&[ev(10.0, mv(true)), ev(9.0, mv(true))], minutes_ago(60.0));
        assert_eq!(stats.stands, 1);
        assert_eq!(stats.is_standing, Some(true));
    }

    #[test]
    fn without_threshold_posture_matches_raise_bit() {
        let stats = run(&[ev(5.0, height(29)), ev(5.0, mv(true))], minutes_ago(60.0));
        assert_eq!(stats.stands, 1);
        assert_eq!(stats.is_standing, Some(true));
    }

    #[test]
    fn standing_across_day_boundary_is_not_counted_again() {
        let events = [
            ev(620.0, mv(true)),
            ev(500.0, mv(true)),
            ev(300.0, mv(false)),
            ev(100.0, mv(true)),
        ];
        let stats = run(&events, minutes_ago(600.0));
        assert_eq!(stats.stands, 1);
        assert_eq!(stats.is_standing, Some(true));
    }

    #[test]
    fn absence_holds_the_timer() {
        let events = [
            ev(40.0, mv(true)),
            ev(30.0, present(false)),
            ev(10.0, present(true)),
        ];
        let stats = run(&events, minutes_ago(60.0));
        assert_eq!(
            stats.next_move,
            Some(NextMove::new(minutes_ago(-7.0) + MOVE_LEAD, false))
        );
    }

    #[test]
    fn the_timer_restarts_at_the_day_boundary() {
        let events = [
            ev(600.0, mv(false)),
            ev(580.0, present(true)),
            ev(560.0, present(false)),
            ev(10.0, present(true)),
        ];
        let stats = run(&events, minutes_ago(300.0));
        assert_eq!(
            stats.next_move,
            Some(NextMove::new(
                minutes_ago(10.0) + minutes(20) + MOVE_LEAD,
                true
            ))
        );
    }

    #[test]
    fn present_across_the_day_boundary_counts_from_the_boundary() {
        let stats = run(&[ev(90.0, mv(false))], minutes_ago(15.0));
        assert_eq!(
            stats.next_move,
            Some(NextMove::new(
                minutes_ago(15.0) + minutes(20) + MOVE_LEAD,
                true
            ))
        );
    }

    #[test]
    fn absence_is_logged_late_so_the_hold_starts_earlier() {
        let events = [
            ev(40.0, mv(true)),
            ev(30.0, present(false)),
            ev(10.0, present(true)),
        ];
        let stats = run(&events, minutes_ago(60.0));
        assert_eq!(
            stats.next_move,
            Some(NextMove::new(now() + ABSENCE_LOG_LAG + MOVE_LEAD, false))
        );
    }

    #[test]
    fn return_after_a_quiet_day_is_not_overdue() {
        let at = |s: &str, kind: EventKind| Event::new(0, s.parse().unwrap(), kind);
        let events = [
            at("2026-09-26T00:48:34Z", height(26)),
            at("2026-09-26T00:48:34Z", mv(false)),
            at("2026-09-26T00:53:34Z", present(true)),
            at("2026-09-26T01:03:34Z", present(false)),
            at("2026-09-26T02:51:34Z", present(true)),
            at("2026-09-26T02:59:34Z", present(false)),
            at("2026-09-26T03:53:34Z", present(true)),
            at("2026-09-26T04:00:34Z", present(false)),
            at("2026-09-26T05:20:34Z", present(true)),
            at("2026-09-26T05:28:34Z", present(false)),
            at("2026-09-26T20:50:34Z", present(true)),
            at("2026-09-26T20:58:34Z", present(false)),
            at("2026-09-26T21:43:34Z", present(true)),
            at("2026-09-26T21:51:34Z", present(false)),
            at("2026-09-27T01:07:34Z", present(true)),
        ];
        let stats = compute(RollupInput {
            cruise: Some(CruiseSlot::new(20 * 60, 40 * 60)),
            standing_threshold_inches: Some(31),
            ..RollupInput::new(
                &events,
                "2026-09-27T01:10:00Z".parse().unwrap(),
                "2026-09-26T08:00:00Z".parse().unwrap(),
            )
        });
        assert_eq!(
            stats.next_move,
            Some(NextMove::new("2026-09-27T01:45:44Z".parse().unwrap(), true))
        );
    }

    #[test]
    fn a_hold_counts_from_a_move_made_while_absent() {
        let events = [
            ev(40.0, mv(true)),
            ev(30.0, present(false)),
            ev(25.0, mv(false)),
            ev(10.0, present(true)),
        ];
        let stats = run(&events, minutes_ago(60.0));
        assert_eq!(
            stats.next_move,
            Some(NextMove::new(minutes_ago(-10.0) + MOVE_LEAD, true))
        );
    }

    #[test]
    fn logged_absences_since_the_move_push_the_estimate_back() {
        let events = [
            ev(2.0, mv(true)),
            ev(1.0, present(false)),
            ev(0.5, present(true)),
        ];
        let stats = run(&events, minutes_ago(60.0));
        assert_eq!(
            stats.next_move,
            Some(NextMove::new(
                minutes_ago(2.0) + minutes(20) + seconds(90) + MOVE_LEAD,
                false
            ))
        );
    }

    #[test]
    fn absences_before_the_move_do_not_count() {
        let events = [
            ev(30.0, present(false)),
            ev(10.0, present(true)),
            ev(2.0, mv(true)),
        ];
        let stats = run(&events, minutes_ago(60.0));
        assert_eq!(
            stats.next_move,
            Some(NextMove::new(
                minutes_ago(2.0) + minutes(20) + MOVE_LEAD,
                false
            ))
        );
    }

    #[test]
    fn countdown_log_entry_anchors_next_move() {
        let stats = run(&[ev(0.5, countdown(true))], minutes_ago(60.0));
        assert_eq!(
            stats.next_move,
            Some(NextMove::new(minutes_ago(0.5) + MOVE_LEAD, true))
        );
    }

    #[test]
    fn aborted_move_after_countdown_derives_posture_from_height() {
        let events = [
            ev(10.0, mv(true)),
            ev(2.0, countdown(false)),
            ev(1.0, height(41)),
        ];
        let stats = run_t(&events, minutes_ago(60.0), 34);
        assert_eq!(stats.stands, 1);
        assert_eq!(stats.is_standing, Some(true));
        assert_eq!(
            stats.next_move,
            Some(NextMove::new(
                minutes_ago(1.0) + minutes(20) + MOVE_LEAD,
                false
            ))
        );
    }

    #[test]
    fn aborted_stand_after_countdown_stays_at_sitting_height() {
        let events = [
            ev(10.0, mv(false)),
            ev(2.0, countdown(true)),
            ev(1.0, height(26)),
        ];
        let stats = run_t(&events, minutes_ago(60.0), 34);
        assert_eq!(stats.stands, 0);
        assert_eq!(stats.is_standing, Some(false));
        assert_eq!(
            stats.next_move,
            Some(NextMove::new(
                minutes_ago(1.0) + minutes(20) + MOVE_LEAD,
                true
            ))
        );
    }

    #[test]
    fn countdown_expires_before_a_far_later_height_change() {
        let events = [
            ev(20.0, mv(true)),
            ev(10.0, countdown(false)),
            ev(1.0, height(41)),
        ];
        let stats = run_t(&events, minutes_ago(60.0), 34);
        assert_eq!(stats.stands, 1);
        assert_eq!(stats.is_standing, Some(true));
        assert_eq!(
            stats.next_move,
            Some(NextMove::new(
                minutes_ago(10.0) + MOVE_LEAD + minutes(20) + MOVE_LEAD,
                false
            ))
        );
    }

    #[test]
    fn dismissed_countdown_restarts_the_timer() {
        let events = [ev(45.0, mv(false)), ev(25.0, countdown(true))];
        let stats = run_t(&events, minutes_ago(60.0), 34);
        assert_eq!(stats.stands, 0);
        assert_eq!(stats.is_standing, Some(false));
        assert_eq!(
            stats.next_move,
            Some(NextMove::new(
                minutes_ago(25.0) + MOVE_LEAD + minutes(20) + MOVE_LEAD,
                true
            ))
        );
    }

    #[test]
    fn back_to_back_dismissed_countdowns_anchor_on_the_latest() {
        let events = [
            ev(62.0, mv(false)),
            ev(41.0, countdown(true)),
            ev(20.0, countdown(true)),
        ];
        let stats = run_t(&events, minutes_ago(90.0), 34);
        assert_eq!(
            stats.next_move,
            Some(NextMove::new(
                minutes_ago(20.0) + MOVE_LEAD + minutes(20) + MOVE_LEAD,
                true
            ))
        );
    }

    #[test]
    fn live_dismissed_countdown_restarts_the_timer_at_once() {
        let read_at = minutes_ago(1.0) + seconds(20);
        let events = [ev(45.0, mv(true)), ev(1.0, countdown(false))];
        let stats = compute(RollupInput {
            cruise: Some(CRUISE),
            standing_threshold_inches: Some(34),
            dismissed_countdown_at: Some(read_at),
            ..RollupInput::new(&events, now(), minutes_ago(60.0))
        });
        assert_eq!(stats.stands, 1);
        assert_eq!(stats.is_standing, Some(true));
        assert_eq!(
            stats.next_move,
            Some(NextMove::new(read_at + minutes(20) + MOVE_LEAD, false))
        );
    }

    #[test]
    fn live_dismissal_of_an_older_countdown_does_not_touch_a_fresh_one() {
        let events = [ev(45.0, mv(false)), ev(2.0, countdown(true))];
        let stats = compute(RollupInput {
            cruise: Some(CRUISE),
            standing_threshold_inches: Some(34),
            dismissed_countdown_at: Some(minutes_ago(23.0)),
            ..RollupInput::new(&events, now(), minutes_ago(60.0))
        });
        assert_eq!(
            stats.next_move,
            Some(NextMove::new(minutes_ago(2.0) + MOVE_LEAD, true))
        );
    }

    #[test]
    fn dismissed_countdown_does_not_carry_absences_from_before_it() {
        let events = [
            ev(70.0, mv(true)),
            ev(60.0, present(false)),
            ev(40.0, present(true)),
            ev(25.0, countdown(false)),
        ];
        let stats = run_t(&events, minutes_ago(90.0), 34);
        assert_eq!(
            stats.next_move,
            Some(NextMove::new(
                minutes_ago(25.0) + MOVE_LEAD + minutes(20) + MOVE_LEAD,
                false
            ))
        );
    }

    #[test]
    fn fresh_countdown_still_announces_the_move() {
        let events = [ev(45.0, mv(false)), ev(2.0, countdown(true))];
        let stats = run_t(&events, minutes_ago(60.0), 34);
        assert_eq!(
            stats.next_move,
            Some(NextMove::new(minutes_ago(2.0) + MOVE_LEAD, true))
        );
    }

    #[test]
    fn stale_countdown_is_dismissed_after_an_absence() {
        let events = [
            ev(600.0, mv(false)),
            ev(580.0, countdown(true)),
            ev(560.0, present(false)),
            ev(13.0, present(true)),
        ];
        let stats = run_t(&events, minutes_ago(400.0), 34);
        assert!(stats.is_present);
        assert_eq!(
            stats.next_move,
            Some(NextMove::new(
                minutes_ago(400.0) + minutes(20 + 387) + MOVE_LEAD,
                true
            ))
        );
    }

    #[test]
    fn next_move_anchor_unaffected_without_an_absence() {
        let stats = run(&[ev(5.0, mv(true))], minutes_ago(60.0));
        assert_eq!(
            stats.next_move,
            Some(NextMove::new(
                minutes_ago(5.0) + minutes(20) + MOVE_LEAD,
                false
            ))
        );
    }

    #[test]
    fn next_move_is_overdue_only_more_than_90_seconds_past_at() {
        let next = NextMove::new(now(), true);
        assert!(!next.is_overdue(now()));
        assert!(!next.is_overdue(now() + seconds(90)));
        assert!(next.is_overdue(now() + seconds(91)));
        assert!(!next.is_overdue(now() - seconds(10)));
    }

    #[test]
    fn next_move_is_none_when_paused_absent_or_cruise_off() {
        let events = [ev(30.0, present(true)), ev(5.0, mv(true))];
        let base = RollupInput::new(&events, now(), minutes_ago(60.0));
        assert_eq!(
            compute(RollupInput {
                cruise: Some(CRUISE),
                paused: true,
                ..base
            })
            .next_move,
            None
        );
        assert_eq!(
            compute(RollupInput {
                cruise: None,
                ..base
            })
            .next_move,
            None
        );
        let mut absent = events.to_vec();
        absent.push(ev(1.0, present(false)));
        assert_eq!(
            compute(RollupInput {
                cruise: Some(CRUISE),
                ..RollupInput::new(&absent, now(), minutes_ago(60.0))
            })
            .next_move,
            None
        );
        assert_eq!(
            compute(RollupInput {
                cruise: Some(CRUISE),
                ..base
            })
            .next_move,
            Some(NextMove::new(
                minutes_ago(5.0) + minutes(20) + MOVE_LEAD,
                false
            ))
        );
    }

    #[test]
    fn next_move_serde_matches_swift() {
        let next = NextMove::announced(now(), true, now() - seconds(14));
        assert_eq!(
            serde_json::to_string(&next).unwrap(),
            r#"{"at":"2027-01-15T08:00:00Z","toStanding":true,"announcedAt":"2027-01-15T07:59:46Z"}"#
        );
        let plain: NextMove =
            serde_json::from_str(r#"{"at":"2027-01-15T08:00:00Z","toStanding":false}"#).unwrap();
        assert_eq!(plain, NextMove::new(now(), false));
    }
}
