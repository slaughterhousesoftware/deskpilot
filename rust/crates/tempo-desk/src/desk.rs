//! The service: owns one transport and one `DeskSession`, keeps the desk model current,
//! and publishes `DeskState`. One task does everything, so there are no locks and no
//! reentrancy: commands from UIs arrive on a channel and run between polls.

use std::collections::HashMap;
use std::future::Future;
use std::sync::Arc;
use std::time::Duration;

use futures::StreamExt;
use jiff::{SignedDuration, Timestamp};
use tempo_core::cruise::CruiseSlot;
use tempo_core::model::{ConnectionStatus, DeskState, HistoryDocument, Settings};
use tempo_core::registers::{
    addr, cruise_slot_address, encode_name, user_base, user_offset, CountdownTiming, DeskClock,
    FirmwareVersion, RegisterBlock, StatusWord, UserFlags, NAME_LENGTH,
};
use tempo_core::session::{DeskSession, SessionConfig};
use tempo_core::store::{LiveCountdown, ObservedMoveStore};
use tempo_core::time::Clock;
use tokio::sync::{mpsc, oneshot, watch};
use tokio::task::JoinHandle;
use tokio::time::Instant;

use crate::transport::{ConnectionEvent, DeskError, EventStream, Transport};

#[derive(Clone, Debug)]
pub struct DeskConfig {
    /// Status poll cadence while the desk is stationary.
    pub poll_interval: Duration,
    /// Status poll cadence while the desk is moving or settling, so the live height and the
    /// moving indicator update smoothly instead of in ~1 s jumps.
    pub moving_poll_interval: Duration,
    /// Base history poll cadence; the session tightens it around a predicted move.
    pub history_poll_interval: Duration,
    /// Refresh the current user's settings, including edits made by the phone or handset.
    pub settings_poll_interval: Duration,
    /// Opt-in protocol research: extra reads of undocumented registers near a move.
    /// Keep disabled in the app: these serialize with live height and command traffic.
    pub probe_registers: bool,
    pub initial_backoff: Duration,
    pub background_retry_interval: Duration,
    /// Visible connection attempts before retrying quietly in the background.
    pub foreground_attempt_limit: u32,
    pub session: SessionConfig,
}

impl Default for DeskConfig {
    fn default() -> Self {
        Self {
            // A quarter second at rest too: a paddle press shows in the menu bar within one
            // poll rather than up to a second later. Eight GATT operations a second is well
            // within the link's capacity (2026-10-29).
            poll_interval: Duration::from_millis(250),
            moving_poll_interval: Duration::from_millis(250),
            history_poll_interval: Duration::from_secs(5),
            settings_poll_interval: Duration::from_secs(30),
            probe_registers: false,
            initial_backoff: Duration::from_secs(2),
            background_retry_interval: Duration::from_secs(60),
            foreground_attempt_limit: 3,
            session: SessionConfig::default(),
        }
    }
}

type Reply<T> = oneshot::Sender<T>;

enum Request {
    Start,
    Stop(Reply<()>),
    CaptureSittingPreset(Reply<Result<(), DeskError>>),
    CaptureStandingPreset(Reply<Result<(), DeskError>>),
    CaptureCustomPreset(u8, Reply<Result<(), DeskError>>),
    SetCruise(Option<CruiseSlot>, Reply<Result<(), DeskError>>),
    SetPaused(bool, Reply<Result<(), DeskError>>),
    SetPulseOnly(bool, Reply<Result<(), DeskError>>),
    SetUser(u8, Reply<Result<(), DeskError>>),
    SetUserName(String, Reply<Result<(), DeskError>>),
    SetPresetName(u8, String, Reply<Result<(), DeskError>>),
    SyncClock(Reply<Result<(), DeskError>>),
    Reconnect,
    HistoryDocument(Reply<Option<HistoryDocument>>),
    DecodedEntryCount(Reply<usize>),
}

/// The handle UIs hold: the state stream and the commands.
#[derive(Clone)]
pub struct DeskHandle {
    tx: mpsc::Sender<Request>,
    state: watch::Receiver<DeskState>,
    task: Arc<std::sync::Mutex<Option<JoinHandle<()>>>>,
}

pub struct Desk;

impl Desk {
    /// Spawns the service task. It starts idle: call `DeskHandle::start`.
    pub fn spawn(
        transport: Arc<dyn Transport>,
        config: DeskConfig,
        clock: Arc<dyn Clock>,
        move_store: Option<Arc<dyn ObservedMoveStore>>,
    ) -> DeskHandle {
        let (tx, rx) = mpsc::channel(32);
        let (state_tx, state) = watch::channel(DeskState::default());
        let events = transport.events();
        let session = DeskSession::new(config.session.clone());
        let actor = Actor {
            transport,
            cfg: config,
            clock,
            move_store,
            saved_countdown: None,
            session,
            state: DeskState::default(),
            state_tx,
            connected: false,
            wall_base: (Instant::now(), Timestamp::now()),
            last_raw_status_flagged: 0,
            probe_values: HashMap::new(),
            firmware: None,
            names_read: false,
            block_reads: true,
        };
        let task = tokio::spawn(actor.run(rx, events));
        DeskHandle {
            tx,
            state,
            task: Arc::new(std::sync::Mutex::new(Some(task))),
        }
    }
}

impl DeskHandle {
    /// A receiver that yields every published state. `borrow()` for the latest.
    pub fn state(&self) -> watch::Receiver<DeskState> {
        self.state.clone()
    }

