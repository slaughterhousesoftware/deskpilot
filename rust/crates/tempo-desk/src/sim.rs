//! A desk that lives in memory, for developing a UI without the real one: pick a scenario
//! and every reader sees a desk in that state. Registers and the history ring are laid out
//! exactly as the real desk's, so the `Desk` service runs unchanged on top of it.

use std::collections::HashMap;
use std::str::FromStr;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use tempo_core::registers::{addr, cruise_slot_address, user_base, user_offset};
use tempo_core::rollup::BEEP;
use tokio::task::JoinHandle;

use crate::transport::{ConnectionEvent, DeskError, EventSender, EventStream, Transport};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Scenario {
    /// Standing at the desk, next sit in about eleven minutes.
    Standing,
    /// Sitting at the desk, next stand in about eleven minutes.
    Sitting,
    /// Sitting, with the next stand due in about forty seconds: the countdown's end.
    Countdown,
    /// Sitting; two seconds after connecting the desk announces a stand (COUNTDOWN entry),
    /// beeps for fifteen seconds, then rises.
    Beeping,
    /// A realistic working day so far: irregular spells, minute-long slivers, breaks of a
    /// few minutes and of an hour, over eleven hours.
    BusyDay,
    /// The desk sees nobody.
    Away,
    /// The desk is rising from sitting to standing height over about twelve seconds, and
    /// keeps going up and down every twenty seconds.
    Moving,
    /// Cruise control paused.
    Paused,
    /// Cruise control turned off on the desk.
    CruiseOff,
    /// Connecting forever.
    Connecting,
    /// Every connection attempt fails: out of reach.
    OutOfReach,
    /// Bluetooth is switched off.
    BluetoothOff,
    /// Bluetooth access was denied.
    Unauthorized,
}

impl Scenario {
    pub const ALL: [Scenario; 13] = [
        Scenario::Standing,
        Scenario::Sitting,
        Scenario::Countdown,
        Scenario::Beeping,
        Scenario::BusyDay,
        Scenario::Away,
        Scenario::Moving,
        Scenario::Paused,
        Scenario::CruiseOff,
        Scenario::Connecting,
        Scenario::OutOfReach,
        Scenario::BluetoothOff,
        Scenario::Unauthorized,
    ];

    pub const fn name(self) -> &'static str {
        match self {
            Scenario::Standing => "standing",
            Scenario::Sitting => "sitting",
            Scenario::Countdown => "countdown",
            Scenario::Beeping => "beeping",
            Scenario::BusyDay => "busy-day",
            Scenario::Away => "away",
            Scenario::Moving => "moving",
            Scenario::Paused => "paused",
            Scenario::CruiseOff => "cruise-off",
            Scenario::Connecting => "connecting",
            Scenario::OutOfReach => "out-of-reach",
            Scenario::BluetoothOff => "bluetooth-off",
            Scenario::Unauthorized => "unauthorized",
        }
    }

    /// `DESKPILOT_SIMULATE` from the environment, if it names a scenario.
    pub fn from_env() -> Option<Scenario> {
        std::env::var("DESKPILOT_SIMULATE").ok()?.parse().ok()
    }
}

impl FromStr for Scenario {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let wanted = s.trim().to_lowercase().replace('_', "-");
        Scenario::ALL
            .iter()
            .copied()
            .find(|sc| sc.name() == wanted || sc.name().replace('-', "") == wanted)
            .ok_or_else(|| {
                format!(
                    "unknown scenario {s:?}; one of {}",
                    Scenario::ALL
                        .iter()
                        .map(|s| s.name())
                        .collect::<Vec<_>>()
                        .join(", ")
                )
            })
    }
}

impl std::fmt::Display for Scenario {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.name())
    }
}

#[derive(Default)]
struct State {
    registers: HashMap<u32, u32>,
    history: Vec<u8>,
    strings: HashMap<u32, Vec<u8>>,
}

impl State {
    fn set_history_len(&mut self) {
        self.registers
            .insert(addr::HISTORY_WRITE_POINTER, self.history.len() as u32);
    }
}

pub struct SimulatedTransport {
    scenario: Scenario,
    events: EventSender,
    state: Arc<Mutex<State>>,
    motion: Mutex<Option<JoinHandle<()>>>,
}

