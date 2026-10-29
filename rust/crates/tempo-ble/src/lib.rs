//! The desk over Bluetooth Low Energy, through `btleplug`: CoreBluetooth on macOS, BlueZ
//! on Linux, WinRT on Windows. The desk must already be bonded at the OS level (hold its
//! UP button four seconds, pair, enter the six-digit code); every characteristic returns
//! "insufficient encryption" otherwise.
//!
//! Connecting is arranged to be as quick as the radio allows:
//!
//! * The desk's identifier is remembered between runs. A connect first asks the OS for
//!   that peripheral (`retrieve_peripherals`: on macOS the system keeps bonded devices on
//!   file) and for any already-connected peripheral with the desk's service, and connects
//!   straight to it. No scan, no advertising interval to wait out.
//! * Only without one does it scan, and then it reacts to the discovery event rather than
//!   polling the adapter's list every quarter second.
//! * The `alert` characteristic is subscribed and logged. The phone app never uses it and
//!   it has never been seen to notify, but if the desk says anything there - a paddle
//!   press, a cancelled countdown - the log will show it.

use std::collections::HashMap;
use std::path::PathBuf;
use std::pin::Pin;
use std::time::Duration;

use async_trait::async_trait;
use btleplug::api::{
    Central, CentralEvent, CentralState, Characteristic, Manager as _, Peripheral as _,
    RetrievePeripheralsOptions, ScanFilter, ValueNotification, WriteType,
};
use btleplug::platform::{Adapter, Manager, Peripheral, PeripheralId};
use futures::{FutureExt, Stream, StreamExt};
use tempo_desk::{ConnectionEvent, DeskError, EventSender, Transport};
use tokio::sync::Mutex;
use tokio::task::JoinHandle;
use uuid::{uuid, Uuid};

pub const SERVICE_UUID: Uuid = uuid!("da582000-796b-40fd-aeab-b06c95c30a5e");
const ADDR_UUID: Uuid = uuid!("da582001-796b-40fd-aeab-b06c95c30a5e");
const DATA_UUID: Uuid = uuid!("da582002-796b-40fd-aeab-b06c95c30a5e");
const ALERT_UUID: Uuid = uuid!("da582003-796b-40fd-aeab-b06c95c30a5e");
const BURST_ADDR_UUID: Uuid = uuid!("da582010-796b-40fd-aeab-b06c95c30a5e");
const BURST_LEN_UUID: Uuid = uuid!("da582011-796b-40fd-aeab-b06c95c30a5e");
const BURST_DATA_UUID: Uuid = uuid!("da582012-796b-40fd-aeab-b06c95c30a5e");
/// The characteristics the desk must have; `alert` is optional.
const REQUIRED_CHARACTERISTICS: [Uuid; 5] = [
    ADDR_UUID,
    DATA_UUID,
    BURST_ADDR_UUID,
    BURST_LEN_UUID,
    BURST_DATA_UUID,
];

#[derive(Clone, Debug)]
pub struct BleConfig {
    /// Per read or write. The desk answers in tens of milliseconds when it answers at all.
    pub operation_timeout: Duration,
    /// For a peripheral found by scanning.
    pub connect_timeout: Duration,
    /// For a remembered peripheral: the OS connects to a bonded device as soon as it
    /// advertises, so this is mostly how long to wait for a desk that is out of range before
    /// falling back to a scan.
    pub known_connect_timeout: Duration,
    pub scan_timeout: Duration,
    /// Extra burst time per 20-byte chunk on top of `operation_timeout`.
    pub per_chunk_timeout: Duration,
    /// Where the desk's identifier is kept between runs; `None` scans every time.
    pub remembered_peripheral: Option<PathBuf>,
}

impl Default for BleConfig {
    fn default() -> Self {
        Self {
            operation_timeout: Duration::from_secs(3),
            connect_timeout: Duration::from_secs(20),
            known_connect_timeout: Duration::from_secs(8),
            scan_timeout: Duration::from_secs(15),
            per_chunk_timeout: Duration::from_millis(500),
            remembered_peripheral: None,
        }
    }
}

type Notifications = Pin<Box<dyn Stream<Item = ValueNotification> + Send>>;