    pub fn current(&self) -> DeskState {
        self.state.borrow().clone()
    }

    /// Waits for the first state satisfying `predicate` (the current one counts).
    pub async fn wait_for(&self, predicate: impl FnMut(&DeskState) -> bool) -> DeskState {
        let mut rx = self.state.clone();
        rx.mark_changed();
        let found = rx.wait_for(predicate).await.map(|state| state.clone());
        found.unwrap_or_else(|_| self.current())
    }

    pub async fn start(&self) {
        let _ = self.tx.send(Request::Start).await;
    }

    /// Stops the connection loop and waits for it to finish, so a `stop().await; start()`
    /// never runs the old loop and the new one together.
    pub async fn stop(&self) {
        let (reply, ack) = oneshot::channel();
        if self.tx.send(Request::Stop(reply)).await.is_ok() {
            let _ = ack.await;
        }
    }

    /// Drops the connection and connects again, with fresh backoff.
    pub async fn reconnect(&self) {
        let _ = self.tx.send(Request::Reconnect).await;
    }

    async fn ask<T>(&self, make: impl FnOnce(Reply<T>) -> Request) -> Option<T> {
        let (reply, answer) = oneshot::channel();
        self.tx.send(make(reply)).await.ok()?;
        answer.await.ok()
    }

    async fn command(
        &self,
        make: impl FnOnce(Reply<Result<(), DeskError>>) -> Request,
    ) -> Result<(), DeskError> {
        self.ask(make).await.unwrap_or(Err(DeskError::NotConnected))
    }

    pub async fn capture_sitting_preset(&self) -> Result<(), DeskError> {
        self.command(Request::CaptureSittingPreset).await
    }

    pub async fn capture_standing_preset(&self) -> Result<(), DeskError> {
        self.command(Request::CaptureStandingPreset).await
    }

    /// Stores the desk's current height as custom preset 1 or 2.
    pub async fn capture_custom_preset(&self, which: u8) -> Result<(), DeskError> {
        self.command(|r| Request::CaptureCustomPreset(which, r))
            .await
    }

    /// Pulse (nudge) instead of moving when the interval runs out.
    pub async fn set_pulse_only(&self, on: bool) -> Result<(), DeskError> {
        self.command(|r| Request::SetPulseOnly(on, r)).await
    }

    /// Makes user 0 or 1 the desk's active user; settings are re-read for them.
    pub async fn set_user(&self, index: u8) -> Result<(), DeskError> {
        self.command(|r| Request::SetUser(index, r)).await
    }

    pub async fn set_user_name(&self, name: String) -> Result<(), DeskError> {
        self.command(|r| Request::SetUserName(name, r)).await
    }

    pub async fn set_preset_name(&self, which: u8, name: String) -> Result<(), DeskError> {
        self.command(|r| Request::SetPresetName(which, name, r))
            .await
    }

    /// `None` disables cruise control. Otherwise writes slot 1 (the custom slot) and selects it.
    pub async fn set_cruise(&self, slot: Option<CruiseSlot>) -> Result<(), DeskError> {
        self.command(|r| Request::SetCruise(slot, r)).await
    }

    pub async fn set_paused(&self, paused: bool) -> Result<(), DeskError> {
        self.command(|r| Request::SetPaused(paused, r)).await
    }

    pub async fn sync_clock(&self) -> Result<(), DeskError> {
        self.command(Request::SyncClock).await
    }

    /// The merged, dated history for dashboards. `None` until settings have been read.
    pub async fn history_document(&self) -> Option<HistoryDocument> {
        self.ask(Request::HistoryDocument).await.flatten()
    }

    /// History entries decoded so far, including NOPs. Tests use it to wait for ingestion.
    pub async fn decoded_entry_count(&self) -> usize {
        self.ask(Request::DecodedEntryCount).await.unwrap_or(0)
    }

    /// Ends the service task. The handle is unusable afterwards.
    pub async fn shutdown(&self) {
        self.stop().await;
        let task = self.task.lock().unwrap().take();
        if let Some(task) = task {
            task.abort();
            let _ = task.await;
        }
    }
}

enum Control {
    Continue,
    Stop(Reply<()>),
    Reconnect,
}

enum Interrupted<T> {
    Done(T),
    Stop(Reply<()>),
    Reconnect,
}

struct Ctx {
    rx: mpsc::Receiver<Request>,
    events: EventStream,
}

struct Actor {
    transport: Arc<dyn Transport>,
    cfg: DeskConfig,
    clock: Arc<dyn Clock>,
    move_store: Option<Arc<dyn ObservedMoveStore>>,
    /// What the store holds for the live countdown, so it is written only when it changes.
    saved_countdown: Option<LiveCountdown>,
    session: DeskSession,
    state: DeskState,
    state_tx: watch::Sender<DeskState>,
    connected: bool,
    /// Poll cadence and settle timing run on the runtime's clock, not the injected one:
    /// business time may be frozen in tests and must never gate IO.
    wall_base: (Instant, Timestamp),
    last_raw_status_flagged: u32,
    probe_values: HashMap<u32, u32>,
    /// Register 4, read once per connection (it is in the global block).
    firmware: Option<String>,
    /// The name fields have been read this connection.
    names_read: bool,
    /// Whether bursts over the register space are trusted. A desk that serves them as
    /// garbage (every word 0xDEADBEEF, say) demotes the connection to register reads.
    block_reads: bool,
}

impl Actor {
    fn now(&self) -> Timestamp {
        self.clock.now()
    }

