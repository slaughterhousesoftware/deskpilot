//! Register addresses and the bit layouts of the words read from them. See docs/protocol.md.

use jiff::civil::Time;
use serde::{Deserialize, Serialize};
use std::fmt;

/// Global register byte addresses.
pub mod addr {
    pub const FIRMWARE_APPLICATION: u32 = 4;
    pub const FIRMWARE_BOOTLOADER: u32 = 8;
    pub const FIRMWARE_SOFTDEVICE: u32 = 12;
    /// Writing this register's own value back reboots the desk into DFU. Never write it.
    pub const BOOTLOADER_MAGIC: u32 = 16;
    pub const USER_COUNT: u32 = 20;
    pub const CRUISE_SLOT_COUNT: u32 = 24;
    pub const MINUTES_SINCE_POWER_ON: u32 = 32;
    pub const HISTORY_SIZE: u32 = 36;
    pub const HISTORY_WRITE_POINTER: u32 = 44;
    pub const CURRENT_USER: u32 = 52;
    pub const CLOCK: u32 = 56;
    pub const STATUS: u32 = 60;
    pub const HISTORY_BASE: u32 = 0x10000;
}

/// Timestamp byte modulus of the history log: minutes since power-on wrap at 256.
pub const MINUTE_WRAP: u32 = 256;

/// User offset 8, as packed by the phone app's syncDeskData. Configuration, not a
/// remaining-time counter; neither field is evidence that the motor is about to start.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CountdownTiming {
    pub countdown_seconds: u16,
    pub pulse_time_seconds: u16,
}

impl CountdownTiming {
    pub const fn from_raw(raw: u32) -> Option<Self> {
        if raw == 0xDEAD_BEEF {
            None
        } else {
            Some(Self {
                countdown_seconds: raw as u16,
                pulse_time_seconds: (raw >> 16) as u16,
            })
        }
    }
}

/// Offsets within a user block (user 0 at 4096, user 1 at 8192).
pub mod user_offset {
    pub const FLAGS: u32 = 0;
    pub const ACTIVE_CRUISE_SLOT: u32 = 4;
    pub const COUNTDOWN_AND_PULSE: u32 = 8;
    pub const MIDDLE_OF_NIGHT_HOUR: u32 = 12;
    pub const STANDING_HEIGHT: u32 = 16;
    pub const SITTING_HEIGHT: u32 = 20;
    pub const CUSTOM_HEIGHT_ONE: u32 = 24;
    pub const CUSTOM_HEIGHT_TWO: u32 = 28;
    pub const MOVE_COUNT: u32 = 40;
    pub const USER_NAME: u32 = 256;
    pub const PRESET_NAME_ONE: u32 = 320;
    pub const PRESET_NAME_TWO: u32 = 384;
    pub const CRUISE_SLOTS: u32 = 512;
    pub const CRUISE_SLOT_STRIDE: u32 = 16;
}

/// Base byte address of a user block. Only two users exist; anything but 0 is user 1.
pub fn user_base(index: u8) -> u32 {
    if index == 0 {
        4096
    } else {
        8192
    }
}

pub fn cruise_slot_address(user: u8, slot: u8) -> u32 {
    user_base(user) + user_offset::CRUISE_SLOTS + u32::from(slot) * user_offset::CRUISE_SLOT_STRIDE
}

/// Whether `address` is one of the four preset-height registers of either user block.
/// The desk stores its *current* height when any of them is written.
pub fn is_preset_address(address: u32) -> bool {
    [0u8, 1].iter().any(|&user| {
        let base = user_base(user);
        address >= base + user_offset::STANDING_HEIGHT
            && address <= base + user_offset::CUSTOM_HEIGHT_TWO
            && (address - base) % 4 == 0
    })
}

/// Bytes in a name field (user name, preset names): one burst write.
pub const NAME_LENGTH: usize = 20;

/// A stretch of the register space read in one burst: registers are one flat, little-endian
/// address space, so the global block (0..64) and a user block come back in a few chunks
/// instead of a round trip per register.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RegisterBlock {
    pub base: u32,
    pub bytes: Vec<u8>,
}

impl RegisterBlock {
    pub fn new(base: u32, bytes: Vec<u8>) -> Self {
        Self { base, bytes }
    }