#[derive(Default)]
struct Inner {
    adapter: Option<Adapter>,
    peripheral: Option<Peripheral>,
    characteristics: HashMap<Uuid, Characteristic>,
    notifications: Option<Notifications>,
    watcher: Option<JoinHandle<()>>,
    /// The register address last written to `addr`, when it is certainly still selected.
    selected: Option<u32>,
}

/// All GATT traffic is serialised through one async mutex: the desk has a single shared
/// address pointer and interleaved reads return the wrong register.
pub struct BleTransport {
    cfg: BleConfig,
    events: EventSender,
    inner: Mutex<Inner>,
}

impl Default for BleTransport {
    fn default() -> Self {
        Self::new(BleConfig::default())
    }
}

impl BleTransport {
    pub fn new(cfg: BleConfig) -> Self {
        Self {
            cfg,
            events: EventSender::new(),
            inner: Mutex::new(Inner::default()),
        }
    }

    fn map(error: btleplug::Error) -> DeskError {
        use btleplug::Error as E;
        match error {
            E::PermissionDenied => DeskError::Unauthorized,
            E::TimedOut(_) => DeskError::Timeout("operation".into()),
            E::NotConnected => DeskError::NotConnected,
            E::DeviceNotFound => DeskError::Timeout("scan".into()),
            E::NotSupported(what) => DeskError::BluetoothUnavailable(what),
            other => DeskError::Gatt(other.to_string()),
        }
    }

    async fn adapter(inner: &mut Inner) -> Result<Adapter, DeskError> {
        if let Some(adapter) = &inner.adapter {
            return Ok(adapter.clone());
        }
        let manager = Manager::new().await.map_err(Self::map)?;
        let adapter = manager
            .adapters()
            .await
            .map_err(Self::map)?
            .into_iter()
            .next()
            .ok_or_else(|| DeskError::BluetoothUnavailable("no Bluetooth adapter".into()))?;
        inner.adapter = Some(adapter.clone());
        Ok(adapter)
    }

    // MARK: Remembering the desk

    fn remembered(&self) -> Option<PeripheralId> {
        let path = self.cfg.remembered_peripheral.as_ref()?;
        let text = std::fs::read_to_string(path).ok()?;
        let uuid: Uuid = text.trim().parse().ok()?;
        Some(PeripheralId::from(uuid))
    }

    fn remember(&self, id: &PeripheralId) {
        let Some(path) = &self.cfg.remembered_peripheral else {
            return;
        };
        if self.remembered().as_ref() == Some(id) {
            return;
        }
        if let Err(error) = std::fs::write(path, format!("{id}\n")) {
            tracing::debug!(%error, "could not remember the desk");
        }
    }

    fn forget_remembered(&self) {
        if let Some(path) = &self.cfg.remembered_peripheral {
            let _ = std::fs::remove_file(path);
        }
    }

    /// The remembered desk, or any peripheral the OS already has connected with the desk's
    /// service (the phone app's bond on this computer, say), without scanning.
    async fn known_peripheral(&self, adapter: &Adapter) -> Option<Peripheral> {
        let remembered = self.remembered();
        let options = RetrievePeripheralsOptions {
            identifiers: remembered.clone().map(|id| vec![id]),
            services: Some(vec![SERVICE_UUID]),
        };
        let found = match adapter.retrieve_peripherals(options).await {
            Ok(found) => found,
            Err(error) => {
                tracing::debug!(%error, "retrieve_peripherals");
                return None;
            }
        };
        // Prefer the one we remember; any other candidate must at least carry the service.
        if let Some(id) = &remembered {
            if let Some(p) = found.iter().find(|p| p.id() == *id) {
                return Some(p.clone());
            }
        }
        for p in found {
            if p.services().iter().any(|s| s.uuid == SERVICE_UUID) {
                return Some(p);
            }
        }
        None
    }

    /// Whether `peripheral` is (or advertises as) the desk.
    async fn is_desk(peripheral: &Peripheral) -> bool {
        if peripheral.services().iter().any(|s| s.uuid == SERVICE_UUID) {
            return true;
        }
        peripheral
            .properties()
            .await
            .ok()
            .flatten()
            .is_some_and(|p| p.services.contains(&SERVICE_UUID))
    }

