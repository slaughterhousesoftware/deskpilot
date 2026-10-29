//! Files shared between the service and its readers: the widget snapshot, the dated
//! history archive, the live-observed moves, and the command queue. Formats are
//! byte-compatible with the Swift apps' `Codable` output so either side can read the other.

use std::collections::HashMap;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use jiff::{SignedDuration, Timestamp};
use serde::{Deserialize, Serialize};
use thiserror::Error;
use uuid::Uuid;

use crate::cruise::CruiseSlot;
use crate::history::{Event, EventKind};
use crate::model::{HistoryDocument, Snapshot};
use crate::time::{iso8601_seconds, seconds};

#[derive(Debug, Error)]
pub enum StoreError {
    #[error("{0}")]
    Io(#[from] io::Error),
    #[error("{0}")]
    Json(#[from] serde_json::Error),
}

/// The App Group the Swift apps share. On macOS the daemon writes there when the container
/// exists, so the Dashboard and widget read what it writes.
pub const APP_GROUP: &str = "LQV43S38FV.com.kevinpatel.tempo";

/// Where the files live: `DESKPILOT_DATA_DIR`, else the Swift apps' App Group container on
/// macOS when present, else the platform's data directory for "Tempo".
pub fn default_data_dir() -> PathBuf {
    if let Some(dir) = std::env::var_os("DESKPILOT_DATA_DIR").filter(|d| !d.is_empty()) {
        return PathBuf::from(dir);
    }
    let home = std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from);
    if cfg!(target_os = "macos") {
        if let Some(home) = &home {
            let group = home.join("Library/Group Containers").join(APP_GROUP);
            if group.is_dir() {
                return group;
            }
            return home.join("Library/Application Support/Tempo");
        }
    }
    if cfg!(target_os = "windows") {
        if let Some(appdata) = std::env::var_os("APPDATA") {
            return PathBuf::from(appdata).join("Tempo");
        }
    }
    if let Some(xdg) = std::env::var_os("XDG_DATA_HOME").filter(|d| !d.is_empty()) {
        return PathBuf::from(xdg).join("tempo");
    }
    home.map(|h| h.join(".local/share/tempo"))
        .unwrap_or_else(|| PathBuf::from("tempo-data"))
}

/// Writes `bytes` to `path` through a temporary file in the same directory and a rename, so
/// a reader never sees a half-written file.
pub fn write_atomic(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let dir = path.parent().unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(dir)?;
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let tmp = dir.join(format!(".{name}.{}.tmp", Uuid::new_v4()));
    fs::write(&tmp, bytes)?;
    if let Err(e) = fs::rename(&tmp, path) {
        let _ = fs::remove_file(&tmp);
        return Err(e);
    }
    Ok(())
}

fn read_json<T: for<'de> Deserialize<'de>>(path: &Path) -> Option<T> {
    let bytes = fs::read(path).ok()?;
    serde_json::from_slice(&bytes).ok()
}

fn write_json<T: Serialize>(path: &Path, value: &T) -> Result<(), StoreError> {
    let bytes = serde_json::to_vec(value)?;
    write_atomic(path, &bytes)?;
    Ok(())
}

// MARK: Snapshot

#[derive(Clone, Debug)]
pub struct SnapshotStore {
    pub path: PathBuf,
}

impl SnapshotStore {
    pub fn new(dir: &Path) -> Self {
        Self {
            path: dir.join("snapshot.json"),
        }
    }

    pub fn read(&self) -> Option<Snapshot> {
        read_json(&self.path)
    }

    pub fn write(&self, snapshot: &Snapshot) -> Result<(), StoreError> {
        write_json(&self.path, snapshot)
    }
}

// MARK: History

#[derive(Clone, Debug)]
pub struct HistoryStore {
    pub path: PathBuf,
}

impl HistoryStore {
    pub fn new(dir: &Path) -> Self {
        Self {
            path: dir.join("history.json"),
        }
    }

    pub fn backups_dir(&self) -> PathBuf {
        self.path
            .parent()
            .unwrap_or_else(|| Path::new("."))
            .join("history-backups")
    }

    pub fn read(&self) -> Option<HistoryDocument> {
        read_json(&self.path)
    }

    pub fn write(&self, doc: &HistoryDocument) -> Result<(), StoreError> {
        write_json(&self.path, doc)
    }

