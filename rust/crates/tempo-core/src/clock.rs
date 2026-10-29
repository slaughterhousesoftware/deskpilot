//! Turning the desk's "minutes since power-on" counter into wall-clock dates.
//!
//! The desk timestamps history entries as minutes since power-on mod 256, so dating them
//! needs one anchor pairing a reading of register 32 with the wall clock. The anchor is
//! deliberately *not* refreshed on every poll: re-anchoring with the same minute value but
//! a later date slides every event date forward, which made the countdown freeze for a
//! minute and then jump. It moves on connect, on a resync (power cycle), on the first
//! observed minute tick (phase lock), and when it is nearly stale.

use jiff::{SignedDuration, Timestamp};

use crate::time::{minutes, seconds};

/// Re-anchor once the anchor is this old: the minute counter wraps at 256, and dating walks
/// backwards from the anchor, so it must be refreshed well inside one wrap.
const STALE_AFTER: SignedDuration = minutes(200);

/// Two reads this close together that straddle a tick pin the tick to within the gap.
const PHASE_LOCK_WINDOW: SignedDuration = seconds(15);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ResyncReason {
    /// The ring-buffer write pointer regressed: a literal wraparound or a reboot.
    Pointer,
    /// Minutes-since-boot regressed: the desk rebooted, even if its write pointer happens
    /// to still read higher than what was already consumed under the old boot.
    Minutes,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct Observation {
    pub resync: Option<ResyncReason>,
    pub phase_locked: bool,
}

#[derive(Clone, Debug)]
pub struct HistoryClock {
    anchor_minutes: u32,
    anchor_date: Timestamp,
    /// The most recent reading, refreshed on every observation whether or not new bytes
    /// arrived. `date_entries` assumes every entry is at or before its reference minute,
    /// walking backward, so dating against the *pinned* anchor misdates by a full wrap any
    /// entry stamped after the anchor was taken. `projected_now` fixes that.
    latest_minutes: u32,
    last_minute_read: Option<(u32, Timestamp)>,
    phase_locked: bool,
}

impl Default for HistoryClock {
    fn default() -> Self {
        Self::new()
    }
}

impl HistoryClock {
    pub fn new() -> Self {
        Self {
            anchor_minutes: 0,
            anchor_date: Timestamp::MIN,
            latest_minutes: 0,
            last_minute_read: None,
            phase_locked: false,
        }
    }

    /// Pins `minutes` to `now`. Clears the phase lock: the next tick re-locks.
    pub fn anchor(&mut self, minutes: u32, now: Timestamp) {
        self.anchor_minutes = minutes;
        self.latest_minutes = minutes;
        self.anchor_date = now;
        self.last_minute_read = Some((minutes, now));
        self.phase_locked = false;
    }

    /// One history poll's reading of registers 32 and 44, taken *before* ingesting new
    /// bytes. On a resync the clock is re-anchored here; the caller must discard everything
    /// derived from the previous boot session.
    pub fn observe(
        &mut self,
        minutes: u32,
        write_pointer: usize,
        bytes_read: usize,
        now: Timestamp,
    ) -> Observation {
        self.latest_minutes = minutes;
        let resync = if write_pointer < bytes_read {
            Some(ResyncReason::Pointer)
        } else if minutes < self.anchor_minutes {
            Some(ResyncReason::Minutes)
        } else {
            None
        };
        if resync.is_some() {
            // A fresh boot can have an empty log; re-anchor regardless, otherwise the
            // "minutes regressed" check re-fires on every poll.
            self.anchor(minutes, now);
            return Observation {
                resync,
                phase_locked: false,
            };
        }
        let mut phase_locked = false;
        if let (false, Some((last_minutes, last_at))) = (self.phase_locked, self.last_minute_read) {
            let gap = now.duration_since(last_at);
            if minutes == last_minutes + 1 && gap < PHASE_LOCK_WINDOW {
                // The counter ticked between the last two reads, so the tick happened inside
                // the gap: date entries to the middle of their minute (error within 30 s)
                // instead of to wherever in the minute the connection-time read landed
                // (error up to 60 s, different on every restart). Locked once per anchor:
                // re-locking every minute would jitter every derived date by the poll spacing.
                let rollover = last_at + gap / 2;
                self.anchor_minutes = minutes;
                self.anchor_date = rollover + seconds(30);
                self.phase_locked = true;
                phase_locked = true;
            }
        }
        self.last_minute_read = Some((minutes, now));
        Observation {
            resync: None,
            phase_locked,
        }
    }

    /// `now` as the desk would see it: the anchor projected forward by however far the
    /// counter has ticked since. Already-dated entries don't move as it advances, because
    /// `latest_minutes` and the backward walk's first step advance together.
    pub fn projected_now(&self) -> Timestamp {
        self.anchor_date + minutes(i64::from(self.latest_minutes) - i64::from(self.anchor_minutes))
    }

    pub const fn latest_minutes(&self) -> u32 {
        self.latest_minutes
    }

    pub const fn anchor_minutes(&self) -> u32 {
        self.anchor_minutes
    }

    pub const fn anchor_date(&self) -> Timestamp {
        self.anchor_date
    }

    pub const fn is_phase_locked(&self) -> bool {
        self.phase_locked
    }

    /// Keep the anchor until it is nearly stale: re-anchoring shifts every event by the
    /// seconds-of-minute jitter, and the anchor is valid for 256 minutes.
    pub fn is_stale(&self, now: Timestamp) -> bool {
        now.duration_since(self.anchor_date) > STALE_AFTER
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn t0() -> Timestamp {
        Timestamp::from_second(1_800_000_000).unwrap()
    }

    #[test]
    fn resyncs_on_pointer_regression_and_on_minutes_regression() {
        let mut clock = HistoryClock::new();
        clock.anchor(5883, t0());
        assert_eq!(
            clock.observe(5883, 4, 4, t0() + seconds(5)),
            Observation::default()
        );
        let o = clock.observe(5884, 2, 4, t0() + seconds(10));
        assert_eq!(o.resync, Some(ResyncReason::Pointer));
        assert_eq!(clock.anchor_minutes(), 5884);
        assert_eq!(clock.anchor_date(), t0() + seconds(10));
        let o = clock.observe(10, 6, 4, t0() + seconds(15));
        assert_eq!(o.resync, Some(ResyncReason::Minutes));
        assert_eq!(clock.anchor_minutes(), 10);
        // Not again on the next poll with the same readings.
        assert_eq!(clock.observe(10, 6, 6, t0() + seconds(20)).resync, None);
    }

    #[test]
    fn phase_locks_on_the_first_tick_to_the_middle_of_the_minute() {
        let mut clock = HistoryClock::new();
        clock.anchor(100, t0());
        assert!(!clock.observe(100, 0, 0, t0() + seconds(20)).phase_locked);
        let o = clock.observe(101, 0, 0, t0() + seconds(25));
        assert!(o.phase_locked);
        // Rollover estimated at +22.5 s; entries dated to mid-minute, 30 s later.
        assert_eq!(
            clock.anchor_date(),
            t0() + seconds(22) + SignedDuration::from_millis(500) + seconds(30)
        );
        assert_eq!(clock.anchor_minutes(), 101);
        // Locked once per anchor.
        assert!(!clock.observe(102, 0, 0, t0() + seconds(85)).phase_locked);
        assert_eq!(clock.anchor_minutes(), 101);
    }

    #[test]
    fn does_not_lock_across_a_long_gap_or_a_skipped_minute() {
        let mut clock = HistoryClock::new();
        clock.anchor(100, t0());
        assert!(
            !clock.observe(101, 0, 0, t0() + seconds(40)).phase_locked,
            "a 40 s gap can't pin the tick"
        );
        clock.anchor(100, t0());
        assert!(
            !clock.observe(102, 0, 0, t0() + seconds(5)).phase_locked,
            "two ticks in 5 s: the reads are unreliable"
        );
    }

    #[test]
    fn projection_advances_with_the_counter_without_moving_the_anchor() {
        let mut clock = HistoryClock::new();
        clock.anchor(5883, t0());
        assert_eq!(clock.projected_now(), t0());
        clock.observe(5885, 0, 0, t0() + seconds(130));
        assert_eq!(clock.anchor_date(), t0());
        assert_eq!(clock.projected_now(), t0() + minutes(2));
        assert!(!clock.is_stale(t0() + minutes(199)));
        assert!(clock.is_stale(t0() + minutes(201)));
    }
}
