//! Raw access to the desk, and the errors it can produce.

use std::pin::Pin;

use async_trait::async_trait;
use futures::Stream;
use thiserror::Error;
use tokio::sync::broadcast;

/// What can go wrong talking to the desk. `Display` is user-facing: the same sentences the
/// macOS app shows, so every front end reads alike.
#[derive(Clone, Debug, PartialEq, Eq, Error)]
pub enum DeskError {
    #[error("Not connected to the desk.")]
    NotConnected,
    /// The local Bluetooth radio is switched off.
    #[error("Bluetooth is turned off.")]
    BluetoothOff,
    /// The user denied this app Bluetooth access.
    #[error("Bluetooth access was denied.")]
    Unauthorized,
    /// Bluetooth is unusable for some other reason (e.g. no adapter).
    #[error("Bluetooth isn't available on this computer.")]
    BluetoothUnavailable(String),
    #[error("{}", timeout_text(.0))]
    Timeout(String),
    #[error("Lost contact with the desk. Try again.")]
    Gatt(String),
    #[error("That change isn't allowed: it could put the desk into update mode.")]
    ForbiddenAddress(u32),
    #[error("{}", invalid_value_text(.0))]
    InvalidValue(String),
    #[error("The desk sent an incomplete response. Try again.")]
    BurstIncomplete { expected: usize, got: usize },
}

/// The scan is the one timeout that means "never heard from it at all".
fn timeout_text(what: &str) -> String {
    if what == "scan" {
        "Couldn't find the desk. Is it on and in range?".into()
    } else {
        "The desk didn't answer in time.".into()
    }
}

/// `InvalidValue` carries a message from the throw site; the known internal ones get a
/// friendlier rewrite, and anything already written for a person passes through.
fn invalid_value_text(message: &str) -> String {
    match message {
        "desk is moving" => "The desk is moving; try again once it stops.".into(),
        "desk is still settling" => "The desk is still settling; try again in a moment.".into(),
        "cruise timing must be positive" => {
            "Standing and sitting times must both be greater than zero.".into()
        }
        other => other.into(),
    }
}

impl DeskError {
    /// Transient failures are retried once; steady states (not connected, radio off or
    /// denied, a refused write) are surfaced at once, because retrying only delays them.
    pub const fn is_transient(&self) -> bool {
        matches!(
            self,
            DeskError::Timeout(_) | DeskError::Gatt(_) | DeskError::BurstIncomplete { .. }
        )
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ConnectionEvent {
    Connecting,
    Connected,
    Disconnected { reason: Option<String> },
    BluetoothOff,
    Unauthorized,
}

pub type EventStream = Pin<Box<dyn Stream<Item = ConnectionEvent> + Send>>;

/// The event side of a transport: a broadcast channel each `events()` call subscribes to.
#[derive(Clone, Debug)]
pub struct EventSender(broadcast::Sender<ConnectionEvent>);

impl Default for EventSender {
    fn default() -> Self {
        Self::new()
    }
}

impl EventSender {
    pub fn new() -> Self {
        Self(broadcast::channel(16).0)
    }

    pub fn emit(&self, event: ConnectionEvent) {
        let _ = self.0.send(event);
    }

    pub fn stream(&self) -> EventStream {
        let rx = self.0.subscribe();
        Box::pin(futures::stream::unfold(rx, |mut rx| async move {
            loop {
                match rx.recv().await {
                    Ok(event) => return Some((event, rx)),
                    Err(broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(broadcast::error::RecvError::Closed) => return None,
                }
            }
        }))
    }
}

/// Raw access to the desk. Implementations must serialise calls: the desk has one shared
/// address pointer and interleaved reads return the wrong register.
#[async_trait]
pub trait Transport: Send + Sync + 'static {
    /// Connection lifecycle events.
    fn events(&self) -> EventStream;
    async fn connect(&self) -> Result<(), DeskError>;
    async fn disconnect(&self);
    async fn read_register(&self, address: u32) -> Result<u32, DeskError>;
    async fn write_register(&self, address: u32, value: u32) -> Result<(), DeskError>;
    /// Reads `chunks` consecutive 20-byte chunks starting at `byte_address`.
    async fn burst_read(&self, byte_address: u32, chunks: usize) -> Result<Vec<u8>, DeskError>;
    /// Writes up to 20 bytes at `byte_address`.
    async fn burst_write(&self, byte_address: u32, data: &[u8]) -> Result<(), DeskError>;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn errors_read_like_the_mac_app() {
        assert_eq!(
            DeskError::Timeout("scan".into()).to_string(),
            "Couldn't find the desk. Is it on and in range?"
        );
        assert_eq!(
            DeskError::Timeout("connect".into()).to_string(),
            "The desk didn't answer in time."
        );
        assert_eq!(
            DeskError::Gatt("boom".into()).to_string(),
            "Lost contact with the desk. Try again."
        );
        assert_eq!(
            DeskError::InvalidValue("desk is moving".into()).to_string(),
            "The desk is moving; try again once it stops."
        );
        assert_eq!(
            DeskError::InvalidValue("Custom text.".into()).to_string(),
            "Custom text."
        );
        assert_eq!(
            DeskError::ForbiddenAddress(16).to_string(),
            "That change isn't allowed: it could put the desk into update mode."
        );
        assert!(DeskError::Gatt(String::new()).is_transient());
        assert!(!DeskError::NotConnected.is_transient());
    }
}