    /// A desk log is a bounded view of one boot session, not the user's archive. Keep the
    /// older prefix and replace the overlapping window with the current log.
    pub fn merge(saved: Option<HistoryDocument>, incoming: HistoryDocument) -> HistoryDocument {
        let Some(saved) = saved else { return incoming };
        let Some(first) = incoming.events.iter().map(|e| e.date).min() else {
            return saved;
        };
        // Reconnecting can shift the log's wall-clock anchor by seconds. Recognise the first
        // entry so the previous copy doesn't survive as a duplicate at the seam.
        let head = incoming.events.first();
        let matching = saved.events.iter().find(|e| {
            head.is_some_and(|h| {
                e.byte_offset == h.byte_offset
                    && e.kind == h.kind
                    && e.date.duration_since(first).abs() < seconds(60)
            })
        });
        let cutoff = matching.map_or(first, |m| m.date.min(first));
        let mut events: Vec<Event> = saved
            .events
            .iter()
            .copied()
            .filter(|e| e.date < cutoff)
            .collect();
        // Don't extend the last known presence across an unobserved power-off gap.
        if saved.written_at < first {
            if let Some(last) = events.last() {
                if last.date <= saved.written_at {
                    events.push(Event::synthetic(
                        saved.written_at,
                        EventKind::Presence { present: false },
                    ));
                }
            }
        }
        events.extend(incoming.events.iter().copied());
        events.sort_by_key(|e| e.date);
        HistoryDocument { events, ..incoming }
    }

    /// Archive-aware sync, with an immutable daily copy of the previous file. A malformed
    /// existing file must never be silently overwritten.
    pub fn merge_and_write(&self, incoming: HistoryDocument) -> Result<(), StoreError> {
        let mut saved = None;
        if self.path.exists() {
            let bytes = fs::read(&self.path)?;
            saved = Some(serde_json::from_slice::<HistoryDocument>(&bytes)?);
            let dir = self.backups_dir();
            fs::create_dir_all(&dir)?;
            let day = &iso8601_seconds::format(incoming.written_at)[..10];
            let backup = dir.join(format!("history-{day}.json"));
            if !backup.exists() {
                fs::write(&backup, &bytes)?;
            }
        }
        self.write(&Self::merge(saved, incoming))
    }
}

// MARK: Observed moves

/// Where the session keeps the moves it saw happen live, so a restart doesn't throw away
/// the only second-accurate timestamps it has.
pub trait ObservedMoveStore: Send + Sync {
    fn load(&self) -> Vec<Event>;
    fn save(&self, moves: &[Event]);
    /// The desk's latest announced countdown as the session read it live, and whether it
    /// was waved off: what a restart would otherwise forget, leaving the countdown on the
    /// stale announced time until the log's resolution window passes.
    fn load_countdown(&self) -> Option<LiveCountdown> {
        None
    }
    fn save_countdown(&self, _countdown: Option<&LiveCountdown>) {}
}

/// A COUNTDOWN entry read live: when it was read (second-accurate, unlike the log's minute
/// stamp), which way, and when the app concluded the move was off, if it did.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LiveCountdown {
    #[serde(with = "iso8601_seconds")]
    pub seen_at: Timestamp,
    pub to_standing: bool,
    #[serde(default, with = "iso8601_seconds::option", skip_serializing_if = "Option::is_none")]
    pub cancelled_at: Option<Timestamp>,
    #[serde(default)]
    pub reversed: bool,
}

#[derive(Clone, Debug)]
pub struct ObservedMoveFile {
    pub path: PathBuf,
}

impl ObservedMoveFile {
    pub fn new(dir: &Path) -> Self {
        Self {
            path: dir.join("observed-moves.json"),
        }
    }
}

impl ObservedMoveStore for ObservedMoveFile {
    fn load(&self) -> Vec<Event> {
        read_json(&self.path).unwrap_or_default()
    }

    fn save(&self, moves: &[Event]) {
        if let Err(e) = write_json(&self.path, &moves) {
            tracing::warn!(error = %e, "could not save observed moves");
        }
    }

    fn load_countdown(&self) -> Option<LiveCountdown> {
        read_json(&self.countdown_path())
    }

