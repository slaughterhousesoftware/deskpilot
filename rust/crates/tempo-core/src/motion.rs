//! Live move detection from the status register.
//!
//! The desk writes its history log *late*: an automatic stand at 15:46 was still not
//! readable through the write pointer at 15:54 (docs/protocol.md, "Write latency"). The
//! status register is live, though, so posture changes are detected from it and fed into
//! the rollup as synthetic moves, which keeps the countdown and the stands counter honest
//! until the log catches up.

use jiff::{SignedDuration, Timestamp};

use crate::registers::StatusWord;
use crate::time::seconds;

/// The sitting and standing presets, in tenths of an inch. Only meaningful when the sitting
/// preset is set and below the standing one; `Presets::sane` checks that.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Presets {
    pub sitting_tenths: u16,
    pub standing_tenths: u16,
}

impl Presets {
    pub const fn sane(self) -> bool {
        self.sitting_tenths > 0 && self.standing_tenths > self.sitting_tenths
    }

    pub const fn midpoint_tenths(self) -> u16 {
        (self.sitting_tenths + self.standing_tenths) / 2
    }

    /// Whole-inch midpoint of the presets, rounded, so the rollup can tell a real stand from
    /// a paddle nudge that never crossed it. `None` when the presets aren't sane yet.
    pub const fn standing_threshold_inches(self) -> Option<u8> {
        if self.sane() {
            Some(((self.midpoint_tenths() + 5) / 10) as u8)
        } else {
            None
        }
    }

    /// Posture of a height against the midpoint. `None` when the presets aren't sane.
    pub const fn posture(self, height_tenths: u16) -> Option<bool> {
        if self.sane() {
            Some(height_tenths >= self.midpoint_tenths())
        } else {
            None
        }
    }

    /// A garbled read (a dropped or corrupted GATT notification decodes to whatever bytes
    /// were in the packet) can land far outside the desk's actual travel.
    const fn is_plausible(self, height_tenths: u16) -> bool {
        height_tenths + 100 >= self.sitting_tenths && height_tenths <= self.standing_tenths + 100
    }
}

/// A posture change seen live, dated at the motor start when one was seen recently (that
/// is what the desk's own timer counts from), else at the settle.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ObservedMove {
    pub at: Timestamp,
    pub to_standing: bool,
    pub settled_height: u16,
    pub previous_height: u16,
    pub settled: bool,
    pub jumped: bool,
}

/// What one status sample produced.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct Observation {
    /// False for an implausible reading, which the caller must not publish.
    pub publish: bool,
    pub moved: Option<ObservedMove>,
    /// The motion bit just rose from rest; carries how far the height had already travelled
    /// (tenths), for measuring the desk's countdown-to-motor against a live-read entry.
    pub motor_started: Option<u16>,
    /// The motor ran and stopped without the posture changing: a nudge, or a move the user
    /// reversed before it got to the other preset.
    pub aborted: bool,
}

/// A settle or jump was just detected but not yet trusted: the height it implies the desk
/// ended up at hasn't been confirmed by a second, matching sample yet.
#[derive(Clone, Copy, Debug)]
struct PendingSettle {
    height: u16,
    settled: bool,
    jumped: bool,
    previous_height: u16,
}

#[derive(Clone, Debug)]
pub struct MotionTracker {
    /// How long a sample's height must go unchanged before it is trusted as final, both for
    /// polling cadence and for refusing a preset capture.
    settle_grace: SignedDuration,
    last_status: Option<StatusWord>,
    last_known_posture: Option<bool>,
    /// Wall clock of the most recent sample whose height differed from the one before. The
    /// desk can clear the motion bit while still travelling (observed live: last moving
    /// sample 40.5 in, settled at 41.1 in about a second later), so "not moving" alone
    /// isn't proof the height is final.
    last_height_change_at: Option<Timestamp>,
    /// When the current stretch of motion began (the motion bit rising from rest): the desk
    /// times its rhythm from when the motor starts, not from when it settles ~8 s later.
    motion_started_at: Option<Timestamp>,
    pending: Option<PendingSettle>,
}

