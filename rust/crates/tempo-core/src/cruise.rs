//! One cruise-control timing slot: `(standing_seconds << 16) | sitting_seconds`.

use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CruiseSlot {
    pub standing_seconds: u32,
    pub sitting_seconds: u32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Error)]
pub enum CruiseError {
    #[error("standing minutes must be between 1 and 240")]
    StandingOutOfRange,
    #[error("cycle minutes must be between 2 and 240")]
    CycleOutOfRange,
    #[error("standing must be shorter than the cycle")]
    StandingNotShorterThanCycle,
}

impl CruiseSlot {
    pub const fn new(standing_seconds: u32, sitting_seconds: u32) -> Self {
        Self {
            standing_seconds,
            sitting_seconds,
        }
    }

    pub const fn from_raw(raw: u32) -> Self {
        Self {
            standing_seconds: raw >> 16,
            sitting_seconds: raw & 0xFFFF,
        }
    }

    pub const fn raw(self) -> u32 {
        (self.standing_seconds & 0xFFFF) << 16 | (self.sitting_seconds & 0xFFFF)
    }

    pub const fn cycle_seconds(self) -> u32 {
        self.standing_seconds + self.sitting_seconds
    }

    pub fn standing_minutes_per_hour(self) -> u32 {
        let cycle = self.cycle_seconds();
        if cycle == 0 {
            0
        } else {
            (f64::from(self.standing_seconds) * 60.0 / f64::from(cycle)).round() as u32
        }
    }

    /// Mirrors the phone app: minutes in, seconds out, standing must be shorter than the cycle.
    pub fn make(standing_minutes: u32, cycle_minutes: u32) -> Result<Self, CruiseError> {
        if !(1..=240).contains(&standing_minutes) {
            return Err(CruiseError::StandingOutOfRange);
        }
        if !(2..=240).contains(&cycle_minutes) {
            return Err(CruiseError::CycleOutOfRange);
        }
        if standing_minutes >= cycle_minutes {
            return Err(CruiseError::StandingNotShorterThanCycle);
        }
        Ok(Self::new(
            standing_minutes * 60,
            (cycle_minutes - standing_minutes) * 60,
        ))
    }

    /// The phone app's "minutes standing per hour" choices.
    pub const PRESETS: [CruiseSlot; 7] = [
        CruiseSlot::new(5 * 60, 55 * 60),
        CruiseSlot::new(10 * 60, 50 * 60),
        CruiseSlot::new(15 * 60, 45 * 60),
        CruiseSlot::new(20 * 60, 40 * 60),
        CruiseSlot::new(22 * 60, 38 * 60),
        CruiseSlot::new(30 * 60, 30 * 60),
        CruiseSlot::new(40 * 60, 20 * 60),
    ];
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_observed_slots() {
        let custom = CruiseSlot::from_raw(0x04B0_04B0);
        assert_eq!(
            (custom.standing_seconds, custom.sitting_seconds),
            (1200, 1200)
        );
        assert_eq!(custom.cycle_seconds(), 2400);
        assert_eq!(custom.standing_minutes_per_hour(), 30);
        let ten = CruiseSlot::from_raw(0x0258_0BB8);
        assert_eq!((ten.standing_seconds, ten.sitting_seconds), (600, 3000));
        assert_eq!(ten.standing_minutes_per_hour(), 10);
    }

    #[test]
    fn encodes_like_phone_app() {
        let slot = CruiseSlot::make(20, 60).unwrap();
        assert_eq!(slot.raw(), 0x04B0_0960);
        assert_eq!(CruiseSlot::from_raw(slot.raw()), slot);
    }

    #[test]
    fn rejects_invalid_timing() {
        assert_eq!(
            CruiseSlot::make(0, 30),
            Err(CruiseError::StandingOutOfRange)
        );
        assert_eq!(
            CruiseSlot::make(30, 30),
            Err(CruiseError::StandingNotShorterThanCycle)
        );
        assert_eq!(
            CruiseSlot::make(10, 5),
            Err(CruiseError::StandingNotShorterThanCycle)
        );
        assert_eq!(CruiseSlot::make(10, 241), Err(CruiseError::CycleOutOfRange));
    }

    #[test]
    fn presets_mirror_the_app() {
        let per_hour: Vec<u32> = CruiseSlot::PRESETS
            .iter()
            .map(|s| s.standing_minutes_per_hour())
            .collect();
        assert_eq!(per_hour, [5, 10, 15, 20, 22, 30, 40]);
        assert!(CruiseSlot::PRESETS
            .iter()
            .all(|s| s.cycle_seconds() == 3600));
    }

    #[test]
    fn serde_matches_swift() {
        let json = serde_json::to_string(&CruiseSlot::new(1200, 2400)).unwrap();
        assert_eq!(json, r#"{"standingSeconds":1200,"sittingSeconds":2400}"#);
    }
}