    /// The word at `address`, if the block covers it.
    pub fn get(&self, address: u32) -> Option<u32> {
        let offset = address.checked_sub(self.base)? as usize;
        let b = self.bytes.get(offset..offset + 4)?;
        Some(u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
    }

    /// A name field starting at `address`.
    pub fn name(&self, address: u32) -> Option<String> {
        let offset = address.checked_sub(self.base)? as usize;
        decode_name(self.bytes.get(offset..offset + NAME_LENGTH)?)
    }
}

/// A 20-byte name field as text: UTF-8 up to the first NUL, trimmed. `None` when blank or
/// unset (all zeros, or the unmapped 0xDEADBEEF pattern).
pub fn decode_name(bytes: &[u8]) -> Option<String> {
    let end = bytes.iter().position(|&b| b == 0).unwrap_or(bytes.len());
    let text = String::from_utf8_lossy(&bytes[..end]);
    let text = text.trim();
    if text.is_empty() || text.chars().any(|c| c.is_control() || c == '\u{FFFD}') {
        None
    } else {
        Some(text.to_string())
    }
}

/// A name as the desk stores it: UTF-8, cut at a character boundary to leave room for the
/// terminating NUL, zero-padded to the field.
pub fn encode_name(name: &str) -> [u8; NAME_LENGTH] {
    let name = name.trim();
    let mut out = [0u8; NAME_LENGTH];
    let mut end = 0;
    for (index, c) in name.char_indices() {
        let next = index + c.len_utf8();
        if next > NAME_LENGTH - 1 {
            break;
        }
        end = next;
    }
    out[..end].copy_from_slice(&name.as_bytes()[..end]);
    out
}

/// Register 60: height in tenths of an inch (bits 0..15) and the motion bit (31).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct StatusWord {
    pub height_tenths: u16,
    pub is_moving: bool,
}

impl StatusWord {
    pub const fn from_raw(raw: u32) -> Self {
        Self {
            height_tenths: (raw & 0xFFFF) as u16,
            is_moving: raw & 0x8000_0000 != 0,
        }
    }

    pub fn height_inches(self) -> f64 {
        f64::from(self.height_tenths) / 10.0
    }
}

/// User block offset 0. Bit order verified against the phone app's `getUserInfo`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct UserFlags(pub u32);

impl UserFlags {
    pub const SIT_PRESET_SET: UserFlags = UserFlags(1 << 0);
    pub const STANDING_PRESET_SET: UserFlags = UserFlags(1 << 1);
    pub const PAUSED: UserFlags = UserFlags(1 << 2);
    pub const RESERVED: UserFlags = UserFlags(1 << 3);
    pub const PULSE_ONLY: UserFlags = UserFlags(1 << 4);
    pub const USER_ENABLED: UserFlags = UserFlags(1 << 5);
    pub const USER_SELECTED: UserFlags = UserFlags(1 << 6);
    pub const HISTORY_LOGGING: UserFlags = UserFlags(1 << 7);

    pub const fn contains(self, other: UserFlags) -> bool {
        self.0 & other.0 == other.0
    }

    pub const fn with(self, other: UserFlags) -> UserFlags {
        UserFlags(self.0 | other.0)
    }

    pub const fn without(self, other: UserFlags) -> UserFlags {
        UserFlags(self.0 & !other.0)
    }

    pub const fn set(self, other: UserFlags, on: bool) -> UserFlags {
        if on {
            self.with(other)
        } else {
            self.without(other)
        }
    }
}

/// Register 4: `major << 16 | minor << 8 | patch`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct FirmwareVersion {
    pub major: u8,
    pub minor: u8,
    pub patch: u8,
}

impl FirmwareVersion {
    pub const fn from_raw(raw: u32) -> Self {
        Self {
            major: ((raw >> 16) & 0xFF) as u8,
            minor: ((raw >> 8) & 0xFF) as u8,
            patch: (raw & 0xFF) as u8,
        }
    }
}

impl fmt::Display for FirmwareVersion {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}.{}.{}", self.major, self.minor, self.patch)
    }
}

/// Register 56: `hour << 16 | minute << 8 | second`. The phone app writes it on every sync.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DeskClock {
    pub hour: u8,
    pub minute: u8,
    pub second: u8,
}

impl DeskClock {
    pub const fn from_raw(raw: u32) -> Self {
        Self {
            hour: ((raw >> 16) & 0xFF) as u8,
            minute: ((raw >> 8) & 0xFF) as u8,
            second: (raw & 0xFF) as u8,
        }
    }

    /// The wall-clock time of day in the desk's own time zone.
    pub fn from_time(time: Time) -> Self {
        Self {
            hour: time.hour() as u8,
            minute: time.minute() as u8,
            second: time.second() as u8,
        }
    }

