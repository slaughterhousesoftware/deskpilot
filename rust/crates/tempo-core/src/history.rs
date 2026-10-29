//! The desk's history ring buffer: 2-byte `[minute][event]` entries, dated by walking
//! backwards from a `(minutes since power-on, now)` reference across the 256-minute wrap.

use jiff::Timestamp;
use serde::{Deserialize, Serialize};

use crate::registers::MINUTE_WRAP;
use crate::time::{iso8601_seconds, minutes};

/// What one log entry says. Serialises as Swift's `{"type": "...", ...}` shape.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum EventKind {
    Presence {
        present: bool,
    },
    /// The desk announced an upcoming move: it starts beeping and logs this entry.
    #[serde(rename_all = "camelCase")]
    Countdown {
        to_standing: bool,
    },
    /// The desk moved. `to_standing` is the new posture per the raise bit.
    #[serde(rename_all = "camelCase")]
    Move {
        to_standing: bool,
    },
    HeightChange {
        inches: u8,
    },
    UserChange {
        user: u8,
    },
    /// Padding or power-cycle marker. Takes part in dating, never reported.
    Nop {
        raw: u8,
    },
}

impl EventKind {
    pub const fn is_move(self) -> bool {
        matches!(self, EventKind::Move { .. })
    }

    pub const fn is_nop(self) -> bool {
        matches!(self, EventKind::Nop { .. })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RawEntry {
    pub byte_offset: usize,
    pub minute_byte: u8,
    pub kind: EventKind,
}

/// A dated log entry. `byte_offset` is `-1` for events the app synthesised itself (a move
/// seen live in the status register, or an absence closing a power-off gap in the archive).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Event {
    pub byte_offset: i64,
    #[serde(with = "iso8601_seconds")]
    pub date: Timestamp,
    pub kind: EventKind,
}

impl Event {
    pub const SYNTHETIC: i64 = -1;

    pub const fn new(byte_offset: i64, date: Timestamp, kind: EventKind) -> Self {
        Self {
            byte_offset,
            date,
            kind,
        }
    }

    pub const fn synthetic(date: Timestamp, kind: EventKind) -> Self {
        Self::new(Self::SYNTHETIC, date, kind)
    }
}

/// Bit patterns copied from the phone app's `processEntry`.
pub const fn decode_kind(b: u8) -> EventKind {
    let top5 = (b & 0xF8) >> 3;
    let top4 = (b & 0xF0) >> 4;
    let top3 = (b & 0xE0) >> 5;
    if top5 == 11 {
        let raise = b & 0x01 != 0;
        if b & 0x04 != 0 {
            EventKind::Move { to_standing: raise }
        } else {
            EventKind::Countdown { to_standing: raise }
        }
    } else if top5 == 10 {
        EventKind::Presence {
            present: b & 0x01 != 0,
        }
    } else if top4 == 4 {
        EventKind::UserChange { user: b & 0x0F }
    } else if top3 == 1 {
        EventKind::HeightChange {
            inches: 20 + (b & 0x1F),
        }
    } else {
        EventKind::Nop { raw: b }
    }
}

/// Splits ring-buffer bytes into `[minute][event]` pairs. A trailing odd byte is ignored.
pub fn decode_entries(bytes: &[u8], first_byte_offset: usize) -> Vec<RawEntry> {
    bytes
        .chunks_exact(2)
        .enumerate()
        .map(|(i, pair)| RawEntry {
            byte_offset: first_byte_offset + i * 2,
            minute_byte: pair[0],
            kind: decode_kind(pair[1]),
        })
        .collect()
}

/// Assigns dates exactly like the phone app: start at `now` with reference
/// `minutes_since_power_on % 256`, walk backwards, each entry `(reference - minute) mod 256`
/// minutes before the entry after it. NOP entries take part in the chain but are not
/// returned. The result is chronological.
pub fn date_entries(
    entries: &[RawEntry],
    minutes_since_power_on: u32,
    now: Timestamp,
) -> Vec<Event> {
    let mut reference = minutes_since_power_on % MINUTE_WRAP;
    let mut cursor = now;
    let mut dated = Vec::with_capacity(entries.len());
    for entry in entries.iter().rev() {
        let t = u32::from(entry.minute_byte);
        let diff = if reference >= t {
            reference - t
        } else {
            reference + MINUTE_WRAP - t
        };
        cursor -= minutes(i64::from(diff));
        reference = t;
        if entry.kind.is_nop() {
            continue;
        }
        dated.push(Event::new(entry.byte_offset as i64, cursor, entry.kind));
    }
    dated.reverse();
    dated
}

#[cfg(test)]
mod tests {
    use super::*;

    // Bytes captured from the real desk on 2026-09-04 (time byte, event byte pairs).
    // t=209 HEIGHT 31, t=209 MOVE down, t=210 HEIGHT 26, t=210 MOVE down, t=212 present,
    // t=221 countdown up, t=221 HEIGHT 26, t=231 countdown up, t=231 HEIGHT 41, t=231 MOVE up,
    // t=251 countdown down, t=251 HEIGHT 26, t=251 MOVE down
    pub const CAPTURED: [u8; 26] = [
        0xD1, 0x2B, 0xD1, 0x5C, 0xD2, 0x26, 0xD2, 0x5C, 0xD4, 0x51, 0xDD, 0x59, 0xDD, 0x26, 0xE7,
        0x59, 0xE7, 0x35, 0xE7, 0x5D, 0xFB, 0x58, 0xFB, 0x26, 0xFB, 0x5C,
    ];

    fn now() -> Timestamp {
        Timestamp::from_second(1_800_000_000).unwrap()
    }

