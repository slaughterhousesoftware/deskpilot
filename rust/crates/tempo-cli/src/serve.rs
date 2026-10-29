//! The daemon: connect, publish the snapshot, archive the history, apply queued commands.

use std::io::{Read, Write};
use std::path::PathBuf;

use fs2::FileExt;
use serde::Serialize;
use std::sync::Arc;
use std::time::Duration;
use tempo_core::timeline::{self, Segment};

use jiff::tz::TimeZone;
use jiff::Timestamp;
use tempo_core::model::{DeskState, HistoryDocument, Snapshot};
use tempo_core::rollup::{self, RollupInput, TodayStats};
use tempo_core::store::{Command, CommandQueue, HistoryStore, ObservedMoveFile, SnapshotStore};
use tempo_core::time::{seconds, SystemClock};
use tempo_desk::sim::{Scenario, SimulatedTransport};
use tempo_desk::{Desk, DeskConfig, DeskHandle, Transport};
use tokio::task::JoinHandle;
use tokio::time::Instant;

/// Today as of the archive's last write, for the snapshot while the desk is out of reach.
fn saved_today(doc: &HistoryDocument, now: Timestamp, tz: &TimeZone) -> Option<TodayStats> {
    let end = now.min(doc.written_at);
    let day_start = rollup::day_start(now, tz, doc.middle_of_night_hour);
    if end < day_start {
        return None;
    }
    let mut today = rollup::compute(RollupInput {
        paused: true,
        standing_threshold_inches: doc.standing_threshold_inches,
        ..RollupInput::new(&doc.events, end, day_start)
    });
    today.next_move = None;
    Some(today)
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct UiFrame<'a> {
    protocol_version: u32,
    state: &'a DeskState,
    snapshot: Snapshot,
    saved_today: Option<TodayStats>,
    today_segments: Vec<Segment>,
    #[serde(with = "tempo_core::time::iso8601_seconds::option")]
    last_synced_at: Option<Timestamp>,
}

fn ui_frame<'a>(
    state: &'a DeskState,
    document: Option<&HistoryDocument>,
    previous: Option<&Snapshot>,
    now: Timestamp,
    tz: &TimeZone,
) -> UiFrame<'a> {
    let saved = document.and_then(|doc| saved_today(doc, now, tz));
    let end = document.map(|doc| {
        if state.is_connected() {
            now
        } else {
            now.min(doc.written_at)
        }
    });
    let segments = document.zip(end).map_or_else(Vec::new, |(doc, end)| {
        let start = rollup::day_start(now, tz, doc.middle_of_night_hour);
        if end < start {
            Vec::new()
        } else {
            timeline::segments(&doc.events, start, end, doc.standing_threshold_inches)
        }
    });
    UiFrame {
        protocol_version: 1,
        state,
        snapshot: Snapshot::from_state(state, previous, saved.as_ref(), now),
        saved_today: saved,
        today_segments: segments,
        last_synced_at: if state.is_connected() {
            state.updated_at
        } else {
            document.map(|doc| doc.written_at)
        },
    }
}

struct Publisher {
    ui_document: Option<HistoryDocument>,
    ui_revision: Option<u64>,
    last_ui_refresh: Instant,
    snapshots: SnapshotStore,
    history: HistoryStore,
    previous: Option<Snapshot>,
    saved_today: Option<TodayStats>,
    last_snapshot: Option<Snapshot>,
    last_snapshot_write: Instant,
    last_history_write: Instant,
    last_history_revision: Option<u64>,
    history_write: Option<JoinHandle<()>>,
    /// What the hosting app last received, so a poll that found nothing new costs it nothing.
    last_ui_state: Option<DeskState>,
    last_ui_snapshot: Option<Snapshot>,
    last_ui_sent: Instant,
    last_motion: Option<Instant>,
}

/// Whether the hosting app would show anything different: the state with its clock-driven
/// fields (`updated_at`, and today's at-desk seconds, which just tick up) set aside.
fn ui_state_changed(state: &DeskState, last: &DeskState) -> bool {
    let mut mine = state.clone();
    mine.updated_at = last.updated_at;
    if let (Some(today), Some(last_today)) = (mine.today.as_mut(), last.today.as_ref()) {
        today.at_desk_seconds = last_today.at_desk_seconds;
    }
    mine != *last
}