    fn wall(&self) -> Timestamp {
        let elapsed = Instant::now().saturating_duration_since(self.wall_base.0);
        self.wall_base.1 + SignedDuration::try_from(elapsed).unwrap_or(SignedDuration::ZERO)
    }

    fn publish(&mut self, mutate: impl FnOnce(&mut DeskState)) {
        mutate(&mut self.state);
        self.state.updated_at = Some(self.now());
        self.state_tx.send_replace(self.state.clone());
    }

    async fn run(mut self, rx: mpsc::Receiver<Request>, events: EventStream) {
        let mut ctx = Ctx { rx, events };
        loop {
            // Idle: only commands, until started.
            let Some(request) = ctx.rx.recv().await else {
                return;
            };
            match request {
                Request::Start | Request::Reconnect => {}
                other => {
                    self.handle_request(other).await;
                    continue;
                }
            }
            if let Some(ack) = self.run_loop(&mut ctx).await {
                let _ = ack.send(());
            }
        }
    }

    /// Connect, sync, poll until disconnected, back off, repeat. Returns when stopped.
    async fn run_loop(&mut self, ctx: &mut Ctx) -> Option<Reply<()>> {
        let mut backoff = self.cfg.initial_backoff;
        let mut failed_attempts = 0u32;
        self.publish(|s| s.reconnecting_in_background = false);
        loop {
            let mut synced = false;
            // Events from the connection just dropped (its own "disconnected") must not be
            // read as news about the one being made.
            Self::drain_events(ctx);
            if !self.state.reconnecting_in_background {
                self.publish(|s| s.status = ConnectionStatus::Connecting);
            }
            let transport = self.transport.clone();
            match self
                .interruptible(async move { transport.connect().await }, ctx)
                .await
            {
                Interrupted::Stop(ack) => return Some(self.finish_stop(ack).await),
                Interrupted::Reconnect => {
                    failed_attempts = 0;
                    backoff = self.cfg.initial_backoff;
                    continue;
                }
                Interrupted::Done(Err(error)) => self.note_error(error),
                Interrupted::Done(Ok(())) => {
                    self.connected = true;
                    self.publish(|s| {
                        s.status = ConnectionStatus::Connected;
                        s.last_error = None;
                    });
                    match self.after_connect().await {
                        Err(error) => self.note_error(error),
                        Ok(()) => {
                            synced = true;
                            failed_attempts = 0;
                            backoff = self.cfg.initial_backoff;
                            self.publish(|s| s.reconnecting_in_background = false);
                            match self.poll_until_disconnect(ctx).await {
                                Interrupted::Stop(ack) => return Some(self.finish_stop(ack).await),
                                Interrupted::Reconnect => {
                                    self.drop_connection().await;
                                    continue;
                                }
                                Interrupted::Done(error) => self.note_error(error),
                            }
                        }
                    }
                }
            }
            // Losing an established connection is not itself a failed reconnect attempt.
            if !synced {
                failed_attempts += 1;
            }
            let quiet = failed_attempts >= self.cfg.foreground_attempt_limit;
            self.publish(|s| s.reconnecting_in_background = quiet);
            let delay = if quiet {
                self.cfg.background_retry_interval
            } else {
                backoff
            };
            match self.interruptible(tokio::time::sleep(delay), ctx).await {
                Interrupted::Stop(ack) => return Some(self.finish_stop(ack).await),
                Interrupted::Reconnect => {
                    failed_attempts = 0;
                    backoff = self.cfg.initial_backoff;
                    self.publish(|s| s.reconnecting_in_background = false);
                    continue;
                }
                Interrupted::Done(()) => {}
            }
            backoff = (backoff * 2).min(self.cfg.background_retry_interval);
        }
    }

    fn note_error(&mut self, error: DeskError) {
        tracing::info!(%error, "run loop error");
        self.connected = false;
        match error {
            DeskError::BluetoothOff => self.publish(|s| {
                s.status = ConnectionStatus::BluetoothOff;
                s.last_error = Some("Bluetooth is turned off".into());
            }),
            DeskError::Unauthorized => self.publish(|s| {
                s.status = ConnectionStatus::Unauthorized;
                s.last_error = Some("Bluetooth access was denied".into());
            }),
            other => {
                // Written out for the UI, never the enum's debug text.
                let text = other.to_string();
                self.publish(|s| {
                    s.status = ConnectionStatus::Disconnected;
                    s.last_error = Some(text);
                });
            }
        }
    }

    async fn drop_connection(&mut self) {
        self.connected = false;
        self.transport.disconnect().await;
        self.publish(|s| {
            s.status = ConnectionStatus::Disconnected;
            s.is_moving = false;
        });
    }

    async fn finish_stop(&mut self, ack: Reply<()>) -> Reply<()> {
        self.drop_connection().await;
        self.publish(|s| s.reconnecting_in_background = false);
        ack
    }

    /// Awaits `fut` while still answering commands and connection events. Commands that
    /// need the desk run inline when connected, else fail with `NotConnected`.
    async fn interruptible<F: Future>(&mut self, fut: F, ctx: &mut Ctx) -> Interrupted<F::Output> {
        tokio::pin!(fut);
        loop {
            tokio::select! {
                biased;
                request = ctx.rx.recv() => match request {
                    None => return Interrupted::Stop(oneshot::channel().0),
                    Some(request) => match self.handle_request(request).await {
                        Control::Continue => {}
                        Control::Stop(ack) => return Interrupted::Stop(ack),
                        Control::Reconnect => return Interrupted::Reconnect,
                    },
                },
                event = ctx.events.next() => {
                    if let Some(event) = event { self.handle_event(event); }
                }
                output = &mut fut => return Interrupted::Done(output),
            }
        }
    }