    /// Scans for the desk, returning the moment it is discovered.
    async fn scan_for_peripheral(&self, adapter: &Adapter) -> Result<Peripheral, DeskError> {
        let deadline = tokio::time::Instant::now() + self.cfg.scan_timeout;
        // Subscribe before scanning so no discovery slips between the two.
        let mut events = adapter.events().await.map_err(Self::map)?;
        adapter
            .start_scan(ScanFilter {
                services: vec![SERVICE_UUID],
            })
            .await
            .map_err(Self::map)?;
        let result = async {
            // Anything the adapter already knows about comes first.
            for peripheral in adapter.peripherals().await.map_err(Self::map)? {
                if Self::is_desk(&peripheral).await {
                    return Ok(peripheral);
                }
            }
            while let Some(event) = events.next().await {
                let id = match event {
                    CentralEvent::DeviceDiscovered(id)
                    | CentralEvent::DeviceUpdated(id)
                    | CentralEvent::ServicesAdvertisement { id, .. } => id,
                    CentralEvent::StateUpdate(CentralState::PoweredOff) => {
                        return Err(DeskError::BluetoothOff);
                    }
                    _ => continue,
                };
                if let Ok(peripheral) = adapter.peripheral(&id).await {
                    if Self::is_desk(&peripheral).await {
                        return Ok(peripheral);
                    }
                }
            }
            Err(DeskError::Timeout("scan".into()))
        };
        let found = tokio::time::timeout_at(deadline, result)
            .await
            .unwrap_or_else(|_| Err(DeskError::Timeout("scan".into())));
        let _ = adapter.stop_scan().await;
        found
    }

    async fn connect_to(
        &self,
        peripheral: &Peripheral,
        timeout: Duration,
    ) -> Result<(), DeskError> {
        tokio::time::timeout(timeout, peripheral.connect())
            .await
            .map_err(|_| DeskError::Timeout("connect".into()))?
            .map_err(Self::map)
    }

    /// Finds and connects to the desk: the remembered one directly, else by scanning.
    async fn find_and_connect(&self, adapter: &Adapter) -> Result<Peripheral, DeskError> {
        let started = tokio::time::Instant::now();
        if let Some(peripheral) = self.known_peripheral(adapter).await {
            match self
                .connect_to(&peripheral, self.cfg.known_connect_timeout)
                .await
            {
                Ok(()) => {
                    tracing::info!(
                        ms = started.elapsed().as_millis(),
                        "connected to the remembered desk"
                    );
                    return Ok(peripheral);
                }
                Err(error) => {
                    // Otherwise every retry burns the same wait on the same bad identifier
                    // before it ever scans.
                    tracing::info!(%error, "remembered desk did not connect; scanning");
                    self.forget_remembered();
                }
            }
        }
        let peripheral = self.scan_for_peripheral(adapter).await?;
        tracing::info!(ms = started.elapsed().as_millis(), "desk found; connecting");
        self.connect_to(&peripheral, self.cfg.connect_timeout)
            .await?;
        tracing::info!(ms = started.elapsed().as_millis(), "connected");
        Ok(peripheral)
    }

    // MARK: GATT

    /// The peripheral and characteristic to use, cloned out of the lock so no shared
    /// reference to the (non-`Sync`) notification stream is held across an await.
    fn target(inner: &Inner, uuid: Uuid) -> Result<(Peripheral, Characteristic), DeskError> {
        let peripheral = inner.peripheral.as_ref().ok_or(DeskError::NotConnected)?;
        let characteristic = inner
            .characteristics
            .get(&uuid)
            .ok_or(DeskError::NotConnected)?;
        Ok((peripheral.clone(), characteristic.clone()))
    }

    async fn write_char(
        &self,
        target: (Peripheral, Characteristic),
        data: &[u8],
    ) -> Result<(), DeskError> {
        let (peripheral, characteristic) = target;
        tokio::time::timeout(
            self.cfg.operation_timeout,
            peripheral.write(&characteristic, data, WriteType::WithResponse),
        )
        .await
        .map_err(|_| DeskError::Timeout(format!("write {}", characteristic.uuid)))?
        .map_err(Self::map)
    }

    async fn read_char(&self, target: (Peripheral, Characteristic)) -> Result<Vec<u8>, DeskError> {
        let (peripheral, characteristic) = target;
        tokio::time::timeout(self.cfg.operation_timeout, peripheral.read(&characteristic))
            .await
            .map_err(|_| DeskError::Timeout(format!("read {}", characteristic.uuid)))?
            .map_err(Self::map)
    }