    fn save_countdown(&self, countdown: Option<&LiveCountdown>) {
        let path = self.countdown_path();
        let result = match countdown {
            Some(countdown) => write_json(&path, countdown),
            None => match fs::remove_file(&path) {
                Ok(()) => Ok(()),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
                Err(e) => Err(e.into()),
            },
        };
        if let Err(e) = result {
            tracing::warn!(error = %e, "could not save the live countdown");
        }
    }
}

impl ObservedMoveFile {
    fn countdown_path(&self) -> PathBuf {
        self.path.with_file_name("live-countdown.json")
    }
}

// MARK: Commands

/// A command a UI queues for the service (the only Bluetooth client) to execute.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(from = "CommandWire", into = "CommandWire")]
pub enum Command {
    /// Return the service's current state without issuing Bluetooth operations.
    Inspect,
    CaptureSittingPreset,
    CaptureStandingPreset,
    /// Store the current height as custom preset 1 or 2.
    CaptureCustomPreset(u8),
    /// `None` turns cruise control off.
    SetCruise(Option<CruiseSlot>),
    SetPaused(bool),
    /// Pulse (a nudge) instead of moving when the interval runs out.
    SetPulseOnly(bool),
    /// Make user 0 or 1 the desk's active user.
    SetUser(u8),
    /// The user's name on the desk (20 bytes).
    SetUserName(String),
    /// The name of custom preset 1 or 2.
    SetPresetName(u8, String),
    /// Write the time of day to the desk's clock.
    SyncClock,
    /// Drop the Bluetooth connection and connect again.
    Reconnect,
}

/// Swift's synthesised `Codable` shape for the enum: `{"setCruise":{"_0":{...}}}`,
/// `{"setCruise":{}}` for nil, `{"captureSittingPreset":{}}`.
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
enum CommandWire {
    Inspect {},
    CaptureSittingPreset {},
    CaptureStandingPreset {},
    SetCruise {
        #[serde(rename = "_0", default, skip_serializing_if = "Option::is_none")]
        slot: Option<CruiseSlot>,
    },
    SetPaused {
        #[serde(rename = "_0")]
        paused: bool,
    },
    CaptureCustomPreset {
        #[serde(rename = "_0")]
        which: u8,
    },
    SetPulseOnly {
        #[serde(rename = "_0")]
        on: bool,
    },
    SetUser {
        #[serde(rename = "_0")]
        index: u8,
    },
    SetUserName {
        #[serde(rename = "_0")]
        name: String,
    },
    SetPresetName {
        #[serde(rename = "_0")]
        which: u8,
        #[serde(rename = "_1")]
        name: String,
    },
    SyncClock {},
    Reconnect {},
}

impl From<CommandWire> for Command {
    fn from(w: CommandWire) -> Self {
        match w {
            CommandWire::Inspect {} => Command::Inspect,
            CommandWire::CaptureSittingPreset {} => Command::CaptureSittingPreset,
            CommandWire::CaptureStandingPreset {} => Command::CaptureStandingPreset,
            CommandWire::CaptureCustomPreset { which } => Command::CaptureCustomPreset(which),
            CommandWire::SetCruise { slot } => Command::SetCruise(slot),
            CommandWire::SetPaused { paused } => Command::SetPaused(paused),
            CommandWire::SetPulseOnly { on } => Command::SetPulseOnly(on),
            CommandWire::SetUser { index } => Command::SetUser(index),
            CommandWire::SetUserName { name } => Command::SetUserName(name),
            CommandWire::SetPresetName { which, name } => Command::SetPresetName(which, name),
            CommandWire::SyncClock {} => Command::SyncClock,
            CommandWire::Reconnect {} => Command::Reconnect,
        }
    }
}