    fn drain_events(ctx: &mut Ctx) {
        use futures::FutureExt;
        while let Some(Some(event)) = ctx.events.next().now_or_never() {
            tracing::debug!(?event, "stale event dropped");
        }
    }

    fn handle_event(&mut self, event: ConnectionEvent) {
        tracing::info!(?event, "event");
        match event {
            ConnectionEvent::Connecting => {
                if !self.state.reconnecting_in_background {
                    self.publish(|s| s.status = ConnectionStatus::Connecting);
                }
            }
            ConnectionEvent::Connected => {
                self.connected = true;
                self.publish(|s| {
                    s.status = ConnectionStatus::Connected;
                    s.last_error = None;
                });
            }
            ConnectionEvent::Disconnected { reason } => {
                self.connected = false;
                self.publish(|s| {
                    s.status = ConnectionStatus::Disconnected;
                    s.last_error = reason;
                    s.is_moving = false;
                });
            }
            ConnectionEvent::BluetoothOff => {
                self.connected = false;
                self.publish(|s| s.status = ConnectionStatus::BluetoothOff);
            }
            ConnectionEvent::Unauthorized => {
                self.connected = false;
                self.publish(|s| s.status = ConnectionStatus::Unauthorized);
            }
        }
    }

    async fn handle_request(&mut self, request: Request) -> Control {
        match request {
            Request::Start => Control::Continue,
            Request::Stop(ack) => Control::Stop(ack),
            Request::Reconnect => Control::Reconnect,
            Request::CaptureSittingPreset(reply) => {
                let _ = reply.send(self.capture_preset(user_offset::SITTING_HEIGHT).await);
                Control::Continue
            }
            Request::CaptureStandingPreset(reply) => {
                let _ = reply.send(self.capture_preset(user_offset::STANDING_HEIGHT).await);
                Control::Continue
            }
            Request::CaptureCustomPreset(which, reply) => {
                let result = match which {
                    1 => self.capture_preset(user_offset::CUSTOM_HEIGHT_ONE).await,
                    2 => self.capture_preset(user_offset::CUSTOM_HEIGHT_TWO).await,
                    _ => Err(DeskError::InvalidValue(
                        "Custom presets are 1 and 2.".into(),
                    )),
                };
                let _ = reply.send(result);
                Control::Continue
            }
            Request::SetPulseOnly(on, reply) => {
                let _ = reply.send(self.set_flag(UserFlags::PULSE_ONLY, on).await);
                Control::Continue
            }
            Request::SetUser(index, reply) => {
                let _ = reply.send(self.set_user(index).await);
                Control::Continue
            }
            Request::SetUserName(name, reply) => {
                let _ = reply.send(self.set_name(user_offset::USER_NAME, &name).await);
                Control::Continue
            }
            Request::SetPresetName(which, name, reply) => {
                let result = match which {
                    1 => self.set_name(user_offset::PRESET_NAME_ONE, &name).await,
                    2 => self.set_name(user_offset::PRESET_NAME_TWO, &name).await,
                    _ => Err(DeskError::InvalidValue(
                        "Custom presets are 1 and 2.".into(),
                    )),
                };
                let _ = reply.send(result);
                Control::Continue
            }
            Request::SetCruise(slot, reply) => {
                let _ = reply.send(self.set_cruise(slot).await);
                Control::Continue
            }
            Request::SetPaused(paused, reply) => {
                let _ = reply.send(self.set_flag(UserFlags::PAUSED, paused).await);
                Control::Continue
            }
            Request::SyncClock(reply) => {
                let _ = reply.send(self.sync_clock().await);
                Control::Continue
            }
            Request::HistoryDocument(reply) => {
                let doc = self
                    .state
                    .settings
                    .clone()
                    .map(|settings| self.session.history_document(self.now(), &settings));
                let _ = reply.send(doc);
                Control::Continue
            }
            Request::DecodedEntryCount(reply) => {
                let _ = reply.send(self.session.decoded_entry_count());
                Control::Continue
            }
        }
    }

    // MARK: Connect and poll

    /// The first sync, arranged so the UI has the height within one burst of the link:
    /// the global block (firmware, the history clock and pointer, the user index and the
    /// status word) in one read, the user block in another, then the log. Every register
    /// read is a write and a read; a burst is two writes and a few notifications, so the
    /// twelve reads this used to take are now two bursts.
    async fn after_connect(&mut self) -> Result<(), DeskError> {
        tracing::info!("connected; syncing");
        let started = Instant::now();
        self.firmware = None;
        self.names_read = false;
        self.block_reads = true;
        self.probe_values.clear();
        // The desk's log says what it did while the link was down; what the app had seen
        // live (the latest countdown, a cancel) still holds unless the desk rebooted, which
        // the first history poll catches. Only the motion tracking starts over.
        self.session.reconnected();
        let (status, minutes, write_pointer) = match self.read_global_block().await {
            Some(global) => global,
            None => (
                self.read(addr::STATUS).await?,
                self.read(addr::MINUTES_SINCE_POWER_ON).await?,
                self.read(addr::HISTORY_WRITE_POINTER).await?,
            ),
        };
        // Where the desk is, before anything else: the menu bar can show the height while
        // the settings and the log are still on their way.
        self.apply_status(status);
        self.refresh_settings().await?;
        self.session.anchor_clock(minutes, self.now());
        self.poll_history_from(minutes, write_pointer as usize)
            .await?;
        if let Some(store) = &self.move_store {
            self.session
                .restore_observed_moves(store.load(), self.now());
            if let Some(countdown) = store.load_countdown() {
                self.session.restore_countdown(countdown, self.now());
            }
            self.saved_countdown = store.load_countdown();
        }
        self.recompute_today();
        tracing::info!(
            ms = started.elapsed().as_millis(),
            blocks = self.block_reads,
            "synced"
        );
        // The phone app writes the clock on every sync; so does this.
        if let Err(error) = self.sync_clock().await {
            tracing::info!(%error, "clock not synced");
        }
        if let Err(error) = self.read_names().await {
            tracing::debug!(%error, "names not synced; will retry at the next settings refresh");
        }
        Ok(())
    }

