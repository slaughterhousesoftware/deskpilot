//! Merging the desk's (late) log with the moves seen live in the status register.

use jiff::SignedDuration;

use crate::history::{Event, EventKind};
use crate::time::seconds;

/// The log's minute stamps are coarse (whole minutes) and late, so a logged move counts
/// as "the same move" as an observed one if it lands anywhere in this window around it.
pub const DEDUPE_WINDOW: SignedDuration = seconds(180);

/// Merges the log's events with the live-detected moves. When an observed move dedupes
/// against a logged move (same direction, within `DEDUPE_WINDOW`), the *logged* event
/// survives, keeping its byte offset and kind, but its date is replaced with the observed
/// move's, which is precise to the second; the log only stamps whole minutes, coarse enough
/// to throw the countdown off by up to a minute (observed live: predicted stand 19:33:31
/// against an actual 19:34:50).
///
/// The sort is stable: events sharing a timestamp (the log stamps a whole minute of entries
/// identically) keep the order they were decoded in, and an unmatched observed move lands
/// after the logged events of the same instant.
pub fn merge_observed_moves(logged: &[Event], observed: &[Event]) -> Vec<Event> {
    if observed.is_empty() {
        return logged.to_vec();
    }
    let mut merged = logged.to_vec();
    let mut claimed = vec![false; merged.len()];
    let mut kept = Vec::new();
    for candidate in observed {
        let EventKind::Move { to_standing } = candidate.kind else {
            kept.push(*candidate);
            continue;
        };
        let matching = merged.iter().enumerate().position(|(index, event)| {
            !claimed[index]
                && matches!(event.kind, EventKind::Move { to_standing: logged } if logged == to_standing)
                && event.date.duration_since(candidate.date).abs() <= DEDUPE_WINDOW
        });
        match matching {
            Some(index) => {
                claimed[index] = true;
                merged[index].date = candidate.date;
            }
            None => kept.push(*candidate),
        }
    }
    merged.extend(kept);
    merged.sort_by_key(|e| e.date);
    merged
}

#[cfg(test)]
mod tests {
    use super::*;
    use jiff::Timestamp;

    fn now() -> Timestamp {
        Timestamp::from_second(1_800_000_000).unwrap()
    }
    fn observed(offset: i64, to_standing: bool) -> Event {
        Event::synthetic(now() + seconds(offset), EventKind::Move { to_standing })
    }

    #[test]
    fn dedupes_within_three_minutes() {
        let logged = [Event::new(8, now(), EventKind::Move { to_standing: true })];
        let near = merge_observed_moves(&logged, &[observed(120, true)]);
        assert_eq!(
            near,
            [Event::new(
                8,
                now() + seconds(120),
                EventKind::Move { to_standing: true }
            )]
        );
        let far = merge_observed_moves(&logged, &[observed(300, true)]);
        assert_eq!(far.len(), 2);
        assert_eq!(
            far.iter().map(|e| e.date).collect::<Vec<_>>(),
            [now(), now() + seconds(300)]
        );
        let opposite = merge_observed_moves(&logged, &[observed(60, false)]);
        assert_eq!(opposite.len(), 2);
        assert_eq!(
            opposite.last().unwrap().kind,
            EventKind::Move { to_standing: false }
        );
        assert_eq!(merge_observed_moves(&logged, &[]), logged);
    }

    #[test]
    fn uses_the_observed_date_for_a_deduped_move() {
        let logged = [Event::new(8, now(), EventKind::Move { to_standing: true })];
        let merged = merge_observed_moves(&logged, &[observed(50, true)]);
        assert_eq!(
            merged,
            [Event::new(
                8,
                now() + seconds(50),
                EventKind::Move { to_standing: true }
            )]
        );
    }

    #[test]
    fn unmatched_observed_move_lands_after_logged_events_of_the_same_instant() {
        let logged = [
            Event::new(0, now(), EventKind::Presence { present: true }),
            Event::new(2, now(), EventKind::HeightChange { inches: 41 }),
        ];
        let merged = merge_observed_moves(&logged, &[observed(0, true)]);
        assert_eq!(
            merged.iter().map(|e| e.byte_offset).collect::<Vec<_>>(),
            [0, 2, -1]
        );
    }
}
