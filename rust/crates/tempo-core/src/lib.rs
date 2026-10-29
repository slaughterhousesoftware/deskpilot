//! Ergodriven Tempo desk: the protocol, the history engine and the file stores.
//!
//! Everything in this crate is pure and synchronous. Time is always passed in, never read
//! from the system, so every piece can be tested deterministically. The async service that
//! drives a transport lives in `tempo-desk`; Bluetooth lives in `tempo-ble`.
//!
//! The protocol reference is `docs/protocol.md` at the repository root. Nothing about the
//! desk is documented by Ergodriven; every rule here was observed in the field and most
//! constants carry the date and the measurement that produced them.

pub mod clock;
pub mod coast;
pub mod cruise;
pub mod format;
pub mod history;
pub mod merge;
pub mod model;
pub mod motion;
pub mod registers;
pub mod rollup;
pub mod session;
pub mod store;
pub mod summary;
pub mod time;
pub mod timeline;

pub use jiff::{SignedDuration, Timestamp};