    /// Registers 0..64 in one burst, checked for sense: `(status, minutes, write pointer)`.
    /// `None` demotes the connection to register reads.
    async fn read_global_block(&mut self) -> Option<(u32, u32, u32)> {
        if !self.block_reads {
            return None;
        }
        let block = match self.read_block(0, 4).await {
            Ok(block) => block,
            Err(error) => {
                tracing::info!(%error, "global block unreadable; reading registers");
                self.block_reads = false;
                return None;
            }
        };
        let firmware = block.get(addr::FIRMWARE_APPLICATION)?;
        let minutes = block.get(addr::MINUTES_SINCE_POWER_ON)?;
        let size = block.get(addr::HISTORY_SIZE)?;
        let pointer = block.get(addr::HISTORY_WRITE_POINTER)?;
        let status = block.get(addr::STATUS)?;
        let sane = FirmwareVersion::from_raw(firmware).major <= 15
            && (1..=0x10000).contains(&size)
            && pointer <= size
            && minutes != 0xDEAD_BEEF
            && status & 0x7FFF_0000 == 0;
        if !sane {
            tracing::info!(
                firmware = format!("{firmware:#x}"),
                size,
                pointer,
                minutes,
                status = format!("{status:#x}"),
                "global block makes no sense; reading registers"
            );
            self.block_reads = false;
            return None;
        }
        self.firmware = Some(FirmwareVersion::from_raw(firmware).to_string());
        Some((status, minutes, pointer))
    }

    async fn read_block(&self, base: u32, chunks: usize) -> Result<RegisterBlock, DeskError> {
        let transport = self.transport.clone();
        let expected = chunks * 20;
        let bytes = Self::retry_once(|| {
            let t = transport.clone();
            async move {
                let data = t.burst_read(base, chunks).await?;
                if data.len() < expected {
                    return Err(DeskError::BurstIncomplete {
                        expected,
                        got: data.len(),
                    });
                }
                Ok(data)
            }
        })
        .await?;
        Ok(RegisterBlock::new(base & !3, bytes))
    }

    async fn poll_until_disconnect(&mut self, ctx: &mut Ctx) -> Interrupted<DeskError> {
        let long_ago = Instant::now() - Duration::from_secs(3600);
        let mut last_history_poll = long_ago;
        // after_connect just loaded the settings; do not immediately read them again.
        let mut last_settings_poll = Instant::now();
        while self.connected {
            if let Err(e) = self.poll_status().await {
                return Interrupted::Done(e);
            }
            let wall = Instant::now();
            let history_interval = self.history_poll_interval();
            let armed = history_interval < self.cfg.history_poll_interval;
            if wall.duration_since(last_history_poll) >= history_interval {
                last_history_poll = wall;
                if let Err(e) = self.poll_history().await {
                    return Interrupted::Done(e);
                }
                if armed && self.cfg.probe_registers {
                    let _ = self.poll_probe().await;
                }
            }
            if wall.duration_since(last_settings_poll) >= self.cfg.settings_poll_interval {
                // A settings failure leaves the last complete snapshot in place and must
                // not tear down an otherwise healthy live-height connection.
                if let Err(error) = self.poll_settings().await {
                    tracing::debug!(%error, "settings not refreshed");
                }
                last_settings_poll = Instant::now();
            }
            // Every iteration, so a freshly ingested COUNTDOWN entry reaches `next_move` at
            // once rather than up to a history interval later.
            self.recompute_today();
            // Stay fast until the height has actually stopped changing, not just until the
            // motion bit clears; and while the desk is announcing a move, so the motor
            // start - or its absence, a wave-off - is seen within a quarter second.
            let tracker = self.session.tracker();
            let moving = tracker.last_status().is_some_and(|w| w.is_moving);
            let settling = tracker.is_settling(self.wall());
            let announced = self.session.status_poll_fast(self.now());
            let interval = if moving || settling || announced {
                self.cfg.moving_poll_interval
            } else {
                self.cfg.poll_interval
            };
            match self.interruptible(tokio::time::sleep(interval), ctx).await {
                Interrupted::Done(()) => {}
                Interrupted::Stop(ack) => return Interrupted::Stop(ack),
                Interrupted::Reconnect => return Interrupted::Reconnect,
            }
        }
        Interrupted::Done(DeskError::NotConnected)
    }