    pub const fn raw(self) -> u32 {
        (self.hour as u32) << 16 | (self.minute as u32) << 8 | self.second as u32
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_word_decodes_height_and_motion() {
        let idle = StatusWord::from_raw(0x0000_010B);
        assert_eq!(idle.height_tenths, 267);
        assert!((idle.height_inches() - 26.7).abs() < 0.001);
        assert!(!idle.is_moving);
        let moving = StatusWord::from_raw(0x8000_0126);
        assert_eq!(moving.height_tenths, 294);
        assert!(moving.is_moving);
    }

    #[test]
    fn user_flags_bit_order_matches_phone_app() {
        let flags = UserFlags(0x1E3);
        assert!(flags.contains(UserFlags::SIT_PRESET_SET));
        assert!(flags.contains(UserFlags::STANDING_PRESET_SET));
        assert!(!flags.contains(UserFlags::PAUSED));
        assert!(!flags.contains(UserFlags::PULSE_ONLY));
        assert!(flags.contains(UserFlags::USER_ENABLED));
        assert!(flags.contains(UserFlags::USER_SELECTED));
        assert!(flags.contains(UserFlags::HISTORY_LOGGING));
        assert_eq!(flags.with(UserFlags::PAUSED).0, 0x1E7);
        assert_eq!(
            flags.with(UserFlags::PAUSED).without(UserFlags::PAUSED),
            flags
        );
    }

    #[test]
    fn firmware_version_formats_bytes() {
        assert_eq!(FirmwareVersion::from_raw(0x0001_0005).to_string(), "1.0.5");
        assert_eq!(FirmwareVersion::from_raw(0x0002_0A01).to_string(), "2.10.1");
    }

    #[test]
    fn desk_clock_round_trips() {
        let clock = DeskClock::from_raw(0x000C_0C2B);
        assert_eq!((clock.hour, clock.minute, clock.second), (12, 12, 43));
        assert_eq!(clock.raw(), 0x000C_0C2B);
        let from_time = DeskClock::from_time(Time::constant(17, 5, 9, 0));
        assert_eq!(from_time.raw(), 0x0011_0509);
    }

    #[test]
    fn register_blocks_and_names() {
        let mut bytes = vec![0u8; 64];
        bytes[4..8].copy_from_slice(&0x0001_0005u32.to_le_bytes());
        bytes[60..64].copy_from_slice(&0x8000_010Bu32.to_le_bytes());
        let block = RegisterBlock::new(0, bytes);
        assert_eq!(block.get(addr::FIRMWARE_APPLICATION), Some(0x0001_0005));
        assert_eq!(block.get(addr::STATUS), Some(0x8000_010B));
        assert_eq!(block.get(64), None, "past the end");
        let user = RegisterBlock::new(4096, {
            let mut b = vec![0u8; 300];
            b[256..261].copy_from_slice(b"Kevin");
            b
        });
        assert_eq!(
            user.name(4096 + user_offset::USER_NAME).as_deref(),
            Some("Kevin")
        );
        assert_eq!(decode_name(&[0; 20]), None);
        assert_eq!(decode_name(&[0xEF, 0xBE, 0xAD, 0xDE]), None, "unmapped");
        assert_eq!(decode_name(b"  Standing  \0junk"), Some("Standing".into()));
        let encoded = encode_name("A name that is far too long for the field");
        assert_eq!(encoded[NAME_LENGTH - 1], 0, "always terminated");
        assert_eq!(decode_name(&encoded).as_deref(), Some("A name that is far"));
        let short = encode_name("Desk");
        assert_eq!(&short[..5], b"Desk\0");
        let accented = encode_name(&"é".repeat(12));
        assert_eq!(decode_name(&accented).unwrap().chars().count(), 9);
    }

    #[test]
    fn address_helpers() {
        assert_eq!(user_base(0), 4096);
        assert_eq!(user_base(1), 8192);
        assert_eq!(cruise_slot_address(0, 1), 4624);
        assert_eq!(cruise_slot_address(1, 4), 8192 + 512 + 64);
        assert_eq!(user_base(0) + user_offset::STANDING_HEIGHT, 4112);
        assert!(is_preset_address(4096 + 16));
        assert!(is_preset_address(8192 + 28));
        assert!(!is_preset_address(4096 + 18));
        assert!(!is_preset_address(4096 + 32));
    }
}