    /// Selects `address` on the desk's register pointer. Always written, even when it is
    /// already selected: the desk latches the value when the address is written, so a bare
    /// `data` read returns the value from the last write, not the register now (tried on
    /// 2026-10-29: the height stood still for seconds after a paddle move, until the next
    /// history poll rewrote the pointer).
    async fn select(&self, inner: &mut Inner, address: u32) -> Result<(), DeskError> {
        inner.selected = None;
        self.write_char(Self::target(inner, ADDR_UUID)?, &address.to_le_bytes())
            .await?;
        inner.selected = Some(address);
        Ok(())
    }

    /// Logs anything the desk pushed that isn't burst data: the `alert` characteristic, or
    /// a chunk left over from a burst that timed out.
    fn note_stray(notification: &ValueNotification) {
        if notification.uuid == ALERT_UUID {
            tracing::info!(value = ?notification.value, "alert notification");
        } else if notification.uuid != BURST_DATA_UUID {
            tracing::debug!(uuid = %notification.uuid, value = ?notification.value, "notification");
        }
    }

    fn clear(inner: &mut Inner) {
        inner.peripheral = None;
        inner.characteristics.clear();
        inner.notifications = None;
        inner.selected = None;
        if let Some(watcher) = inner.watcher.take() {
            watcher.abort();
        }
    }
}

#[async_trait]
impl Transport for BleTransport {
    fn events(&self) -> tempo_desk::transport::EventStream {
        self.events.stream()
    }

    async fn connect(&self) -> Result<(), DeskError> {
        let mut inner = self.inner.lock().await;
        Self::clear(&mut inner);
        let adapter = Self::adapter(&mut inner).await?;
        match adapter.adapter_state().await {
            Ok(CentralState::PoweredOff) => {
                self.events.emit(ConnectionEvent::BluetoothOff);
                return Err(DeskError::BluetoothOff);
            }
            Ok(_) => {}
            Err(btleplug::Error::PermissionDenied) => {
                self.events.emit(ConnectionEvent::Unauthorized);
                return Err(DeskError::Unauthorized);
            }
            Err(e) => tracing::debug!(error = %e, "adapter state unavailable"),
        }
        self.events.emit(ConnectionEvent::Connecting);
        let peripheral = self.find_and_connect(&adapter).await?;
        if let Err(e) = peripheral.discover_services().await {
            let _ = peripheral.disconnect().await;
            return Err(Self::map(e));
        }
        // Discovery already reads the full table. Keep its UUIDs/properties in diagnostics
        // so protocol investigations do not need a competing Bluetooth client.
        tracing::info!(services = ?peripheral.services(), "discovered GATT inventory");
        let mut characteristics = HashMap::new();
        for c in peripheral.characteristics() {
            if REQUIRED_CHARACTERISTICS.contains(&c.uuid) || c.uuid == ALERT_UUID {
                characteristics.insert(c.uuid, c);
            }
        }
        if REQUIRED_CHARACTERISTICS
            .iter()
            .any(|uuid| !characteristics.contains_key(uuid))
        {
            let _ = peripheral.disconnect().await;
            return Err(DeskError::Gatt(format!(
                "found {} of {} characteristics",
                characteristics.len(),
                REQUIRED_CHARACTERISTICS.len()
            )));
        }
        let notifications = peripheral.notifications().await.map_err(Self::map)?;
        peripheral
            .subscribe(&characteristics[&BURST_DATA_UUID])
            .await
            .map_err(Self::map)?;
        if let Some(alert) = characteristics.get(&ALERT_UUID) {
            // Best effort: the desk works without it.
            if let Err(error) = peripheral.subscribe(alert).await {
                tracing::debug!(%error, "alert not subscribed");
            }
        }
        self.remember(&peripheral.id());

        // Watch for the link dropping underneath us.
        let id = peripheral.id();
        let events = self.events.clone();
        let mut central_events = adapter.events().await.map_err(Self::map)?;
        let watcher = tokio::spawn(async move {
            while let Some(event) = central_events.next().await {
                match event {
                    CentralEvent::DeviceDisconnected(gone) if gone == id => {
                        events.emit(ConnectionEvent::Disconnected {
                            reason: Some("The desk disconnected.".into()),
                        });
                        return;
                    }
                    CentralEvent::StateUpdate(CentralState::PoweredOff) => {
                        events.emit(ConnectionEvent::BluetoothOff);
                        return;
                    }
                    _ => {}
                }
            }
        });
        inner.peripheral = Some(peripheral);
        inner.characteristics = characteristics;
        inner.notifications = Some(notifications);
        inner.watcher = Some(watcher);
        inner.selected = None;
        self.events.emit(ConnectionEvent::Connected);
        Ok(())
    }