    fn history_poll_interval(&self) -> Duration {
        let base = SignedDuration::try_from(self.cfg.history_poll_interval)
            .unwrap_or(SignedDuration::from_secs(5));
        let interval = DeskSession::history_poll_interval(
            self.state.today.as_ref(),
            self.state.is_moving,
            self.now(),
            base,
        );
        Duration::try_from(interval).unwrap_or(self.cfg.history_poll_interval)
    }

    /// Retries once after 250 ms on transient failures; steady-state errors surface at once.
    async fn retry_once<T, Fut>(op: impl Fn() -> Fut) -> Result<T, DeskError>
    where
        Fut: Future<Output = Result<T, DeskError>>,
    {
        match op().await {
            Err(e) if e.is_transient() => {
                tokio::time::sleep(Duration::from_millis(250)).await;
                op().await
            }
            other => other,
        }
    }

    async fn read(&self, address: u32) -> Result<u32, DeskError> {
        let transport = self.transport.clone();
        Self::retry_once(|| {
            let t = transport.clone();
            async move { t.read_register(address).await }
        })
        .await
    }

    async fn poll_status(&mut self) -> Result<(), DeskError> {
        let raw = self.read(addr::STATUS).await?;
        self.apply_status(raw);
        Ok(())
    }

    /// One status word, wherever it was read: into the tracker and out to the UI.
    fn apply_status(&mut self, raw: u32) {
        let word = StatusWord::from_raw(raw);
        // Bits 16..30 have only ever been seen as zero while idle; if the desk flags its
        // countdown or pulse anywhere in this register, this is where it would show.
        if raw & 0x7FFF_0000 != 0 && raw != self.last_raw_status_flagged {
            self.last_raw_status_flagged = raw;
            tracing::info!(raw = format!("{raw:#x}"), "status raw");
        }
        let previous = self.session.tracker().last_status();
        if word.is_moving
            || previous.is_some_and(|p| p.is_moving)
            || previous.map(|p| p.height_tenths) != Some(word.height_tenths)
        {
            tracing::debug!(
                height = word.height_tenths,
                moving = word.is_moving,
                "status sample"
            );
        }
        let (now, wall) = (self.now(), self.wall());
        let note = self
            .session
            .note_status(word, self.state.settings.as_ref(), now, wall);
        if note.moves_changed {
            if let Some(store) = &self.move_store {
                store.save(self.session.observed_moves());
            }
        }
        if note.observation.publish {
            // Only once the motor has stopped. While the paddle is held the model can say
            // where the desk would stop if released, but a readout heading there runs past
            // the hand's actual stop and then turns back, which reads as a wobble.
            let predicted = note
                .prediction
                .filter(|p| p.coasting)
                .map(|p| p.final_tenths);
            self.publish(|s| {
                s.height_tenths = Some(word.height_tenths);
                s.is_moving = word.is_moving;
                s.predicted_height_tenths = predicted;
            });
        } else {
            tracing::info!(height = word.height_tenths, "ignoring implausible height");
        }
    }

    async fn poll_history(&mut self) -> Result<(), DeskError> {
        let write_pointer = self.read(addr::HISTORY_WRITE_POINTER).await? as usize;
        let minutes = self.read(addr::MINUTES_SINCE_POWER_ON).await?;
        self.poll_history_from(minutes, write_pointer).await
    }

    /// A history poll whose registers 44 and 32 were just read (as part of a block).
    async fn poll_history_from(
        &mut self,
        minutes: u32,
        write_pointer: usize,
    ) -> Result<(), DeskError> {
        let plan = self
            .session
            .begin_history_poll(minutes, write_pointer, self.now());
        if plan.resync.is_some() {
            // The desk rebooted: its timer restarted with it, so moves from before the
            // reboot must not anchor the countdown after a restart of the app either.
            if let Some(store) = &self.move_store {
                store.save(&[]);
            }
        }
        let mut collected = Vec::new();
        for burst in &plan.bursts {
            let transport = self.transport.clone();
            let (address, chunks, expected) = (burst.address, burst.chunks, burst.expected_bytes());
            let data = Self::retry_once(|| {
                let t = transport.clone();
                async move {
                    let data = t.burst_read(address, chunks).await?;
                    if data.len() < expected {
                        return Err(DeskError::BurstIncomplete {
                            expected,
                            got: data.len(),
                        });
                    }
                    Ok(data)
                }
            })
            .await?;
            collected.extend_from_slice(burst.slice(&data));
        }
        self.session.ingest(&collected, write_pointer, self.now());
        Ok(())
    }