impl From<Command> for CommandWire {
    fn from(c: Command) -> Self {
        match c {
            Command::Inspect => CommandWire::Inspect {},
            Command::CaptureSittingPreset => CommandWire::CaptureSittingPreset {},
            Command::CaptureStandingPreset => CommandWire::CaptureStandingPreset {},
            Command::CaptureCustomPreset(which) => CommandWire::CaptureCustomPreset { which },
            Command::SetCruise(slot) => CommandWire::SetCruise { slot },
            Command::SetPaused(paused) => CommandWire::SetPaused { paused },
            Command::SetPulseOnly(on) => CommandWire::SetPulseOnly { on },
            Command::SetUser(index) => CommandWire::SetUser { index },
            Command::SetUserName(name) => CommandWire::SetUserName { name },
            Command::SetPresetName(which, name) => CommandWire::SetPresetName { which, name },
            Command::SyncClock => CommandWire::SyncClock {},
            Command::Reconnect => CommandWire::Reconnect {},
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Envelope {
    pub id: Uuid,
    #[serde(with = "iso8601_seconds")]
    pub created_at: Timestamp,
    pub command: Command,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CommandResult {
    pub id: Uuid,
    #[serde(with = "iso8601_seconds")]
    pub completed_at: Timestamp,
    pub success: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
}

/// A file-backed queue: a UI enqueues `commands/<ID>.json`; the service polls `pending`,
/// executes each against the desk and calls `complete`, which removes the command file and
/// writes `results/<ID>.json`.
#[derive(Clone, Debug)]
pub struct CommandQueue {
    commands_dir: PathBuf,
    results_dir: PathBuf,
}

impl CommandQueue {
    /// How long a queued command stays worth executing. A command written while the service
    /// was not running would otherwise sit here and be applied, moving the desk or changing
    /// its rhythm, whenever the service next started, long after anyone expected it.
    pub const STALE_AFTER: SignedDuration = seconds(300);

    /// A distributed-notification name the macOS Dashboard posts after enqueuing, so the
    /// menu bar app reacts at once instead of waiting for its fallback poll.
    pub const WAKE_NOTIFICATION_NAME: &'static str = "com.kevinpatel.tempo.commands";

    pub fn new(dir: &Path) -> Self {
        Self {
            commands_dir: dir.join("commands"),
            results_dir: dir.join("results"),
        }
    }

    /// Swift names the files by its uppercase `UUID.uuidString`.
    fn file_name(id: Uuid) -> String {
        format!("{}.json", id.hyphenated().to_string().to_uppercase())
    }

    pub fn command_path(&self, id: Uuid) -> PathBuf {
        self.commands_dir.join(Self::file_name(id))
    }

    pub fn result_path(&self, id: Uuid) -> PathBuf {
        self.results_dir.join(Self::file_name(id))
    }

    pub fn enqueue(&self, command: Command, now: Timestamp) -> Result<Uuid, StoreError> {
        let id = Uuid::new_v4();
        self.write_envelope(&Envelope {
            id,
            created_at: now,
            command,
        })?;
        Ok(id)
    }

    /// Writes an envelope as given; tests use it to age a command in place.
    pub fn write_envelope(&self, envelope: &Envelope) -> Result<(), StoreError> {
        write_json(&self.command_path(envelope.id), envelope)
    }

    /// Pending commands, oldest first. Envelopes older than `STALE_AFTER` are deleted rather
    /// than returned, so a stale command is dropped exactly once by whoever polls next.
    /// Files that don't parse (a newer writer's command) are skipped.
    pub fn pending(&self, now: Timestamp) -> Vec<Envelope> {
        let Ok(entries) = fs::read_dir(&self.commands_dir) else {
            return Vec::new();
        };
        let cutoff = now - Self::STALE_AFTER;
        let mut envelopes: Vec<Envelope> = entries
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.extension().is_some_and(|x| x == "json"))
            .filter_map(|path| {
                let envelope: Envelope = read_json(&path)?;
                if envelope.created_at < cutoff {
                    let _ = fs::remove_file(&path);
                    return None;
                }
                Some(envelope)
            })
            .collect();
        envelopes.sort_by_key(|e| e.created_at);
        envelopes
    }

    /// Withdraws a command that hasn't been executed yet. A no-op when it is gone.
    pub fn cancel(&self, id: Uuid) -> Result<(), StoreError> {
        match fs::remove_file(self.command_path(id)) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(e.into()),
        }
    }

    pub fn complete(
        &self,
        id: Uuid,
        success: bool,
        message: Option<String>,
        now: Timestamp,
    ) -> Result<(), StoreError> {
        write_json(
            &self.result_path(id),
            &CommandResult {
                id,
                completed_at: now,
                success,
                message,
            },
        )?;
        let _ = fs::remove_file(self.command_path(id));
        Ok(())
    }

    pub fn result(&self, id: Uuid) -> Option<CommandResult> {
        read_json(&self.result_path(id))
    }

    /// Deletes results completed more than `older_than` before `now`.
    pub fn purge(&self, older_than: SignedDuration, now: Timestamp) {
        let Ok(entries) = fs::read_dir(&self.results_dir) else {
            return;
        };
        let cutoff = now - older_than;
        for path in entries
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.extension().is_some_and(|x| x == "json"))
        {
            if let Some(result) = read_json::<CommandResult>(&path) {
                if result.completed_at < cutoff {
                    let _ = fs::remove_file(&path);
                }
            }
        }
    }
}

/// Reads per address, for diagnostics and tests of poll cadence.
pub type ReadCounts = HashMap<u32, usize>;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rollup::NextMove;
    use crate::timeline::{segments, PostureState};