const SITTING_TENTHS: u32 = 266;
const STANDING_TENTHS: u32 = 372;
/// The desk's clock, in minutes since it was powered on, at the moment the app connects.
const MINUTES_NOW: u32 = 5883;

const fn presence(present: bool) -> u8 {
    if present {
        0b0101_0001
    } else {
        0b0101_0000
    }
}
const fn mv(up: bool) -> u8 {
    if up {
        0b0101_1101
    } else {
        0b0101_1100
    }
}
const fn countdown(up: bool) -> u8 {
    if up {
        0b0101_1001
    } else {
        0b0101_1000
    }
}

impl SimulatedTransport {
    pub fn new(scenario: Scenario) -> Self {
        let t = Self {
            scenario,
            events: EventSender::new(),
            state: Arc::new(Mutex::new(State::default())),
            motion: Mutex::new(None),
        };
        t.seed();
        t
    }

    pub const fn scenario(&self) -> Scenario {
        self.scenario
    }

    fn seed(&self) {
        let s = self.scenario;
        let user = user_base(0);
        let mut flags: u32 = 0x1E3;
        if s == Scenario::Paused {
            flags |= 0x4;
        }
        let standing = matches!(s, Scenario::Standing | Scenario::Moving);
        let present = s != Scenario::Away;
        let height = if s == Scenario::Moving || !standing {
            SITTING_TENTHS
        } else {
            STANDING_TENTHS
        };
        let mut st = State::default();
        st.registers.extend([
            (addr::FIRMWARE_APPLICATION, 0x0001_0005),
            (addr::MINUTES_SINCE_POWER_ON, MINUTES_NOW),
            (addr::HISTORY_SIZE, 8192),
            (addr::CURRENT_USER, 0),
            (addr::STATUS, if present { 0x100 } else { 0 } | height),
            (user + user_offset::FLAGS, flags),
            (
                user + user_offset::ACTIVE_CRUISE_SLOT,
                if s == Scenario::CruiseOff { 0 } else { 1 },
            ),
            (user + user_offset::COUNTDOWN_AND_PULSE, 0x0008_000F),
            (user + user_offset::MIDDLE_OF_NIGHT_HOUR, 4),
            (user + user_offset::STANDING_HEIGHT, STANDING_TENTHS),
            (user + user_offset::SITTING_HEIGHT, SITTING_TENTHS),
            (user + user_offset::CUSTOM_HEIGHT_ONE, 0),
            (user + user_offset::CUSTOM_HEIGHT_TWO, 0),
            (user + user_offset::MOVE_COUNT, 7),
            (cruise_slot_address(0, 1), 0x04B0_04B0),
        ]);
        let mut log: Vec<u8> = Vec::new();
        let entry = |log: &mut Vec<u8>, minutes_ago: i64, kind: u8| {
            log.push(((i64::from(MINUTES_NOW) - minutes_ago).rem_euclid(256)) as u8);
            log.push(kind);
        };
        // A morning at the desk: arrived 2 h ago, alternated every 20 min, and the last
        // move sets the countdown.
        entry(&mut log, 120, presence(true));
        let mut to_standing = true;
        let mut minutes_ago = 110;
        while minutes_ago > 9 {
            entry(&mut log, minutes_ago + 1, countdown(to_standing));
            entry(&mut log, minutes_ago, mv(to_standing));
            to_standing = !to_standing;
            minutes_ago -= 20;
        }
        let last_to_standing = !to_standing;
        if last_to_standing != standing {
            entry(&mut log, 9, mv(standing));
        }
        match s {
            Scenario::BusyDay => {
                log.clear();
                // (minutes, kind): 's' sitting, 'S' standing, 'b' break, oldest first, ending now.
                let day: [(i64, char); 31] = [
                    (41, 's'),
                    (20, 'S'),
                    (30, 's'),
                    (20, 'S'),
                    (33, 's'),
                    (10, 'b'),
                    (27, 's'),
                    (20, 'S'),
                    (5, 's'),
                    (2, 'S'),
                    (31, 's'),
                    (20, 'S'),
                    (65, 'b'),
                    (30, 's'),
                    (20, 'S'),
                    (28, 's'),
                    (3, 'b'),
                    (12, 's'),
                    (1, 'S'),
                    (30, 's'),
                    (20, 'S'),
                    (4, 'b'),
                    (1, 's'),
                    (1, 'S'),
                    (33, 's'),
                    (20, 'S'),
                    (28, 's'),
                    (95, 'b'),
                    (21, 's'),
                    (20, 'S'),
                    (14, 's'),
                ];
                let mut minutes_ago: i64 = day.iter().map(|d| d.0).sum();
                entry(&mut log, minutes_ago, presence(true));
                let mut previous = 's';
                for (length, kind) in day {
                    if kind == 'b' {
                        entry(&mut log, minutes_ago, presence(false));
                    } else {
                        if previous == 'b' {
                            entry(&mut log, minutes_ago, presence(true));
                        }
                        entry(&mut log, minutes_ago, mv(kind == 'S'));
                    }
                    previous = kind;
                    minutes_ago -= length;
                }
            }
            Scenario::Countdown | Scenario::Beeping => {
                // Sat down 19 minutes ago: the next stand is due in about a minute.
                log.clear();
                entry(&mut log, 120, presence(true));
                entry(&mut log, 19, mv(false));
            }
            Scenario::Away => entry(&mut log, 3, presence(false)),
            _ => {}
        }
        st.history = log;
        st.set_history_len();
        *self.state.lock().unwrap() = st;
    }