    #[test]
    fn decode_kind_matches_phone_app_bit_patterns() {
        assert_eq!(decode_kind(0x5D), EventKind::Move { to_standing: true });
        assert_eq!(decode_kind(0x5C), EventKind::Move { to_standing: false });
        assert_eq!(
            decode_kind(0x59),
            EventKind::Countdown { to_standing: true }
        );
        assert_eq!(
            decode_kind(0x58),
            EventKind::Countdown { to_standing: false }
        );
        assert_eq!(decode_kind(0x51), EventKind::Presence { present: true });
        assert_eq!(decode_kind(0x50), EventKind::Presence { present: false });
        assert_eq!(decode_kind(0x40), EventKind::UserChange { user: 0 });
        assert_eq!(decode_kind(0x4A), EventKind::UserChange { user: 10 });
        assert_eq!(decode_kind(0x26), EventKind::HeightChange { inches: 26 });
        assert_eq!(decode_kind(0x35), EventKind::HeightChange { inches: 41 });
        assert_eq!(decode_kind(0x00), EventKind::Nop { raw: 0x00 });
        assert_eq!(decode_kind(0x79), EventKind::Nop { raw: 0x79 });
    }

    #[test]
    fn decode_entries_pairs_bytes_and_tracks_offsets() {
        let entries = decode_entries(&CAPTURED, 402);
        assert_eq!(entries.len(), 13);
        assert_eq!(
            entries[0],
            RawEntry {
                byte_offset: 402,
                minute_byte: 209,
                kind: EventKind::HeightChange { inches: 31 }
            }
        );
        assert_eq!(
            entries[12],
            RawEntry {
                byte_offset: 426,
                minute_byte: 251,
                kind: EventKind::Move { to_standing: false }
            }
        );
        // A trailing odd byte is ignored, and the next read resumes at the even boundary.
        assert_eq!(decode_entries(&[0x01, 0x5D, 0x02], 0).len(), 1);
    }

    #[test]
    fn date_entries_walks_backwards_from_now_like_the_phone_app() {
        let entries = decode_entries(&CAPTURED, 0);
        // minutes since power-on = 5883 -> 5883 % 256 = 251, same as the newest entry, so it is "now".
        let dated = date_entries(&entries, 5883, now());
        assert_eq!(dated.len(), 13);
        assert_eq!(dated.last().unwrap().date, now());
        assert_eq!(
            dated.last().unwrap().kind,
            EventKind::Move { to_standing: false }
        );
        assert_eq!(dated[9].date, now() - minutes(20));
        assert_eq!(dated[0].date, now() - minutes(42));
    }

    #[test]
    fn date_entries_handles_minute_wrap() {
        // t=250 then t=4: 10 minutes apart across the 256 wrap.
        let entries = decode_entries(&[0xFA, 0x50, 0x04, 0x51], 0);
        // minutes % 256 == 9 -> newest entry (t=4) is 5 minutes ago.
        let dated = date_entries(&entries, 256 * 3 + 9, now());
        assert_eq!(dated[1].date, now() - minutes(5));
        assert_eq!(dated[0].date, now() - minutes(15));
    }

    #[test]
    fn date_entries_drops_nops_but_uses_them_as_time_references() {
        // present=0 at t=89, NOP t=88, NOP t=87, HEIGHT at t=35. The minute bytes decrease
        // along chronological order, so each step is a wrap: 35->87 is 204 min, 87->88 and
        // 88->89 are 255 min each, 714 in total - what the phone app's algorithm produces.
        let entries = decode_entries(&[0x59, 0x50, 0x58, 0x00, 0x57, 0x00, 0x23, 0x26], 0);
        let dated = date_entries(&entries, 35, now());
        let kinds: Vec<EventKind> = dated.iter().map(|e| e.kind).collect();
        assert_eq!(
            kinds,
            [
                EventKind::Presence { present: false },
                EventKind::HeightChange { inches: 26 }
            ]
        );
        assert_eq!(dated[1].date, now());
        assert_eq!(dated[0].date, now() - minutes(204 + 255 + 255));
    }

    #[test]
    fn serde_matches_swift_for_every_kind() {
        let cases = [
            (
                EventKind::Presence { present: true },
                r#"{"type":"presence","present":true}"#,
            ),
            (
                EventKind::Countdown { to_standing: false },
                r#"{"type":"countdown","toStanding":false}"#,
            ),
            (
                EventKind::Move { to_standing: true },
                r#"{"type":"move","toStanding":true}"#,
            ),
            (
                EventKind::HeightChange { inches: 29 },
                r#"{"type":"heightChange","inches":29}"#,
            ),
            (
                EventKind::UserChange { user: 3 },
                r#"{"type":"userChange","user":3}"#,
            ),
            (EventKind::Nop { raw: 255 }, r#"{"type":"nop","raw":255}"#),
        ];
        for (kind, json) in cases {
            assert_eq!(serde_json::to_string(&kind).unwrap(), json);
            assert_eq!(serde_json::from_str::<EventKind>(json).unwrap(), kind);
        }
        // Swift's key order differs; it must still parse.
        let swift = r#"{"byteOffset":6,"date":"2026-08-31T21:40:35Z","kind":{"toStanding":false,"type":"move"}}"#;
        let event: Event = serde_json::from_str(swift).unwrap();
        assert_eq!(event.byte_offset, 6);
        assert_eq!(event.kind, EventKind::Move { to_standing: false });
        assert_eq!(
            serde_json::to_string(&event).unwrap(),
            r#"{"byteOffset":6,"date":"2026-08-31T21:40:35Z","kind":{"type":"move","toStanding":false}}"#
        );
    }
}