    fn now() -> Timestamp {
        Timestamp::from_second(1_800_000_000).unwrap()
    }
    fn dir() -> tempfile::TempDir {
        tempfile::tempdir().unwrap()
    }
    fn doc(written_at: Timestamp, threshold: Option<u8>, events: Vec<Event>) -> HistoryDocument {
        HistoryDocument {
            written_at,
            standing_threshold_inches: threshold,
            middle_of_night_hour: 4,
            events,
        }
    }
    fn presence(offset: i64, at: Timestamp, present: bool) -> Event {
        Event::new(offset, at, EventKind::Presence { present })
    }

    #[test]
    fn sync_after_desk_reset_preserves_older_days_and_closes_unknown_gap() {
        let d = dir();
        let store = HistoryStore::new(d.path());
        let start = now();
        let old = doc(
            start + seconds(3600),
            Some(34),
            vec![presence(0, start, true)],
        );
        store.write(&old).unwrap();
        let next = start + seconds(86400);
        let incoming = doc(
            next + seconds(3600),
            Some(34),
            vec![presence(0, next, true)],
        );
        store.merge_and_write(incoming.clone()).unwrap();
        let recovered = store.read().unwrap();
        let mut expected = old.events.clone();
        expected.push(Event::synthetic(
            old.written_at,
            EventKind::Presence { present: false },
        ));
        expected.extend(incoming.events.iter().copied());
        assert_eq!(recovered.events, expected);
        let segs = segments(&recovered.events, start, next, Some(34));
        assert_eq!(segs.last().unwrap().state, PostureState::Away);
        store.merge_and_write(incoming).unwrap();
        assert_eq!(store.read().unwrap(), recovered);
        let backups: Vec<_> = fs::read_dir(store.backups_dir())
            .unwrap()
            .flatten()
            .collect();
        assert_eq!(backups.len(), 1);
        assert_eq!(
            backups[0].file_name().to_string_lossy(),
            "history-2027-01-16.json"
        );
        let backup: HistoryDocument =
            serde_json::from_slice(&fs::read(backups[0].path()).unwrap()).unwrap();
        assert_eq!(backup, old);
    }

    #[test]
    fn reanchored_overlapping_sync_does_not_duplicate_first_event() {
        let start = now();
        let saved = doc(
            start + seconds(1000),
            Some(34),
            vec![
                presence(0, start - seconds(86400), false),
                presence(2, start, true),
            ],
        );
        let incoming = doc(
            start + seconds(1100),
            Some(34),
            vec![presence(2, start + seconds(20), true)],
        );
        let merged = HistoryStore::merge(Some(saved.clone()), incoming.clone());
        assert_eq!(merged.events, [saved.events[0], incoming.events[0]]);
    }

    #[test]
    fn empty_sync_preserves_archive_and_corrupt_file_cannot_be_overwritten() {
        let d = dir();
        let store = HistoryStore::new(d.path());
        let saved = doc(now(), Some(34), vec![presence(0, now(), true)]);
        store.write(&saved).unwrap();
        store
            .merge_and_write(doc(now() + seconds(60), None, vec![]))
            .unwrap();
        assert_eq!(store.read().unwrap(), saved);
        fs::write(&store.path, b"invalid history").unwrap();
        assert!(store.merge_and_write(saved).is_err());
        assert_eq!(fs::read(&store.path).unwrap(), b"invalid history");
    }