impl Publisher {
    /// The desk is polled four times a second, and at rest every poll reads the same. The
    /// app gets a frame when something it shows changed, at full rate while the desk moves
    /// (and for a few seconds after, while its label settles), and otherwise every few
    /// seconds so its clock-driven bits ("cancelled" fades, "last synced") keep up.
    async fn publish_ui(
        &mut self,
        handle: &DeskHandle,
        state: &DeskState,
        tz: &TimeZone,
    ) -> Result<(), String> {
        let mut refreshed = false;
        if state.is_connected()
            && (self.ui_revision != Some(state.history_revision)
                || self.last_ui_refresh.elapsed() >= Duration::from_secs(30))
        {
            if let Some(document) = handle.history_document().await {
                refreshed = self.ui_revision != Some(state.history_revision);
                self.ui_document = Some(document);
                self.ui_revision = Some(state.history_revision);
                self.last_ui_refresh = Instant::now();
            }
        }
        let frame = ui_frame(
            state,
            self.ui_document.as_ref(),
            self.previous.as_ref(),
            Timestamp::now(),
            tz,
        );
        if state.is_moving {
            self.last_motion = Some(Instant::now());
        }
        let settling = self
            .last_motion
            .is_some_and(|at| at.elapsed() < Duration::from_secs(3));
        let changed = refreshed
            || self
                .last_ui_state
                .as_ref()
                .is_none_or(|last| ui_state_changed(state, last))
            || self
                .last_ui_snapshot
                .as_ref()
                .is_none_or(|last| frame.snapshot.differs_from(last));
        if !(changed || settling || self.last_ui_sent.elapsed() >= Duration::from_secs(5)) {
            return Ok(());
        }
        self.last_ui_state = Some(state.clone());
        self.last_ui_snapshot = Some(frame.snapshot.clone());
        self.last_ui_sent = Instant::now();
        let mut output = std::io::stdout().lock();
        serde_json::to_writer(&mut output, &frame).map_err(|e| e.to_string())?;
        output
            .write_all(b"\n")
            .and_then(|()| output.flush())
            .map_err(|e| e.to_string())
    }

    /// The desk polls at 1 Hz and publishes more than once per reading, but consecutive
    /// snapshots normally differ only in the clock. Write when something a reader would
    /// notice changed, and otherwise at most every 30 s so the file stays fresh.
    fn publish_snapshot(&mut self, state: &DeskState) {
        let snapshot = Snapshot::from_state(
            state,
            self.previous.as_ref(),
            self.saved_today.as_ref(),
            Timestamp::now(),
        );
        let changed = self
            .last_snapshot
            .as_ref()
            .is_none_or(|last| snapshot.differs_from(last));
        if changed || self.last_snapshot_write.elapsed() > Duration::from_secs(30) {
            self.last_snapshot_write = Instant::now();
            if let Err(e) = self.snapshots.write(&snapshot) {
                tracing::warn!(error = %e, "could not write snapshot");
            }
        }
        self.last_snapshot = Some(snapshot);
    }

    /// Writes history.json when the merged event count changed, every 60 s, or right
    /// after a (re)connect. Each write waits for the previous one so they land in order.
    async fn write_history_if_needed(
        &mut self,
        handle: &DeskHandle,
        state: &DeskState,
        just_connected: bool,
    ) {
        let revision_changed = self.last_history_revision != Some(state.history_revision);
        let stale = self.last_history_write.elapsed() >= Duration::from_secs(60);
        if !(just_connected || revision_changed || stale) {
            return;
        }
        let Some(document) = handle.history_document().await else {
            return;
        };
        self.last_history_write = Instant::now();
        self.last_history_revision = Some(state.history_revision);
        let store = self.history.clone();
        if let Some(previous) = self.history_write.take() {
            let _ = previous.await;
        }
        self.history_write = Some(tokio::task::spawn_blocking(move || {
            if let Err(e) = store.merge_and_write(document) {
                tracing::warn!(error = %e, "could not write history");
            }
        }));
    }

    /// On exit the snapshot must stop looking live.
    fn write_disconnected(&mut self) {
        let mut snapshot = self
            .last_snapshot
            .clone()
            .unwrap_or_else(|| Snapshot::disconnected(Timestamp::now()));
        snapshot.connected = false;
        snapshot.is_moving = false;
        snapshot.next_move = None;
        snapshot.updated_at = Timestamp::now();
        let _ = self.snapshots.write(&snapshot);
    }
}

