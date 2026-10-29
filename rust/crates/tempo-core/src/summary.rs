//! The one-sentence answer for "what's my Tempo status", built from the snapshot so it says
//! the same thing a widget shows.

use jiff::{SignedDuration, Timestamp};

use crate::format;
use crate::model::Snapshot;

pub const DISCONNECTED: &str = "Tempo isn't connected to the desk.";

pub fn sentence(snapshot: Option<&Snapshot>, now: Timestamp) -> String {
    let Some(s) = snapshot.filter(|s| s.connected && !s.is_stale(now)) else {
        return DISCONNECTED.to_string();
    };
    // At-desk time grows while present between snapshot writes, as in the widget.
    let since_write = now.duration_since(s.updated_at).max(SignedDuration::ZERO);
    let at_desk = s.at_desk_seconds
        + if s.is_present {
            since_write
        } else {
            SignedDuration::ZERO
        };
    let today = format!(
        "{} at the desk and {} stands today.",
        format::duration(at_desk),
        s.stands_today
    );
    if !s.is_present {
        return format!("You're away from the desk. {today}");
    }
    let posture = format!(
        "You're {} at {}.",
        if s.is_standing == Some(true) {
            "standing"
        } else {
            "sitting"
        },
        format::height(s.height_tenths)
    );
    let next = match s.next_move {
        Some(m) => {
            let verb = if m.to_standing { "stand" } else { "sit" };
            // The countdown runs to the beep, like the app's; past that the desk decides.
            if m.announce_at() > now {
                format!(
                    "Next {verb} in {}.",
                    format::countdown_minutes(m.announce_at(), now)
                )
            } else {
                format!("Next {verb} any moment.")
            }
        }
        None if s.paused => "Cruise control is paused.".to_string(),
        None => "Cruise control is off.".to_string(),
    };
    format!("{posture} {today} {next}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cruise::CruiseSlot;
    use crate::rollup::{NextMove, BEEP};
    use crate::time::seconds;

    fn now() -> Timestamp {
        Timestamp::from_second(1_800_000_000).unwrap()
    }

    fn snapshot(
        connected: bool,
        present: bool,
        standing: Option<bool>,
        next_move: Option<NextMove>,
        paused: bool,
        age: i64,
    ) -> Snapshot {
        Snapshot {
            updated_at: now() - seconds(age),
            connected,
            height_tenths: Some(411),
            is_moving: false,
            is_present: present,
            is_standing: standing,
            at_desk_seconds: seconds(3 * 3600 + 20 * 60),
            stands_today: 6,
            next_move,
            paused,
            cruise: Some(CruiseSlot::new(1200, 1200)),
            sitting_height_tenths: Some(266),
            standing_height_tenths: Some(411),
        }
    }

    #[test]
    fn standing_with_a_countdown() {
        let next = NextMove::new(now() + seconds(11 * 60) + BEEP, false);
        assert_eq!(
            sentence(
                Some(&snapshot(true, true, Some(true), Some(next), false, 0)),
                now()
            ),
            "You're standing at 41.1\". 3h 20m at the desk and 6 stands today. Next sit in 11m."
        );
    }

    #[test]
    fn sitting_with_an_overdue_move() {
        let next = NextMove::new(now() - seconds(120), true);
        assert_eq!(
            sentence(Some(&snapshot(true, true, Some(false), Some(next), false, 0)), now()),
            "You're sitting at 41.1\". 3h 20m at the desk and 6 stands today. Next stand any moment."
        );
    }

    #[test]
    fn paused_and_cruise_off() {
        assert_eq!(
            sentence(Some(&snapshot(true, true, Some(true), None, true, 0)), now()),
            "You're standing at 41.1\". 3h 20m at the desk and 6 stands today. Cruise control is paused."
        );
        let mut off = snapshot(true, true, Some(false), None, false, 0);
        off.height_tenths = Some(266);
        off.at_desk_seconds = seconds(60);
        off.stands_today = 0;
        off.cruise = None;
        assert_eq!(
            sentence(Some(&off), now()),
            "You're sitting at 26.6\". 1m at the desk and 0 stands today. Cruise control is off."
        );
    }

    #[test]
    fn away() {
        assert_eq!(
            sentence(
                Some(&snapshot(true, false, Some(true), None, false, 0)),
                now()
            ),
            "You're away from the desk. 3h 20m at the desk and 6 stands today."
        );
    }

    #[test]
    fn disconnected_missing_and_stale() {
        assert_eq!(sentence(None, now()), DISCONNECTED);
        assert_eq!(
            sentence(
                Some(&snapshot(false, true, Some(true), None, false, 0)),
                now()
            ),
            DISCONNECTED
        );
        assert_eq!(
            sentence(
                Some(&snapshot(true, true, Some(true), None, false, 121)),
                now()
            ),
            DISCONNECTED
        );
    }
}