    #[test]
    fn history_round_trips_every_event_kind_and_a_missing_threshold() {
        let d = dir();
        let store = HistoryStore::new(d.path());
        assert!(store.read().is_none());
        let kinds = [
            EventKind::Presence { present: true },
            EventKind::Presence { present: false },
            EventKind::Countdown { to_standing: true },
            EventKind::Move { to_standing: false },
            EventKind::HeightChange { inches: 29 },
            EventKind::UserChange { user: 3 },
            EventKind::Nop { raw: 0xFF },
        ];
        let events: Vec<Event> = kinds
            .iter()
            .enumerate()
            .map(|(i, k)| Event::new(i as i64 * 2, now() + seconds(i as i64 * 60), *k))
            .collect();
        let d1 = doc(now(), Some(34), events);
        store.write(&d1).unwrap();
        assert_eq!(store.read().unwrap(), d1);
        let d2 = doc(now() + seconds(60), None, vec![]);
        store.write(&d2).unwrap();
        assert_eq!(store.read().unwrap(), d2);
    }

    #[test]
    fn snapshot_store_round_trips() {
        let d = dir();
        let store = SnapshotStore::new(d.path());
        assert!(store.read().is_none());
        let mut snap = Snapshot::disconnected(now());
        snap.connected = true;
        snap.height_tenths = Some(411);
        snap.is_present = true;
        snap.is_standing = Some(true);
        snap.at_desk_seconds = seconds(3600);
        snap.stands_today = 4;
        snap.next_move = Some(NextMove::new(now() + seconds(600), false));
        snap.cruise = Some(CruiseSlot::new(1200, 1200));
        snap.sitting_height_tenths = Some(266);
        snap.standing_height_tenths = Some(411);
        store.write(&snap).unwrap();
        assert_eq!(store.read().unwrap(), snap);
    }

    #[test]
    fn observed_move_file_round_trips_and_tolerates_absence() {
        let d = dir();
        let file = ObservedMoveFile::new(d.path());
        assert!(file.load().is_empty());
        let moves = vec![Event::synthetic(
            now(),
            EventKind::Move { to_standing: true },
        )];
        file.save(&moves);
        assert_eq!(file.load(), moves);
    }