async fn process_commands(queue: &CommandQueue, handle: &DeskHandle) {
    for envelope in queue.pending(Timestamp::now()) {
        tracing::info!(id = %envelope.id, command = ?envelope.command, "applying");
        let result = execute_command(envelope.command, handle).await;
        let (success, message) = match result {
            Ok(message) => (true, message),
            Err(e) => (false, Some(e)),
        };
        if let Err(e) = queue.complete(envelope.id, success, message.clone(), Timestamp::now()) {
            tracing::error!(id = %envelope.id, error = %e, "could not record the result; withdrawing");
            let _ = queue.cancel(envelope.id);
        }
        if success {
            tracing::info!(id = %envelope.id, "succeeded");
        } else if let Some(message) = message {
            tracing::error!(id = %envelope.id, error = %message, "failed");
        }
    }
    queue.purge(seconds(3600), Timestamp::now());
}

async fn execute_command(command: Command, handle: &DeskHandle) -> Result<Option<String>, String> {
    let result = match command {
        Command::Inspect => {
            return serde_json::to_string(&handle.current())
                .map(Some)
                .map_err(|e| e.to_string())
        }
        Command::CaptureSittingPreset => handle.capture_sitting_preset().await,
        Command::CaptureStandingPreset => handle.capture_standing_preset().await,
        Command::CaptureCustomPreset(which) => handle.capture_custom_preset(which).await,
        Command::SetCruise(slot) => handle.set_cruise(slot).await,
        Command::SetPaused(paused) => handle.set_paused(paused).await,
        Command::SetPulseOnly(on) => handle.set_pulse_only(on).await,
        Command::SetUser(index) => handle.set_user(index).await,
        Command::SetUserName(name) => handle.set_user_name(name).await,
        Command::SetPresetName(which, name) => handle.set_preset_name(which, name).await,
        Command::SyncClock => handle.sync_clock().await,
        Command::Reconnect => {
            // A connect can take 45 s, longer than anyone waits for a result.
            handle.reconnect().await;
            Ok(())
        }
    };
    result.map(|()| None).map_err(|e| e.to_string())
}

/// Ctrl-C everywhere; SIGTERM too on Unix, so a service manager stopping the daemon still
/// gets the disconnected snapshot written.
async fn shutdown_signal() {
    #[cfg(unix)]
    {
        let mut term =
            match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
                Ok(term) => term,
                Err(_) => return tokio::signal::ctrl_c().await.unwrap_or(()),
            };
        tokio::select! {
            _ = tokio::signal::ctrl_c() => {}
            _ = term.recv() => {}
        }
    }
    #[cfg(not(unix))]
    {
        let _ = tokio::signal::ctrl_c().await;
    }
}