impl MotionTracker {
    pub fn new(settle_grace: SignedDuration) -> Self {
        Self {
            settle_grace,
            last_status: None,
            last_known_posture: None,
            last_height_change_at: None,
            motion_started_at: None,
            pending: None,
        }
    }

    /// Drops everything: after a reconnect or a power cycle the next status poll
    /// re-establishes the posture.
    pub fn forget(&mut self) {
        self.last_status = None;
        self.last_known_posture = None;
        self.pending = None;
        self.motion_started_at = None;
    }

    pub const fn last_status(&self) -> Option<StatusWord> {
        self.last_status
    }

    pub const fn last_known_posture(&self) -> Option<bool> {
        self.last_known_posture
    }

    /// A logged move only gets to set the posture live readings are compared against once
    /// it has taken its place in the merged, date-sorted timeline; see the session.
    pub fn set_known_posture(&mut self, to_standing: bool) {
        self.last_known_posture = Some(to_standing);
    }

    pub const fn motion_started_at(&self) -> Option<Timestamp> {
        self.motion_started_at
    }

    pub const fn has_pending_settle(&self) -> bool {
        self.pending.is_some()
    }

    /// True while the height changed less than `settle_grace` ago on the wall clock.
    pub fn is_settling(&self, wall: Timestamp) -> bool {
        self.last_height_change_at
            .is_some_and(|at| wall.duration_since(at) < self.settle_grace)
    }

    /// Turns status-register transitions into live moves. `now` is business time (dates
    /// the move); `wall` is a clock that always advances (settle timing).
    ///
    /// A move is "done" when the motion bit falls from 1 to 0. As a defence against a move
    /// that starts and finishes between two polls, a height jump of at least 2 inches
    /// between consecutive stationary readings counts too. Neither is trusted immediately:
    /// the desk can clear the motion bit before it has stopped travelling, so a detected
    /// settle or jump only becomes a recorded move once a *second* sample confirms the same
    /// height, and posture is classified from that confirmed height. Only a *change* of
    /// posture is recorded: the desk nudging itself within one posture is not a move.
    pub fn observe(
        &mut self,
        word: StatusWord,
        presets: Option<Presets>,
        now: Timestamp,
        wall: Timestamp,
    ) -> Observation {
        let Some(presets) = presets.filter(|p| p.sane()) else {
            self.last_status = Some(word);
            return Observation {
                publish: true,
                ..Default::default()
            };
        };
        if !presets.is_plausible(word.height_tenths) {
            // Dropped before `last_status` is touched, so the next real reading is compared
            // against the last real one; letting it through would make the next reading
            // look like a settle or jump and record a move nothing in the log will dedupe.
            return Observation {
                publish: false,
                ..Default::default()
            };
        }
        let observation = self.step(word, presets, now, wall);
        self.last_status = Some(word);
        observation
    }