    async fn disconnect(&self) {
        let mut inner = self.inner.lock().await;
        if let Some(peripheral) = inner.peripheral.take() {
            let _ = tokio::time::timeout(self.cfg.operation_timeout, peripheral.disconnect()).await;
        }
        Self::clear(&mut inner);
        self.events.emit(ConnectionEvent::Disconnected {
            reason: Some("requested".into()),
        });
    }

    async fn read_register(&self, address: u32) -> Result<u32, DeskError> {
        let mut inner = self.inner.lock().await;
        self.select(&mut inner, address).await?;
        let data = match self.read_char(Self::target(&inner, DATA_UUID)?).await {
            Ok(data) => data,
            Err(error) => {
                // After a failed read nothing about the pointer is certain.
                inner.selected = None;
                return Err(error);
            }
        };
        data.get(..4)
            .map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
            .ok_or_else(|| DeskError::Gatt(format!("short read at {address}")))
    }

    async fn write_register(&self, address: u32, value: u32) -> Result<(), DeskError> {
        let mut inner = self.inner.lock().await;
        // Always reselect for a write: a stale pointer would put the value somewhere else.
        inner.selected = None;
        self.select(&mut inner, address).await?;
        let written = self
            .write_char(Self::target(&inner, DATA_UUID)?, &value.to_le_bytes())
            .await;
        if written.is_err() {
            inner.selected = None;
        }
        written
    }

    async fn burst_read(&self, byte_address: u32, chunks: usize) -> Result<Vec<u8>, DeskError> {
        let mut inner = self.inner.lock().await;
        // Whether a burst disturbs the register pointer is unknown; assume it does.
        inner.selected = None;
        self.write_char(
            Self::target(&inner, BURST_ADDR_UUID)?,
            &byte_address.to_le_bytes(),
        )
        .await?;
        let expected = chunks * 20;
        let budget = self.cfg.operation_timeout + self.cfg.per_chunk_timeout * chunks as u32;
        // Chunks left over from a burst that timed out must not be mistaken for this one's.
        {
            let stream = inner
                .notifications
                .as_mut()
                .ok_or(DeskError::NotConnected)?;
            while let Some(Some(stray)) = stream.next().now_or_never() {
                Self::note_stray(&stray);
            }
        }
        // Writing the length triggers the stream.
        self.write_char(
            Self::target(&inner, BURST_LEN_UUID)?,
            &(chunks as u32).to_le_bytes(),
        )
        .await?;
        let stream = inner
            .notifications
            .as_mut()
            .ok_or(DeskError::NotConnected)?;
        let mut buffer = Vec::with_capacity(expected);
        let collect = async {
            while buffer.len() < expected {
                match stream.next().await {
                    Some(n) if n.uuid == BURST_DATA_UUID => buffer.extend_from_slice(&n.value),
                    Some(other) => Self::note_stray(&other),
                    None => break,
                }
            }
        };
        if tokio::time::timeout(budget, collect).await.is_err() {
            return Err(DeskError::Timeout("burst read".into()));
        }
        if buffer.len() < expected {
            return Err(DeskError::BurstIncomplete {
                expected,
                got: buffer.len(),
            });
        }
        Ok(buffer)
    }

    async fn burst_write(&self, byte_address: u32, data: &[u8]) -> Result<(), DeskError> {
        let mut inner = self.inner.lock().await;
        inner.selected = None;
        self.write_char(
            Self::target(&inner, BURST_ADDR_UUID)?,
            &byte_address.to_le_bytes(),
        )
        .await?;
        self.write_char(
            Self::target(&inner, BURST_DATA_UUID)?,
            &data[..data.len().min(20)],
        )
        .await
    }
}