pub async fn serve(
    dir: PathBuf,
    sim: Option<Scenario>,
    hosted: bool,
    probe_registers: bool,
) -> Result<(), String> {
    std::fs::create_dir_all(&dir).map_err(|e| format!("Cannot create {}: {e}", dir.display()))?;
    // An OS-owned lock releases even after a crash; a second app/CLI must never share BLE
    // ownership or race the archive writer.
    let service_lock = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(dir.join(".service.lock"))
        .map_err(|e| e.to_string())?;
    service_lock
        .try_lock_exclusive()
        .map_err(|_| "A Tempo backend is already running for this data directory.".to_string())?;
    tracing::info!(dir = %dir.display(), sim = ?sim.map(|s| s.name()), probe_registers, "tempo serve");
    let transport: Arc<dyn Transport> = match sim {
        Some(scenario) => Arc::new(SimulatedTransport::new(scenario)),
        None => Arc::new(tempo_ble::BleTransport::new(tempo_ble::BleConfig {
            // The desk's identifier from the last connection lives here, so the next one
            // skips the scan.
            remembered_peripheral: Some(dir.join("peripheral-id")),
            ..tempo_ble::BleConfig::default()
        })),
    };
    let move_store = Arc::new(ObservedMoveFile::new(&dir));
    let handle = Desk::spawn(
        transport,
        DeskConfig {
            probe_registers,
            ..DeskConfig::default()
        },
        Arc::new(SystemClock),
        Some(move_store),
    );
    handle.start().await;

    let tz = TimeZone::system();
    let history = HistoryStore::new(&dir);
    let saved_document = history.read();
    let saved = saved_document
        .as_ref()
        .and_then(|doc| saved_today(doc, Timestamp::now(), &tz));
    let mut publisher = Publisher {
        ui_document: saved_document,
        ui_revision: None,
        last_ui_refresh: Instant::now() - Duration::from_secs(3600),
        snapshots: SnapshotStore::new(&dir),
        previous: SnapshotStore::new(&dir).read(),
        history,
        saved_today: saved,
        last_snapshot: None,
        last_snapshot_write: Instant::now() - Duration::from_secs(3600),
        last_history_write: Instant::now() - Duration::from_secs(3600),
        last_history_revision: None,
        history_write: None,
        last_ui_state: None,
        last_ui_snapshot: None,
        last_ui_sent: Instant::now() - Duration::from_secs(3600),
        last_motion: None,
    };
    let queue = CommandQueue::new(&dir);
    let mut state_rx = handle.state();
    // The hosting app nudges stdin whenever a command is queued, so the queue is read on
    // demand; the tick is for the CLI, which can't nudge, and costs one directory read.
    let mut command_tick = tokio::time::interval(Duration::from_secs(1));
    let (host_exit_tx, host_exit_rx) = tokio::sync::oneshot::channel();
    let (nudge_tx, mut nudge_rx) = tokio::sync::mpsc::unbounded_channel();
    if hosted {
        // A plain thread, rather than Tokio's blocking pool: signal shutdown must not wait
        // for an uncancellable stdin read. EOF also handles the hosting app being killed.
        std::thread::spawn(move || {
            let mut input = std::io::stdin().lock();
            let mut bytes = [0; 64];
            while let Ok(n) = input.read(&mut bytes) {
                if n == 0 {
                    break;
                }
                let _ = nudge_tx.send(());
            }
            let _ = host_exit_tx.send(());
        });
    }
    let host_exit = async {
        if hosted {
            let _ = host_exit_rx.await;
        } else {
            std::future::pending::<()>().await;
        }
    };
    let signal = shutdown_signal();
    tokio::pin!(host_exit, signal);
    let mut was_connected = false;
    loop {
        tokio::select! {
            changed = state_rx.changed() => {
                if changed.is_err() { break; }
                let state = state_rx.borrow_and_update().clone();
                publisher.publish_snapshot(&state);
                if hosted {
                    if let Err(error) = publisher.publish_ui(&handle, &state, &tz).await {
                        tracing::info!(%error, "UI stream closed");
                        break;
                    }
                }
                let just_connected = state.is_connected() && !was_connected;
                was_connected = state.is_connected();
                publisher.write_history_if_needed(&handle, &state, just_connected).await;
            }
            _ = command_tick.tick() => process_commands(&queue, &handle).await,
            Some(()) = nudge_rx.recv() => process_commands(&queue, &handle).await,
            _ = &mut host_exit => { tracing::info!("hosting app stopped"); break; }
            _ = &mut signal => {
                tracing::info!("stopping");
                break;
            }
        }
    }
    let state = handle.current();
    publisher
        .write_history_if_needed(&handle, &state, true)
        .await;
    if let Some(write) = publisher.history_write.take() {
        let _ = write.await;
    }
    publisher.write_disconnected();
    handle.shutdown().await;
    Ok(())
}

#[cfg(test)]
mod inspection_tests {
    use super::*;
    use tempo_desk::fake::FakeTransport;

    #[tokio::test]
    async fn queued_inspection_returns_state_without_connecting_or_touching_registers() {
        let fake = Arc::new(FakeTransport::new());
        let handle = Desk::spawn(
            fake.clone(),
            DeskConfig::default(),
            Arc::new(SystemClock),
            None,
        );
        let directory = tempfile::tempdir().unwrap();
        let queue = CommandQueue::new(directory.path());
        let id = queue.enqueue(Command::Inspect, Timestamp::now()).unwrap();
        process_commands(&queue, &handle).await;
        let result = queue.result(id).unwrap();
        assert!(result.success);
        let state: DeskState = serde_json::from_str(result.message.as_deref().unwrap()).unwrap();
        assert!(!state.is_connected());
        assert_eq!(fake.connect_calls(), 0);
        assert_eq!(fake.read_count(), 0);
        assert!(fake.writes().is_empty());
        assert!(queue.pending(Timestamp::now()).is_empty());
        handle.stop().await;
    }
}