    #[test]
    fn command_serde_matches_swift() {
        let cases = [
            (
                Command::CaptureSittingPreset,
                r#"{"captureSittingPreset":{}}"#,
            ),
            (
                Command::CaptureStandingPreset,
                r#"{"captureStandingPreset":{}}"#,
            ),
            (
                Command::SetCruise(Some(CruiseSlot::new(1200, 2400))),
                r#"{"setCruise":{"_0":{"standingSeconds":1200,"sittingSeconds":2400}}}"#,
            ),
            (Command::SetCruise(None), r#"{"setCruise":{}}"#),
            (Command::SetPaused(true), r#"{"setPaused":{"_0":true}}"#),
            (Command::Reconnect, r#"{"reconnect":{}}"#),
        ];
        for (command, json) in cases {
            assert_eq!(serde_json::to_string(&command).unwrap(), json);
            assert_eq!(serde_json::from_str::<Command>(json).unwrap(), command);
        }
        let swift = r#"{"id":"0B7A5C1E-1234-4ABC-9DEF-00AA11BB22CC","command":{"setPaused":{"_0":true}},"createdAt":"2027-01-15T08:00:00Z"}"#;
        let envelope: Envelope = serde_json::from_str(swift).unwrap();
        assert_eq!(envelope.command, Command::SetPaused(true));
        assert_eq!(envelope.created_at, now());
        let result = CommandResult {
            id: envelope.id,
            completed_at: now(),
            success: false,
            message: None,
        };
        assert_eq!(
            serde_json::to_string(&result).unwrap(),
            r#"{"id":"0b7a5c1e-1234-4abc-9def-00aa11bb22cc","completedAt":"2027-01-15T08:00:00Z","success":false}"#
        );
        assert_eq!(
            CommandQueue::file_name(envelope.id),
            "0B7A5C1E-1234-4ABC-9DEF-00AA11BB22CC.json"
        );
    }

    #[test]
    fn cancel_removes_a_pending_command_and_is_a_no_op_when_gone() {
        let d = dir();
        let queue = CommandQueue::new(d.path());
        let id = queue
            .enqueue(Command::CaptureStandingPreset, now())
            .unwrap();
        assert_eq!(
            queue
                .pending(now())
                .iter()
                .map(|e| e.id)
                .collect::<Vec<_>>(),
            [id]
        );
        queue.cancel(id).unwrap();
        assert!(queue.pending(now()).is_empty());
        assert!(queue.result(id).is_none());

        let kept = queue.enqueue(Command::CaptureSittingPreset, now()).unwrap();
        let done = queue.enqueue(Command::SetPaused(true), now()).unwrap();
        queue.complete(done, true, None, now()).unwrap();
        queue.cancel(done).unwrap();
        queue.cancel(Uuid::new_v4()).unwrap();
        assert_eq!(
            queue
                .pending(now())
                .iter()
                .map(|e| e.id)
                .collect::<Vec<_>>(),
            [kept]
        );
        assert_eq!(queue.result(done).map(|r| r.success), Some(true));
    }

    #[test]
    fn pending_drops_and_deletes_stale_commands_and_skips_unknown_ones() {
        let d = dir();
        let queue = CommandQueue::new(d.path());
        let fresh = queue.enqueue(Command::CaptureSittingPreset, now()).unwrap();
        let stale = Uuid::new_v4();
        queue
            .write_envelope(&Envelope {
                id: stale,
                created_at: now() - CommandQueue::STALE_AFTER - seconds(60),
                command: Command::SetPaused(true),
            })
            .unwrap();
        fs::write(queue.command_path(Uuid::new_v4()), br#"{"id":"0B7A5C1E-1234-4ABC-9DEF-00AA11BB22CC","command":{"moveTo":{"_0":300}},"createdAt":"2027-01-15T08:00:00Z"}"#).unwrap();
        assert_eq!(
            queue
                .pending(now())
                .iter()
                .map(|e| e.id)
                .collect::<Vec<_>>(),
            [fresh]
        );
        assert!(
            !queue.command_path(stale).exists(),
            "a stale command is deleted, not just skipped"
        );
    }

    #[test]
    fn enqueue_pending_complete_result_sorted_and_all_cases() {
        let d = dir();
        let queue = CommandQueue::new(d.path());
        let commands = [
            Command::CaptureSittingPreset,
            Command::CaptureStandingPreset,
            Command::SetCruise(Some(CruiseSlot::new(300, 900))),
            Command::SetCruise(None),
            Command::SetPaused(true),
            Command::SetPaused(false),
            Command::CaptureCustomPreset(2),
            Command::SetPulseOnly(true),
            Command::SetUser(1),
            Command::SetUserName("Kevin".into()),
            Command::SetPresetName(1, "Drafting".into()),
            Command::SyncClock,
            Command::Reconnect,
        ];
        let ids: Vec<Uuid> = commands
            .iter()
            .enumerate()
            .map(|(i, c)| queue.enqueue(c.clone(), now() + seconds(i as i64)).unwrap())
            .collect();
        let pending = queue.pending(now() + seconds(10));
        assert_eq!(
            pending.iter().map(|e| e.id).collect::<Vec<_>>(),
            ids,
            "oldest first"
        );
        for (id, command) in ids.iter().zip(commands) {
            assert_eq!(
                pending.iter().find(|e| e.id == *id).unwrap().command,
                command
            );
        }
        queue
            .complete(ids[0], false, Some("desk did not respond".into()), now())
            .unwrap();
        let result = queue.result(ids[0]).unwrap();
        assert!(!result.success);
        assert_eq!(result.message.as_deref(), Some("desk did not respond"));
        assert!(queue.result(Uuid::new_v4()).is_none());
        assert_eq!(queue.pending(now() + seconds(10)).len(), 12);
    }

    #[test]
    fn purge_removes_old_results_only() {
        let d = dir();
        let queue = CommandQueue::new(d.path());
        let id = queue
            .enqueue(Command::CaptureStandingPreset, now())
            .unwrap();
        queue.complete(id, true, None, now()).unwrap();
        queue.purge(seconds(3600), now() + seconds(10));
        assert!(queue.result(id).is_some());
        queue.purge(SignedDuration::ZERO, now() + seconds(1));
        assert!(queue.result(id).is_none());
    }

    #[test]
    fn data_dir_honours_the_environment_override() {
        // Process-wide env; set and restore within one test.
        std::env::set_var("DESKPILOT_DATA_DIR", "/tmp/tempo-test-dir");
        assert_eq!(default_data_dir(), PathBuf::from("/tmp/tempo-test-dir"));
        std::env::remove_var("DESKPILOT_DATA_DIR");
        assert!(default_data_dir()
            .to_string_lossy()
            .to_lowercase()
            .contains("tempo"));
    }
}