    fn step(
        &mut self,
        word: StatusWord,
        presets: Presets,
        now: Timestamp,
        wall: Timestamp,
    ) -> Observation {
        let mut out = Observation {
            publish: true,
            ..Default::default()
        };
        let posture = word.height_tenths >= presets.midpoint_tenths();
        // The first reading of a connection only establishes where the desk is.
        let Some(previous) = self.last_status else {
            self.last_known_posture = Some(posture);
            return out;
        };
        if word.height_tenths != previous.height_tenths {
            self.last_height_change_at = Some(wall);
        }
        // The motion bit, not the height: the desk's pre-move pulse is a one-tenth height
        // blip with the motion bit clear, about 7 s after the beep starts, and dating the
        // move there would put the anchor ~6 s ahead of the motor.
        if self.pending.is_none()
            && self.motion_started_at.is_none()
            && word.is_moving
            && !previous.is_moving
        {
            self.motion_started_at = Some(now);
            out.motor_started = Some(word.height_tenths.abs_diff(previous.height_tenths));
        }
        let Some(known) = self.last_known_posture else {
            self.last_known_posture = Some(posture);
            return out;
        };
        if let Some(mut pending) = self.pending {
            // Confirmed: two consecutive samples at the same height. The motion bit is not
            // trusted either way here - the desk clearing it early, mid-travel, is exactly
            // the bug this guards against, but a stray moving=true blip on an otherwise
            // matching sample shouldn't discard a real confirmation.
            if word.height_tenths == pending.height {
                let settled_posture = pending.height >= presets.midpoint_tenths();
                if known != settled_posture {
                    out.moved = Some(self.record(settled_posture, pending, now));
                }
                self.pending = None;
                self.motion_started_at = None;
            } else {
                pending.height = word.height_tenths;
                self.pending = Some(pending);
            }
            return out;
        }
        let settled = previous.is_moving && !word.is_moving;
        let jumped = !previous.is_moving
            && !word.is_moving
            && word.height_tenths.abs_diff(previous.height_tenths) >= 20;
        if (settled || jumped) && known != posture {
            self.pending = Some(PendingSettle {
                height: word.height_tenths,
                settled,
                jumped,
                previous_height: previous.height_tenths,
            });
        } else if settled {
            // Stopped where it started, posture-wise. The motor start must not linger: it
            // would date the next real move and block a waved-off countdown's dismissal.
            out.aborted = true;
            self.motion_started_at = None;
        }
        out
    }