    pub(crate) async fn refresh_settings(&mut self) -> Result<(), DeskError> {
        let user_index: u8 = if self.read(addr::CURRENT_USER).await? == 0 {
            0
        } else {
            1
        };
        let base = user_base(user_index);
        // The first 44 bytes of the user block in one burst, else register by register.
        let block = if self.block_reads {
            match self.read_block(base, 3).await {
                Ok(block) if Self::user_block_sane(&block, base) => Some(block),
                Ok(_) => {
                    tracing::info!("user block makes no sense; reading registers");
                    self.block_reads = false;
                    None
                }
                Err(error) => {
                    tracing::info!(%error, "user block unreadable; reading registers");
                    self.block_reads = false;
                    None
                }
            }
        } else {
            None
        };
        let block = block.as_ref();
        let flags = self.word(block, base + user_offset::FLAGS).await?;
        let slot = self
            .word(block, base + user_offset::ACTIVE_CRUISE_SLOT)
            .await? as u8;
        let countdown_timing = CountdownTiming::from_raw(
            self.word(block, base + user_offset::COUNTDOWN_AND_PULSE)
                .await?,
        );
        let middle_of_night_hour = self
            .word(block, base + user_offset::MIDDLE_OF_NIGHT_HOUR)
            .await? as u8;
        let standing_height_tenths = self
            .word(block, base + user_offset::STANDING_HEIGHT)
            .await? as u16;
        let sitting_height_tenths =
            self.word(block, base + user_offset::SITTING_HEIGHT).await? as u16;
        let custom_height_one_tenths = self
            .word(block, base + user_offset::CUSTOM_HEIGHT_ONE)
            .await? as u16;
        let custom_height_two_tenths = self
            .word(block, base + user_offset::CUSTOM_HEIGHT_TWO)
            .await? as u16;
        let cruise = if slot > 0 {
            Some(CruiseSlot::from_raw(
                self.read(cruise_slot_address(user_index, slot)).await?,
            ))
        } else {
            None
        };
        let firmware = match &self.firmware {
            Some(firmware) => firmware.clone(),
            None => {
                let firmware =
                    FirmwareVersion::from_raw(self.read(addr::FIRMWARE_APPLICATION).await?)
                        .to_string();
                self.firmware = Some(firmware.clone());
                firmware
            }
        };
        // Names survive a refresh for the same user; another user's are read afresh.
        let previous = self
            .state
            .settings
            .as_ref()
            .filter(|s| s.user_index == user_index);
        let settings = Settings {
            firmware,
            user_index,
            flags,
            active_cruise_slot: slot,
            cruise,
            countdown_timing,
            middle_of_night_hour,
            standing_height_tenths,
            sitting_height_tenths,
            custom_height_one_tenths,
            custom_height_two_tenths,
            user_name: previous.and_then(|s| s.user_name.clone()),
            preset_name_one: previous.and_then(|s| s.preset_name_one.clone()),
            preset_name_two: previous.and_then(|s| s.preset_name_two.clone()),
        };
        if previous.is_none() {
            self.names_read = false;
        }
        if self.state.settings.as_ref() != Some(&settings) {
            self.publish(|s| s.settings = Some(settings));
        }
        Ok(())
    }

    /// A register from the block when it has it, else read from the desk.
    async fn word(&self, block: Option<&RegisterBlock>, address: u32) -> Result<u32, DeskError> {
        match block.and_then(|b| b.get(address)) {
            Some(value) => Ok(value),
            None => self.read(address).await,
        }
    }

    fn user_block_sane(block: &RegisterBlock, base: u32) -> bool {
        let flags = block.get(base + user_offset::FLAGS);
        let night = block.get(base + user_offset::MIDDLE_OF_NIGHT_HOUR);
        let standing = block.get(base + user_offset::STANDING_HEIGHT);
        let sitting = block.get(base + user_offset::SITTING_HEIGHT);
        flags.is_some_and(|f| f != 0xDEAD_BEEF && f <= 0xFFFF)
            && night.is_some_and(|h| h <= 23)
            && standing.is_some_and(|h| h <= 2000)
            && sitting.is_some_and(|h| h <= 2000)
    }

    /// The three name fields of the current user's block: 20 bytes each, one burst apiece.
    async fn read_names(&mut self) -> Result<(), DeskError> {
        let Some(settings) = self.state.settings.clone() else {
            return Ok(());
        };
        let base = user_base(settings.user_index);
        let mut names = [None, None, None];
        for (slot, offset) in [
            user_offset::USER_NAME,
            user_offset::PRESET_NAME_ONE,
            user_offset::PRESET_NAME_TWO,
        ]
        .into_iter()
        .enumerate()
        {
            names[slot] = self.read_block(base + offset, 1).await?.name(base + offset);
        }
        self.names_read = true;
        let [user_name, preset_name_one, preset_name_two] = names;
        tracing::info!(?user_name, ?preset_name_one, ?preset_name_two, "names");
        self.publish(|s| {
            if let Some(settings) = s.settings.as_mut() {
                settings.user_name = user_name;
                settings.preset_name_one = preset_name_one;
                settings.preset_name_two = preset_name_two;
            }
        });
        Ok(())
    }

    /// Settings are independent of flags and slot selection: the phone edits slot 1 in
    /// place and can change presets, timing or the day boundary without changing either.
    /// Reuse the block reader and its fallback, then publish a complete settings snapshot.
    async fn poll_settings(&mut self) -> Result<(), DeskError> {
        self.refresh_settings().await?;
        if !self.names_read {
            self.read_names().await?;
        }
        Ok(())
    }

    /// Experiment, run once a second around a predicted move: reads the registers whose
    /// meaning is still unknown and logs any that change.
    async fn poll_probe(&mut self) -> Result<(), DeskError> {
        let Some(settings) = self.state.settings.as_ref() else {
            return Ok(());
        };
        let base = user_base(settings.user_index);
        let mut changes = Vec::new();
        for address in [48, 72, 76, 228, base + 32, base + 36, base + 40] {
            let value = self.read(address).await?;
            if self.probe_values.get(&address) != Some(&value) {
                changes.push(format!("{address}={value:#x}"));
                self.probe_values.insert(address, value);
            }
        }
        if !changes.is_empty() {
            tracing::info!(changes = changes.join(" "), "probe");
        }
        Ok(())
    }

