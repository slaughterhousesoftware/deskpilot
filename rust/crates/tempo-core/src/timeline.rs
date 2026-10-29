//! Posture segments and per-day totals, for charts. Shares its state machine rules with
//! `rollup` so the two can never disagree about presence or posture.

use jiff::tz::TimeZone;
use jiff::{SignedDuration, Span, Timestamp};
use serde::{Deserialize, Serialize};

use crate::history::{Event, EventKind};
use crate::rollup::resolved_posture;
use crate::time::{duration_seconds, iso8601_seconds};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, Hash)]
#[serde(rename_all = "lowercase")]
pub enum PostureState {
    Standing,
    Sitting,
    Away,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Segment {
    #[serde(with = "iso8601_seconds")]
    pub start: Timestamp,
    #[serde(with = "iso8601_seconds")]
    pub end: Timestamp,
    pub state: PostureState,
}

impl Segment {
    pub const fn new(start: Timestamp, end: Timestamp, state: PostureState) -> Self {
        Self { start, end, state }
    }

    pub fn duration(&self) -> SignedDuration {
        self.end.duration_since(self.start)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DayTotals {
    #[serde(with = "iso8601_seconds")]
    pub day: Timestamp,
    #[serde(with = "duration_seconds")]
    pub standing: SignedDuration,
    #[serde(with = "duration_seconds")]
    pub sitting: SignedDuration,
    #[serde(with = "duration_seconds")]
    pub away: SignedDuration,
    pub stands: u32,
}

#[derive(Clone, Copy)]
struct Breakpoint {
    date: Timestamp,
    state: PostureState,
}

#[derive(Clone, Copy)]
struct ResolvedMove {
    date: Timestamp,
    to_standing: bool,
}

struct Walk {
    breakpoints: Vec<Breakpoint>,
    moves: Vec<ResolvedMove>,
}

/// The single state machine shared by `segments` and `totals`. Mirrors the rollup's
/// per-event handling: absent -> away, present/countdown/move -> present, a move's posture
/// from an immediately preceding height change when a threshold is known, and posture while
/// present with no move yet is unknown -> sitting.
fn walk(events: &[Event], threshold: Option<u8>) -> Walk {
    let mut present;
    let mut is_standing: Option<bool> = None;
    let mut breakpoints = Vec::new();
    let mut moves = Vec::new();
    let state = |present: bool, is_standing: Option<bool>| {
        if !present {
            PostureState::Away
        } else if is_standing == Some(true) {
            PostureState::Standing
        } else {
            PostureState::Sitting
        }
    };
    for (index, event) in events.iter().enumerate() {
        match event.kind {
            EventKind::Presence { present: p } => {
                present = p;
            }
            EventKind::Countdown { .. } => {
                present = true;
            }
            EventKind::Move {
                to_standing: raise_bit,
            } => {
                present = true;
                let to_standing = resolved_posture(events, index, raise_bit, threshold);
                is_standing = Some(to_standing);
                moves.push(ResolvedMove {
                    date: event.date,
                    to_standing,
                });
            }
            EventKind::HeightChange { .. }
            | EventKind::UserChange { .. }
            | EventKind::Nop { .. } => continue,
        }
        breakpoints.push(Breakpoint {
            date: event.date,
            state: state(present, is_standing),
        });
    }
    Walk { breakpoints, moves }
}

/// Turns a chronological breakpoint list into contiguous segments covering [from, to),
/// clipping breakpoints outside the window and merging adjacent equal states.
fn clipped_segments(breakpoints: &[Breakpoint], from: Timestamp, to: Timestamp) -> Vec<Segment> {
    if to <= from {
        return Vec::new();
    }
    let mut segments = Vec::new();
    let mut state = PostureState::Away;
    let mut segment_start = from;
    for point in breakpoints {
        if point.date >= to {
            break;
        }
        if point.state == state {
            continue;
        }
        let clipped = point.date.max(from).min(to);
        if clipped > segment_start {
            segments.push(Segment::new(segment_start, clipped, state));
        }
        state = point.state;
        segment_start = clipped;
    }
    if to > segment_start {
        segments.push(Segment::new(segment_start, to, state));
    }
    segments
}

/// The rollup's "genuine sitting->standing transition" rule, scoped to one day.
fn stands(moves: &[ResolvedMove], day_start: Timestamp, day_end: Timestamp) -> u32 {
    let mut seed: Option<bool> = None;
    let mut count = 0;
    for m in moves {
        if m.date < day_start {
            seed = Some(m.to_standing);
            continue;
        }
        if m.date >= day_end {
            break;
        }
        if m.to_standing && seed != Some(true) {
            count += 1;
        }
        seed = Some(m.to_standing);
    }
    count
}

/// Contiguous segments covering [from, to) from chronological events. While away the state
/// is `Away` regardless of posture; adjacent equal states are merged.
pub fn segments(
    events: &[Event],
    from: Timestamp,
    to: Timestamp,
    threshold: Option<u8>,
) -> Vec<Segment> {
    clipped_segments(&walk(events, threshold).breakpoints, from, to)
}

/// The calendar day after `day_start` in `tz`: across a daylight-saving change a fixed
/// 86 400 s runs an hour past or short of the boundary and would leak an hour of the
/// neighbouring day into the totals twice a year.
pub fn next_day(day_start: Timestamp, tz: &TimeZone) -> Timestamp {
    day_start
        .to_zoned(tz.clone())
        .checked_add(Span::new().days(1))
        .map(|z| z.timestamp())
        .unwrap_or(day_start + SignedDuration::from_hours(24))
}

/// Totals per day for the given day starts, each clipped to `[day_start, next day)` and to
/// `now`, so an unfinished day totals only what has happened so far.
pub fn totals(
    events: &[Event],
    day_starts: &[Timestamp],
    threshold: Option<u8>,
    now: Timestamp,
    tz: &TimeZone,
) -> Vec<DayTotals> {
    let walked = walk(events, threshold);
    day_starts
        .iter()
        .map(|&day_start| {
            let day_end = next_day(day_start, tz);
            let mut totals = DayTotals {
                day: day_start,
                standing: SignedDuration::ZERO,
                sitting: SignedDuration::ZERO,
                away: SignedDuration::ZERO,
                stands: stands(&walked.moves, day_start, day_end),
            };
            for seg in clipped_segments(&walked.breakpoints, day_start, day_end.min(now)) {
                match seg.state {
                    PostureState::Standing => totals.standing += seg.duration(),
                    PostureState::Sitting => totals.sitting += seg.duration(),
                    PostureState::Away => totals.away += seg.duration(),
                }
            }
            totals
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::time::seconds;

    fn day0() -> Timestamp {
        Timestamp::from_second(1_800_000_000).unwrap()
    }
    fn at(offset: i64) -> Timestamp {
        day0() + seconds(offset)
    }
    fn ev(offset: i64, kind: EventKind) -> Event {
        Event::new(0, at(offset), kind)
    }
    fn close(a: SignedDuration, b: i64) -> bool {
        (a - seconds(b)).abs() <= seconds(1)
    }
    const UTC: TimeZone = TimeZone::UTC;

    #[test]
    fn segments_away_present_sitting_standing_clipped_and_merged() {
        let events = [
            ev(3600, EventKind::Presence { present: true }),
            ev(7200, EventKind::Move { to_standing: true }),
            ev(9000, EventKind::Countdown { to_standing: true }),
            ev(10800, EventKind::Presence { present: false }),
            ev(18000, EventKind::Presence { present: true }),
        ];
        let segs = segments(&events, day0(), at(4 * 3600), None);
        assert_eq!(
            segs,
            [
                Segment::new(day0(), at(3600), PostureState::Away),
                Segment::new(at(3600), at(7200), PostureState::Sitting),
                Segment::new(at(7200), at(10800), PostureState::Standing),
                Segment::new(at(10800), at(4 * 3600), PostureState::Away),
            ]
        );
    }

    #[test]
    fn nudge_within_presets_stays_sitting() {
        let events = [
            ev(0, EventKind::Presence { present: true }),
            ev(60, EventKind::HeightChange { inches: 29 }),
            ev(60, EventKind::Move { to_standing: true }),
        ];
        assert_eq!(
            segments(&events, day0(), at(3600), Some(34)),
            [Segment::new(day0(), at(3600), PostureState::Sitting)]
        );
    }

    #[test]
    fn totals_split_segment_spanning_midnight_and_count_stands_per_day() {
        let day2 = at(86_400);
        let events = [
            ev(0, EventKind::Presence { present: true }),
            ev(3600, EventKind::Move { to_standing: true }),
            ev(90_000, EventKind::Move { to_standing: false }),
            ev(93_600, EventKind::Move { to_standing: true }),
        ];
        let t = totals(&events, &[day0(), day2], None, at(100_000), &UTC);
        assert_eq!(t.len(), 2);
        assert_eq!(t[0].day, day0());
        assert!(close(t[0].sitting, 3600));
        assert!(close(t[0].standing, 82_800));
        assert!(close(t[0].away, 0));
        assert_eq!(t[0].stands, 1);
        assert_eq!(t[1].day, day2);
        assert!(close(t[1].standing, 3600 + 6400));
        assert!(close(t[1].sitting, 3600));
        assert!(close(t[1].away, 0));
        assert_eq!(t[1].stands, 1);
    }

    #[test]
    fn totals_clip_to_now_for_an_unfinished_day() {
        let events = [
            ev(0, EventKind::Presence { present: true }),
            ev(60, EventKind::Move { to_standing: true }),
        ];
        let t = totals(&events, &[day0()], None, at(1800), &UTC);
        assert!(close(t[0].standing + t[0].sitting + t[0].away, 1800));
    }

    #[test]
    fn segments_returns_empty_when_to_is_not_after_from() {
        assert!(segments(&[], day0(), day0(), None).is_empty());
    }

    #[test]
    fn next_day_follows_the_calendar_across_dst() {
        let tz = TimeZone::get("America/Los_Angeles").unwrap();
        // 2026-10-31 04:00 PDT is the day boundary; the next one is 25 h later, in PST.
        let start = jiff::civil::date(2026, 10, 31)
            .at(4, 0, 0, 0)
            .to_zoned(tz.clone())
            .unwrap()
            .timestamp();
        assert_eq!(
            next_day(start, &tz).duration_since(start),
            SignedDuration::from_hours(25)
        );
    }
}
