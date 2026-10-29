//! An in-memory desk for tests. Registers live in a map; the history ring in a byte vector.

use std::collections::HashMap;
use std::sync::Mutex;

use async_trait::async_trait;
use tempo_core::registers::{addr, is_preset_address};

use crate::transport::{ConnectionEvent, DeskError, EventSender, EventStream, Transport};

#[derive(Default)]
struct Inner {
    registers: HashMap<u32, u32>,
    history: Vec<u8>,
    strings: HashMap<u32, Vec<u8>>,
    connect_error: Option<DeskError>,
    read_error: Option<DeskError>,
    fail_next_reads: usize,
    captures_presets: bool,
    writes: Vec<(u32, u32)>,
    burst_writes: Vec<(u32, Vec<u8>)>,
    connect_calls: usize,
    read_count: usize,
    read_counts: HashMap<u32, usize>,
}

pub struct FakeTransport {
    events: EventSender,
    inner: Mutex<Inner>,
}

impl Default for FakeTransport {
    fn default() -> Self {
        Self::new()
    }
}

impl FakeTransport {
    pub fn new() -> Self {
        Self {
            events: EventSender::new(),
            inner: Mutex::new(Inner {
                captures_presets: true,
                ..Default::default()
            }),
        }
    }

    fn with<T>(&self, f: impl FnOnce(&mut Inner) -> T) -> T {
        f(&mut self.inner.lock().unwrap())
    }

    pub fn emit(&self, event: ConnectionEvent) {
        self.events.emit(event);
    }

    pub fn set_register(&self, address: u32, value: u32) {
        self.with(|i| {
            i.registers.insert(address, value);
        });
    }

    pub fn register(&self, address: u32) -> Option<u32> {
        self.with(|i| i.registers.get(&address).copied())
    }

    pub fn set_registers(&self, pairs: impl IntoIterator<Item = (u32, u32)>) {
        self.with(|i| i.registers.extend(pairs));
    }

    /// Replaces the ring buffer and its write pointer atomically.
    pub fn set_history(&self, bytes: &[u8], minutes_since_power_on: Option<u32>) {
        self.with(|i| {
            i.history = bytes.to_vec();
            i.registers
                .insert(addr::HISTORY_WRITE_POINTER, bytes.len() as u32);
            if let Some(m) = minutes_since_power_on {
                i.registers.insert(addr::MINUTES_SINCE_POWER_ON, m);
            }
        });
    }

    pub fn append_history(&self, bytes: &[u8]) {
        self.with(|i| {
            i.history.extend_from_slice(bytes);
            i.registers
                .insert(addr::HISTORY_WRITE_POINTER, i.history.len() as u32);
        });
    }

    pub fn set_connect_error(&self, error: Option<DeskError>) {
        self.with(|i| i.connect_error = error);
    }

    pub fn set_read_error(&self, error: Option<DeskError>) {
        self.with(|i| i.read_error = error);
    }

    /// Upcoming reads (register or burst) that fail with a transient error first.
    pub fn fail_next_reads(&self, n: usize) {
        self.with(|i| i.fail_next_reads = n);
    }

    /// The real desk ignores the value written to a preset register and stores its
    /// *current* height instead. On by default.
    pub fn set_captures_presets(&self, on: bool) {
        self.with(|i| i.captures_presets = on);
    }

    pub fn writes(&self) -> Vec<(u32, u32)> {
        self.with(|i| i.writes.clone())
    }

    pub fn burst_writes(&self) -> Vec<(u32, Vec<u8>)> {
        self.with(|i| i.burst_writes.clone())
    }

    pub fn connect_calls(&self) -> usize {
        self.with(|i| i.connect_calls)
    }

    pub fn read_count(&self) -> usize {
        self.with(|i| i.read_count)
    }

    /// Reads per address: register reads keyed by register address, bursts by byte address.
    pub fn read_count_for(&self, address: u32) -> usize {
        self.with(|i| i.read_counts.get(&address).copied().unwrap_or(0))
    }
}

#[async_trait]
impl Transport for FakeTransport {
    fn events(&self) -> EventStream {
        self.events.stream()
    }

    async fn connect(&self) -> Result<(), DeskError> {
        // A real connect takes time; yielding lets observers see the "connecting" state.
        tokio::task::yield_now().await;
        let error = self.with(|i| {
            i.connect_calls += 1;
            i.connect_error.clone()
        });
        if let Some(e) = error {
            return Err(e);
        }
        self.emit(ConnectionEvent::Connected);
        Ok(())
    }

    async fn disconnect(&self) {
        tokio::task::yield_now().await;
        self.emit(ConnectionEvent::Disconnected {
            reason: Some("requested".into()),
        });
    }

    async fn read_register(&self, address: u32) -> Result<u32, DeskError> {
        self.with(|i| {
            i.read_count += 1;
            *i.read_counts.entry(address).or_default() += 1;
            if let Some(e) = &i.read_error {
                return Err(e.clone());
            }
            if i.fail_next_reads > 0 {
                i.fail_next_reads -= 1;
                return Err(DeskError::Gatt("flaky".into()));
            }
            if address >= addr::HISTORY_BASE {
                let off = (address - addr::HISTORY_BASE) as usize;
                return Ok(i.history.get(off..off + 4).map_or(0xDEAD_BEEF, |b| {
                    u32::from_le_bytes([b[0], b[1], b[2], b[3]])
                }));
            }
            Ok(i.registers.get(&address).copied().unwrap_or(0xDEAD_BEEF))
        })
    }

    async fn write_register(&self, address: u32, value: u32) -> Result<(), DeskError> {
        self.with(|i| {
            if i.captures_presets && is_preset_address(address) {
                let height = i.registers.get(&addr::STATUS).copied().unwrap_or(0) & 0xFFFF;
                i.registers.insert(address, height);
            } else {
                i.registers.insert(address, value);
            }
            i.writes.push((address, value));
        });
        Ok(())
    }

    async fn burst_read(&self, byte_address: u32, chunks: usize) -> Result<Vec<u8>, DeskError> {
        self.with(|i| {
            i.read_count += 1;
            *i.read_counts.entry(byte_address).or_default() += 1;
            if let Some(e) = &i.read_error {
                return Err(e.clone());
            }
            if i.fail_next_reads > 0 {
                i.fail_next_reads -= 1;
                return Err(DeskError::Gatt("flaky".into()));
            }
            // The real desk serves data from the address rounded down to a multiple of 4.
            let aligned = byte_address & !3;
            let n = chunks * 20;
            if aligned >= addr::HISTORY_BASE {
                let start = (aligned - addr::HISTORY_BASE) as usize;
                Ok((0..n)
                    .map(|k| i.history.get(start + k).copied().unwrap_or(0))
                    .collect())
            } else if let Some(s) = i.strings.get(&aligned) {
                let mut out = s.clone();
                out.resize(n.max(s.len()), 0);
                Ok(out)
            } else {
                // Registers are one flat address space: a burst over them serves each
                // word as the register at that address, unmapped ones as 0xDEADBEEF.
                Ok(crate::sim::register_block(&i.registers, aligned, n))
            }
        })
    }

    async fn burst_write(&self, byte_address: u32, data: &[u8]) -> Result<(), DeskError> {
        self.with(|i| {
            i.strings.insert(byte_address, data.to_vec());
            i.burst_writes.push((byte_address, data.to_vec()));
        });
        Ok(())
    }
}
