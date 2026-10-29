//! The value types the service publishes and the files it shares with UIs.

use jiff::{SignedDuration, Timestamp};
use serde::{Deserialize, Serialize};

use crate::cruise::CruiseSlot;
use crate::history::Event;
use crate::motion::Presets;
use crate::registers::{CountdownTiming, UserFlags};
use crate::rollup::{NextMove, TodayStats};
use crate::time::{duration_seconds, iso8601_seconds, seconds};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum ConnectionStatus {
    #[default]
    Disconnected,
    Connecting,
    Connected,
    BluetoothOff,
    Unauthorized,
}

/// The current user's block, as last read from the desk.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Settings {
    pub firmware: String,
    pub user_index: u8,
    pub flags: u32,
    pub active_cruise_slot: u8,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cruise: Option<CruiseSlot>,
    /// Configured alert timing; absent in older snapshots or on an unmapped register.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub countdown_timing: Option<CountdownTiming>,
    pub middle_of_night_hour: u8,
    pub standing_height_tenths: u16,
    pub sitting_height_tenths: u16,
    pub custom_height_one_tenths: u16,
    pub custom_height_two_tenths: u16,
    /// The 20-byte name fields of the user block, read once per connection.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub user_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preset_name_one: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preset_name_two: Option<String>,
}

impl Settings {
    pub const fn pulse_only(&self) -> bool {
        self.user_flags().contains(UserFlags::PULSE_ONLY)
    }

    pub const fn user_flags(&self) -> UserFlags {
        UserFlags(self.flags)
    }

    pub const fn paused(&self) -> bool {
        self.user_flags().contains(UserFlags::PAUSED)
    }

    pub const fn cruise_enabled(&self) -> bool {
        self.active_cruise_slot != 0 && self.cruise.is_some()
    }

    /// The cruise slot in force: `None` when cruise control is off.
    pub const fn active_cruise(&self) -> Option<CruiseSlot> {
        if self.cruise_enabled() {
            self.cruise
        } else {
            None
        }
    }

    pub const fn presets(&self) -> Presets {
        Presets {
            sitting_tenths: self.sitting_height_tenths,
            standing_tenths: self.standing_height_tenths,
        }
    }

    pub const fn standing_threshold_inches(&self) -> Option<u8> {
        self.presets().standing_threshold_inches()
    }
}

/// Everything a UI needs, published on every change.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct DeskState {
    pub status: ConnectionStatus,
    /// Visible attempts exhausted; keep checking without animating anything.
    pub reconnecting_in_background: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub height_tenths: Option<u16>,
    pub is_moving: bool,
    /// Where the desk is going to stop, while it moves or coasts (`coast::CoastModel`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub predicted_height_tenths: Option<u16>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub settings: Option<Settings>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub today: Option<TodayStats>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_error: Option<String>,
    #[serde(
        with = "iso8601_seconds::option",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub updated_at: Option<Timestamp>,
    /// Bumped whenever the merged history event count changes: a cheap signal that the
    /// history document is worth re-fetching and writing, without diffing the event list.
    pub history_revision: u64,
}

impl DeskState {
    pub const fn is_connected(&self) -> bool {
        matches!(self.status, ConnectionStatus::Connected)
    }
}

/// What a widget or a status command needs, written after every meaningful change.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    #[serde(with = "iso8601_seconds")]
    pub updated_at: Timestamp,
    pub connected: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub height_tenths: Option<u16>,
    pub is_moving: bool,
    pub is_present: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub is_standing: Option<bool>,
    #[serde(with = "duration_seconds")]
    pub at_desk_seconds: SignedDuration,
    pub stands_today: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next_move: Option<NextMove>,
    pub paused: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cruise: Option<CruiseSlot>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sitting_height_tenths: Option<u16>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub standing_height_tenths: Option<u16>,
}

impl Snapshot {
    /// Readers treat snapshots older than this as stale.
    pub const STALE_AFTER: SignedDuration = seconds(120);

    /// An empty, disconnected snapshot.
    pub fn disconnected(now: Timestamp) -> Self {
        Self {
            updated_at: now,
            connected: false,
            height_tenths: None,
            is_moving: false,
            is_present: false,
            is_standing: None,
            at_desk_seconds: SignedDuration::ZERO,
            stands_today: 0,
            next_move: None,
            paused: false,
            cruise: None,
            sitting_height_tenths: None,
            standing_height_tenths: None,
        }
    }

    /// Builds the snapshot for a state. Until the desk has been read this run, cruise
    /// control and the presets come from `previous` (what the last run left) so an
    /// out-of-reach launch doesn't overwrite them with blanks; `saved_today` fills the
    /// at-desk total and stands from the saved history for the same reason.
    pub fn from_state(
        state: &DeskState,
        previous: Option<&Snapshot>,
        saved_today: Option<&TodayStats>,
        now: Timestamp,
    ) -> Self {
        let today = state.today.as_ref().or(saved_today);
        Self {
            updated_at: now,
            connected: state.is_connected(),
            height_tenths: state.height_tenths,
            is_moving: state.is_moving,
            is_present: state.today.is_some_and(|t| t.is_present),
            is_standing: state.today.and_then(|t| t.is_standing),
            at_desk_seconds: today.map_or(SignedDuration::ZERO, |t| t.at_desk_seconds),
            stands_today: today.map_or(0, |t| t.stands),
            next_move: state.today.and_then(|t| t.next_move),
            paused: state
                .settings
                .as_ref()
                .map(Settings::paused)
                .or(previous.map(|p| p.paused))
                .unwrap_or(false),
            cruise: match &state.settings {
                Some(s) => s.active_cruise(),
                None => previous.and_then(|p| p.cruise),
            },
            sitting_height_tenths: state
                .settings
                .as_ref()
                .map(|s| s.sitting_height_tenths)
                .or(previous.and_then(|p| p.sitting_height_tenths)),
            standing_height_tenths: state
                .settings
                .as_ref()
                .map(|s| s.standing_height_tenths)
                .or(previous.and_then(|p| p.standing_height_tenths)),
        }
    }