    fn set_motion(&self, task: Option<JoinHandle<()>>) {
        let mut slot = self.motion.lock().unwrap();
        if let Some(old) = slot.take() {
            old.abort();
        }
        *slot = task;
    }

    /// The real sequence of an automatic stand, on the real timings: the COUNTDOWN entry
    /// lands in the log, and `BEEP` later the desk rises.
    fn start_beeping(&self) {
        let state = self.state.clone();
        let rising = Self::rising_task(self.state.clone());
        self.set_motion(Some(tokio::spawn(async move {
            tokio::time::sleep(Duration::from_secs(2)).await;
            {
                let mut st = state.lock().unwrap();
                st.history
                    .extend_from_slice(&[(MINUTES_NOW % 256) as u8, countdown(true)]);
                st.set_history_len();
            }
            tokio::time::sleep(Duration::from_secs_f64(BEEP.as_secs_f64())).await;
            rising.await;
        })));
    }

    fn start_rising(&self) {
        self.set_motion(Some(tokio::spawn(Self::rising_task(self.state.clone()))));
    }

    /// Ramps the status register from sitting to standing height, a tenth of an inch at a
    /// time with the motion bit set, then back again every so often.
    async fn rising_task(state: Arc<Mutex<State>>) {
        let mut up = true;
        loop {
            let (from, to) = if up {
                (SITTING_TENTHS, STANDING_TENTHS)
            } else {
                (STANDING_TENTHS, SITTING_TENTHS)
            };
            let step: i64 = if up { 1 } else { -1 };
            let mut height = i64::from(from);
            while height != i64::from(to) {
                height += step;
                state
                    .lock()
                    .unwrap()
                    .registers
                    .insert(addr::STATUS, 0x8000_0100 | height as u32);
                tokio::time::sleep(Duration::from_millis(110)).await;
            }
            state
                .lock()
                .unwrap()
                .registers
                .insert(addr::STATUS, 0x100 | to);
            up = !up;
            tokio::time::sleep(Duration::from_secs(20)).await;
        }
    }
}

impl Drop for SimulatedTransport {
    fn drop(&mut self) {
        if let Some(task) = self.motion.get_mut().unwrap().take() {
            task.abort();
        }
    }
}

#[async_trait]
impl Transport for SimulatedTransport {
    fn events(&self) -> EventStream {
        self.events.stream()
    }

    async fn connect(&self) -> Result<(), DeskError> {
        match self.scenario {
            Scenario::Connecting => {
                self.events.emit(ConnectionEvent::Connecting);
                std::future::pending::<()>().await;
                Ok(())
            }
            Scenario::OutOfReach => Err(DeskError::Gatt("simulated: out of reach".into())),
            Scenario::BluetoothOff => Err(DeskError::BluetoothOff),
            Scenario::Unauthorized => Err(DeskError::Unauthorized),
            _ => {
                self.events.emit(ConnectionEvent::Connected);
                match self.scenario {
                    Scenario::Moving => self.start_rising(),
                    Scenario::Beeping => self.start_beeping(),
                    _ => {}
                }
                Ok(())
            }
        }
    }

    async fn disconnect(&self) {
        self.set_motion(None);
        self.events.emit(ConnectionEvent::Disconnected {
            reason: Some("requested".into()),
        });
    }