    fn recompute_today(&mut self) {
        let Some(settings) = self.state.settings.clone() else {
            return;
        };
        let result = self.session.recompute(
            self.now(),
            &settings,
            self.state.height_tenths,
            self.state.is_moving,
        );
        let live = self.session.live_countdown();
        if live != self.saved_countdown {
            if let Some(store) = &self.move_store {
                store.save_countdown(live.as_ref());
            }
            self.saved_countdown = live;
        }
        self.publish(|s| {
            s.today = Some(result.today);
            if result.history_changed {
                s.history_revision += 1;
            }
        });
    }

    // MARK: Writes

    async fn write_register(&mut self, address: u32, value: u32) -> Result<(), DeskError> {
        if address == addr::BOOTLOADER_MAGIC {
            return Err(DeskError::ForbiddenAddress(address));
        }
        if !self.connected {
            return Err(DeskError::NotConnected);
        }
        self.transport.write_register(address, value).await
    }

    /// The desk stores its current height into the preset; the written value is ignored.
    async fn capture_preset(&mut self, offset: u32) -> Result<(), DeskError> {
        if !self.connected {
            return Err(DeskError::NotConnected);
        }
        // The desk stores whatever height it is at *when the write lands*, so the guards
        // run against a fresh reading, not whatever the 1 Hz poll last saw.
        self.poll_status().await?;
        let (Some(settings), Some(height)) =
            (self.state.settings.clone(), self.state.height_tenths)
        else {
            return Err(DeskError::NotConnected);
        };
        if self.state.is_moving {
            return Err(DeskError::InvalidValue("desk is moving".into()));
        }
        // The motion bit can clear before the desk has stopped travelling, so `!is_moving`
        // alone isn't proof the height is final.
        let tracker = self.session.tracker();
        if tracker.has_pending_settle() || tracker.is_settling(self.wall()) {
            return Err(DeskError::InvalidValue("desk is still settling".into()));
        }
        self.write_register(user_base(settings.user_index) + offset, u32::from(height))
            .await?;
        self.refresh_settings().await?;
        let stored = self.state.settings.as_ref().map(|s| match offset {
            user_offset::SITTING_HEIGHT => s.sitting_height_tenths,
            user_offset::CUSTOM_HEIGHT_ONE => s.custom_height_one_tenths,
            user_offset::CUSTOM_HEIGHT_TWO => s.custom_height_two_tenths,
            _ => s.standing_height_tenths,
        });
        match stored {
            Some(stored) if stored.abs_diff(height) <= 3 => {}
            stored => {
                return Err(DeskError::InvalidValue(format!(
                    "The desk stored {} instead of {}. Move the desk to the height you want and try again.",
                    tempo_core::format::height(stored),
                    tempo_core::format::height(Some(height))
                )))
            }
        }
        self.recompute_today();
        Ok(())
    }

    async fn set_cruise(&mut self, slot: Option<CruiseSlot>) -> Result<(), DeskError> {
        let Some(settings) = self.state.settings.clone() else {
            return Err(DeskError::NotConnected);
        };
        let base = user_base(settings.user_index);
        match slot {
            Some(slot) => {
                if slot.standing_seconds == 0 || slot.sitting_seconds == 0 {
                    return Err(DeskError::InvalidValue(
                        "cruise timing must be positive".into(),
                    ));
                }
                self.write_register(cruise_slot_address(settings.user_index, 1), slot.raw())
                    .await?;
                self.write_register(base + user_offset::ACTIVE_CRUISE_SLOT, 1)
                    .await?;
            }
            None => {
                self.write_register(base + user_offset::ACTIVE_CRUISE_SLOT, 0)
                    .await?
            }
        }
        self.refresh_settings().await?;
        self.recompute_today();
        Ok(())
    }

    /// One bit of the user flags (pause, pulse-only), the rest as they are.
    async fn set_flag(&mut self, flag: UserFlags, on: bool) -> Result<(), DeskError> {
        let Some(settings) = self.state.settings.clone() else {
            return Err(DeskError::NotConnected);
        };
        let flags = UserFlags(settings.flags).set(flag, on);
        self.write_register(user_base(settings.user_index) + user_offset::FLAGS, flags.0)
            .await?;
        self.refresh_settings().await?;
        self.recompute_today();
        Ok(())
    }

    async fn set_user(&mut self, index: u8) -> Result<(), DeskError> {
        if index > 1 {
            return Err(DeskError::InvalidValue(
                "The desk has users 0 and 1.".into(),
            ));
        }
        self.write_register(addr::CURRENT_USER, u32::from(index))
            .await?;
        self.refresh_settings().await?;
        if !self.names_read {
            self.read_names().await?;
        }
        self.recompute_today();
        Ok(())
    }

    /// A 20-byte name field of the current user's block, written in one burst.
    async fn set_name(&mut self, offset: u32, name: &str) -> Result<(), DeskError> {
        let Some(settings) = self.state.settings.clone() else {
            return Err(DeskError::NotConnected);
        };
        if !self.connected {
            return Err(DeskError::NotConnected);
        }
        if name.trim().is_empty() {
            return Err(DeskError::InvalidValue("The name is empty.".into()));
        }
        let bytes = encode_name(name);
        debug_assert_eq!(bytes.len(), NAME_LENGTH);
        self.transport
            .burst_write(user_base(settings.user_index) + offset, &bytes)
            .await?;
        self.read_names().await
    }

    async fn sync_clock(&mut self) -> Result<(), DeskError> {
        let local = self.now().to_zoned(self.cfg.session.tz.clone());
        self.write_register(addr::CLOCK, DeskClock::from_time(local.time()).raw())
            .await
    }
}

#[cfg(test)]
#[path = "desk_tests.rs"]
mod tests;