    /// Whether anything a reader would notice differs, ignoring the clock-driven fields
    /// (`updated_at`, and `at_desk_seconds`, which just ticks up).
    pub fn differs_from(&self, other: &Snapshot) -> bool {
        let mut mine = self.clone();
        mine.updated_at = other.updated_at;
        mine.at_desk_seconds = other.at_desk_seconds;
        mine != *other
    }

    /// Whether a change is worth waking readers for immediately.
    pub fn significant_change(&self, other: &Snapshot) -> bool {
        self.connected != other.connected
            || self.is_present != other.is_present
            || self.stands_today != other.stands_today
            || self.next_move != other.next_move
            || self.is_standing != other.is_standing
            || self.paused != other.paused
    }

    pub fn is_stale(&self, now: Timestamp) -> bool {
        now.duration_since(self.updated_at) > Self::STALE_AFTER
    }
}

/// The dated history the service writes for dashboards to read.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryDocument {
    #[serde(with = "iso8601_seconds")]
    pub written_at: Timestamp,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub standing_threshold_inches: Option<u8>,
    pub middle_of_night_hour: u8,
    pub events: Vec<Event>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::history::EventKind;

    fn now() -> Timestamp {
        Timestamp::from_second(1_800_000_000).unwrap()
    }

    #[test]
    fn snapshot_serde_matches_swift() {
        let mut snapshot = Snapshot::disconnected(now());
        snapshot.connected = true;
        snapshot.height_tenths = Some(267);
        snapshot.at_desk_seconds = SignedDuration::from_secs(3600);
        snapshot.next_move = Some(NextMove::new(now() + seconds(60), true));
        snapshot.cruise = Some(CruiseSlot::new(1200, 1200));
        let json = serde_json::to_string(&snapshot).unwrap();
        assert_eq!(
            json,
            r#"{"updatedAt":"2027-01-15T08:00:00Z","connected":true,"heightTenths":267,"isMoving":false,"isPresent":false,"atDeskSeconds":3600.0,"standsToday":0,"nextMove":{"at":"2027-01-15T08:01:00Z","toStanding":true},"paused":false,"cruise":{"standingSeconds":1200,"sittingSeconds":1200}}"#
        );
        assert_eq!(serde_json::from_str::<Snapshot>(&json).unwrap(), snapshot);
        // Swift writes integral TimeInterval values without a fraction; both must parse.
        let swift = r#"{"updatedAt":"2026-10-13T22:10:36Z","connected":false,"isMoving":false,"isPresent":false,"atDeskSeconds":2881,"standsToday":4,"paused":false}"#;
        let parsed: Snapshot = serde_json::from_str(swift).unwrap();
        assert_eq!(parsed.at_desk_seconds, SignedDuration::from_secs(2881));
        assert_eq!(parsed.stands_today, 4);
    }

    #[test]
    fn history_document_parses_swift_output_with_fractional_seconds_and_missing_threshold() {
        let swift = r#"{"middleOfNightHour":4,"writtenAt":"2026-10-13T22:10:36.5Z","events":[{"byteOffset":2,"date":"2026-08-31T21:40:35Z","kind":{"present":true,"type":"presence"}}]}"#;
        let doc: HistoryDocument = serde_json::from_str(swift).unwrap();
        assert_eq!(doc.standing_threshold_inches, None);
        assert_eq!(doc.events[0].kind, EventKind::Presence { present: true });
        let json = serde_json::to_string(&doc).unwrap();
        assert!(
            json.starts_with(
                r#"{"writtenAt":"2026-10-13T22:10:36Z","middleOfNightHour":4,"events":["#
            ),
            "{json}"
        );
    }

    #[test]
    fn snapshot_from_state_falls_back_to_the_previous_run() {
        let state = DeskState::default();
        let mut previous = Snapshot::disconnected(now());
        previous.paused = true;
        previous.cruise = Some(CruiseSlot::new(600, 3000));
        previous.sitting_height_tenths = Some(266);
        let saved = TodayStats {
            stands: 3,
            at_desk_seconds: seconds(100),
            ..Default::default()
        };
        let snap = Snapshot::from_state(&state, Some(&previous), Some(&saved), now());
        assert!(!snap.connected && snap.paused);
        assert_eq!(snap.cruise, previous.cruise);
        assert_eq!(snap.sitting_height_tenths, Some(266));
        assert_eq!((snap.stands_today, snap.at_desk_seconds), (3, seconds(100)));
        assert!(
            !snap.is_present,
            "presence never comes from the saved history"
        );
    }

    #[test]
    fn snapshot_change_detection() {
        let a = Snapshot::disconnected(now());
        let mut b = a.clone();
        b.updated_at = now() + seconds(30);
        b.at_desk_seconds = seconds(30);
        assert!(!a.differs_from(&b));
        b.stands_today = 1;
        assert!(a.differs_from(&b));
        assert!(a.significant_change(&b));
        let mut c = a.clone();
        c.height_tenths = Some(300);
        assert!(a.differs_from(&c) && !a.significant_change(&c));
        assert!(a.is_stale(now() + seconds(121)) && !a.is_stale(now() + seconds(120)));
    }
}
