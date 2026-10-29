//! The Ergodriven Tempo desk service: a `Transport` to talk to the desk, the `Desk` task
//! that keeps a `DeskSession` current over it and publishes `DeskState`, a simulator for
//! working without the hardware, and the command-queue sender UIs use.

pub mod commands;
pub mod desk;
#[cfg(any(test, feature = "test-util"))]
pub mod fake;
pub mod sim;
pub mod transport;

pub use desk::{Desk, DeskConfig, DeskHandle};
pub use transport::{ConnectionEvent, DeskError, EventSender, Transport};