    async fn read_register(&self, address: u32) -> Result<u32, DeskError> {
        let st = self.state.lock().unwrap();
        if address >= addr::HISTORY_BASE {
            let off = (address - addr::HISTORY_BASE) as usize;
            return Ok(st
                .history
                .get(off..off + 4)
                .map_or(0, |b| u32::from_le_bytes([b[0], b[1], b[2], b[3]])));
        }
        Ok(st.registers.get(&address).copied().unwrap_or(0))
    }

    async fn write_register(&self, address: u32, value: u32) -> Result<(), DeskError> {
        let mut st = self.state.lock().unwrap();
        if tempo_core::registers::is_preset_address(address) {
            let height = st.registers.get(&addr::STATUS).copied().unwrap_or(0) & 0xFFFF;
            st.registers.insert(address, height);
        } else {
            st.registers.insert(address, value);
        }
        Ok(())
    }

    async fn burst_read(&self, byte_address: u32, chunks: usize) -> Result<Vec<u8>, DeskError> {
        let st = self.state.lock().unwrap();
        let aligned = byte_address & !3;
        let n = chunks * 20;
        if aligned >= addr::HISTORY_BASE {
            let start = (aligned - addr::HISTORY_BASE) as usize;
            Ok((0..n)
                .map(|k| st.history.get(start + k).copied().unwrap_or(0))
                .collect())
        } else if let Some(s) = st.strings.get(&aligned) {
            let mut out = s.clone();
            out.resize(n.max(s.len()), 0);
            Ok(out)
        } else {
            Ok(register_block(&st.registers, aligned, n))
        }
    }

    async fn burst_write(&self, byte_address: u32, data: &[u8]) -> Result<(), DeskError> {
        self.state
            .lock()
            .unwrap()
            .strings
            .insert(byte_address, data.to_vec());
        Ok(())
    }
}

/// `n` bytes of the register space from `aligned`, little-endian words, 0xDEADBEEF where
/// nothing is mapped: what the real desk serves for a burst below the history ring.
pub fn register_block(registers: &HashMap<u32, u32>, aligned: u32, n: usize) -> Vec<u8> {
    (0..n)
        .map(|k| {
            let address = aligned + (k as u32 & !3);
            let word = registers.get(&address).copied().unwrap_or(0xDEAD_BEEF);
            word.to_le_bytes()[k % 4]
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scenario_names_parse() {
        assert_eq!("busy-day".parse::<Scenario>(), Ok(Scenario::BusyDay));
        assert_eq!("busyDay".parse::<Scenario>(), Ok(Scenario::BusyDay));
        assert_eq!("cruise_off".parse::<Scenario>(), Ok(Scenario::CruiseOff));
        assert!("flying".parse::<Scenario>().is_err());
        for s in Scenario::ALL {
            assert_eq!(s.name().parse::<Scenario>(), Ok(s));
        }
    }

    #[tokio::test]
    async fn every_scenario_seeds_a_desk() {
        for s in Scenario::ALL {
            let t = SimulatedTransport::new(s);
            assert_eq!(
                t.read_register(addr::FIRMWARE_APPLICATION).await.unwrap(),
                0x0001_0005
            );
            let ptr = t.read_register(addr::HISTORY_WRITE_POINTER).await.unwrap();
            assert_eq!(ptr % 2, 0, "{s}: whole entries");
            if s == Scenario::Away {
                let bytes = t
                    .burst_read(addr::HISTORY_BASE, (ptr as usize).div_ceil(20))
                    .await
                    .unwrap();
                assert_eq!(bytes[ptr as usize - 1], presence(false));
            }
        }
    }

    #[tokio::test(start_paused = true)]
    async fn beeping_announces_then_rises() {
        let t = SimulatedTransport::new(Scenario::Beeping);
        let before = t.read_register(addr::HISTORY_WRITE_POINTER).await.unwrap();
        t.connect().await.unwrap();
        tokio::time::sleep(Duration::from_millis(2100)).await;
        assert_eq!(
            t.read_register(addr::HISTORY_WRITE_POINTER).await.unwrap(),
            before + 2
        );
        tokio::time::sleep(Duration::from_secs(16)).await;
        assert!(
            t.read_register(addr::STATUS).await.unwrap() & 0x8000_0000 != 0,
            "rising after the beep"
        );
        t.disconnect().await;
    }
}