    fn record(
        &mut self,
        to_standing: bool,
        pending: PendingSettle,
        now: Timestamp,
    ) -> ObservedMove {
        let at = self
            .motion_started_at
            .filter(|started| now.duration_since(*started) < seconds(60))
            .unwrap_or(now);
        self.last_known_posture = Some(to_standing);
        ObservedMove {
            at,
            to_standing,
            settled_height: pending.height,
            previous_height: pending.previous_height,
            settled: pending.settled,
            jumped: pending.jumped,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const PRESETS: Presets = Presets {
        sitting_tenths: 266,
        standing_tenths: 411,
    };
    fn t0() -> Timestamp {
        Timestamp::from_second(1_800_000_000).unwrap()
    }
    fn tracker() -> MotionTracker {
        MotionTracker::new(seconds(1))
    }
    fn word(raw: u32) -> StatusWord {
        StatusWord::from_raw(raw)
    }

    #[test]
    fn threshold_and_posture() {
        assert_eq!(PRESETS.standing_threshold_inches(), Some(34));
        assert_eq!(PRESETS.posture(267), Some(false));
        assert_eq!(PRESETS.posture(411), Some(true));
        assert_eq!(
            Presets {
                sitting_tenths: 0,
                standing_tenths: 411
            }
            .standing_threshold_inches(),
            None
        );
    }

    #[test]
    fn first_reading_is_not_a_move_and_presets_unknown_publishes() {
        let mut t = tracker();
        let o = t.observe(word(0x010B), None, t0(), t0());
        assert!(o.publish && o.moved.is_none());
        let o = t.observe(word(0x019B), Some(PRESETS), t0(), t0());
        assert!(
            o.publish && o.moved.is_none(),
            "first classified reading only establishes posture"
        );
        assert_eq!(t.last_known_posture(), Some(true));
    }

    #[test]
    fn settle_after_motion_records_a_move_dated_at_the_motor_start() {
        let mut t = tracker();
        t.observe(word(0x010B), Some(PRESETS), t0(), t0());
        let rise = t.observe(
            word(0x8000_0150),
            Some(PRESETS),
            t0() + seconds(13),
            t0() + seconds(13),
        );
        assert_eq!(rise.motor_started, Some(0x150 - 0x10B));
        assert_eq!(t.motion_started_at(), Some(t0() + seconds(13)));
        let stop = t.observe(
            word(0x019B),
            Some(PRESETS),
            t0() + seconds(21),
            t0() + seconds(21),
        );
        assert!(stop.moved.is_none(), "needs a confirming sample");
        assert!(t.has_pending_settle());
        let confirm = t.observe(
            word(0x019B),
            Some(PRESETS),
            t0() + seconds(22),
            t0() + seconds(22),
        );
        let moved = confirm.moved.expect("second matching sample confirms");
        assert_eq!(moved.at, t0() + seconds(13));
        assert!(moved.to_standing && moved.settled && !moved.jumped);
        assert_eq!(moved.settled_height, 411);
        assert!(!t.has_pending_settle());
        assert_eq!(t.motion_started_at(), None);
    }

    #[test]
    fn height_jump_between_stationary_readings_counts() {
        let mut t = tracker();
        t.observe(word(0x010B), Some(PRESETS), t0(), t0());
        assert!(t
            .observe(
                word(0x019B),
                Some(PRESETS),
                t0() + seconds(1),
                t0() + seconds(1)
            )
            .moved
            .is_none());
        let moved = t
            .observe(
                word(0x019B),
                Some(PRESETS),
                t0() + seconds(2),
                t0() + seconds(2),
            )
            .moved
            .unwrap();
        assert!(moved.jumped && !moved.settled && moved.to_standing);
        assert_eq!(
            moved.at,
            t0() + seconds(2),
            "no motor start seen: dated at the settle"
        );
    }

    #[test]
    fn clearing_the_motion_bit_early_keeps_waiting_until_the_height_holds() {
        let mut t = tracker();
        t.observe(word(0x010B), Some(PRESETS), t0(), t0());
        t.observe(
            word(0x8000_0190),
            Some(PRESETS),
            t0() + seconds(1),
            t0() + seconds(1),
        );
        t.observe(
            word(0x0190),
            Some(PRESETS),
            t0() + seconds(2),
            t0() + seconds(2),
        );
        for (i, h) in [0x195u32, 0x199, 0x19D].iter().enumerate() {
            let wall = t0() + seconds(3 + i as i64);
            assert!(t
                .observe(word(*h), Some(PRESETS), wall, wall)
                .moved
                .is_none());
            assert!(t.is_settling(wall));
            assert!(t.has_pending_settle());
        }
        assert!(!t.is_settling(t0() + seconds(10)));
        let moved = t
            .observe(
                word(0x19D),
                Some(PRESETS),
                t0() + seconds(10),
                t0() + seconds(10),
            )
            .moved
            .unwrap();
        assert_eq!(
            moved.settled_height, 0x19D,
            "classified from the confirmed height, not the triggering one"
        );
    }

    #[test]
    fn implausible_reading_is_dropped_without_touching_state() {
        let mut t = tracker();
        t.observe(word(0x010B), Some(PRESETS), t0(), t0());
        let o = t.observe(
            word(0xDEAD_BEEF),
            Some(PRESETS),
            t0() + seconds(1),
            t0() + seconds(1),
        );
        assert!(!o.publish && o.moved.is_none());
        assert_eq!(t.last_status(), Some(word(0x010B)));
        let o = t.observe(
            word(0x010B),
            Some(PRESETS),
            t0() + seconds(2),
            t0() + seconds(2),
        );
        assert!(o.publish && o.moved.is_none() && !t.has_pending_settle());
    }

    #[test]
    fn nudging_within_one_posture_is_not_a_move() {
        let mut t = tracker();
        t.observe(word(0x010B), Some(PRESETS), t0(), t0());
        t.observe(
            word(0x8000_0110),
            Some(PRESETS),
            t0() + seconds(1),
            t0() + seconds(1),
        );
        t.observe(
            word(0x0122),
            Some(PRESETS),
            t0() + seconds(2),
            t0() + seconds(2),
        );
        assert!(t
            .observe(
                word(0x0122),
                Some(PRESETS),
                t0() + seconds(3),
                t0() + seconds(3)
            )
            .moved
            .is_none());
        assert_eq!(t.last_known_posture(), Some(false));
    }
}
