//! Time helpers: the file date format Swift reads, and the injectable clock.

use jiff::{SignedDuration, Timestamp};

/// Seconds as a float, for the few places that log or compare with sub-second precision.
pub fn secs(d: SignedDuration) -> f64 {
    d.as_secs_f64()
}

/// A duration in whole seconds.
pub const fn seconds(s: i64) -> SignedDuration {
    SignedDuration::from_secs(s)
}

/// A duration in minutes.
pub const fn minutes(m: i64) -> SignedDuration {
    SignedDuration::from_mins(m)
}

/// Where business time comes from. The service injects a `SystemClock`; tests inject a
/// clock they advance by hand. Poll cadence does *not* use this - it runs on the runtime's
/// own timer - so a frozen test clock never stalls IO.
pub trait Clock: Send + Sync + 'static {
    fn now(&self) -> Timestamp;
}

#[derive(Clone, Copy, Debug, Default)]
pub struct SystemClock;

impl Clock for SystemClock {
    fn now(&self) -> Timestamp {
        Timestamp::now()
    }
}

/// Serde for dates in files shared with the Swift apps: whole seconds, `Z`, as Swift's
/// `.iso8601` strategy writes them (`2026-10-13T22:10:36Z`). Reading accepts fractional
/// seconds and offsets too.
pub mod iso8601_seconds {
    use jiff::Timestamp;
    use serde::{de, Deserialize, Deserializer, Serializer};

    pub fn format(ts: Timestamp) -> String {
        // Truncate toward zero like Swift's encoder does: 1800000000.75 -> ...:00Z.
        let whole = Timestamp::from_second(ts.as_second()).unwrap_or(ts);
        whole.strftime("%Y-%m-%dT%H:%M:%SZ").to_string()
    }

    pub fn serialize<S: Serializer>(ts: &Timestamp, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&format(*ts))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Timestamp, D::Error> {
        let text = <&str>::deserialize(d)?;
        text.parse::<Timestamp>().map_err(de::Error::custom)
    }

    pub mod option {
        use jiff::Timestamp;
        use serde::{Deserialize, Deserializer, Serializer};

        pub fn serialize<S: Serializer>(ts: &Option<Timestamp>, s: S) -> Result<S::Ok, S::Error> {
            match ts {
                Some(ts) => s.serialize_str(&super::format(*ts)),
                None => s.serialize_none(),
            }
        }

        pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Option<Timestamp>, D::Error> {
            let text: Option<String> = Option::deserialize(d)?;
            text.map(|t| t.parse::<Timestamp>().map_err(serde::de::Error::custom))
                .transpose()
        }
    }
}

/// Serde for durations as a plain number of seconds (`"atDeskSeconds": 3600.5`), as Swift
/// encodes `TimeInterval`.
pub mod duration_seconds {
    use jiff::SignedDuration;
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(d: &SignedDuration, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_f64(d.as_secs_f64())
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<SignedDuration, D::Error> {
        let secs = f64::deserialize(d)?;
        SignedDuration::try_from_secs_f64(secs).map_err(serde::de::Error::custom)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::{Deserialize, Serialize};

    #[derive(Serialize, Deserialize, PartialEq, Debug)]
    struct Doc {
        #[serde(with = "iso8601_seconds")]
        at: Timestamp,
        #[serde(
            with = "iso8601_seconds::option",
            default,
            skip_serializing_if = "Option::is_none"
        )]
        maybe: Option<Timestamp>,
    }

    #[test]
    fn writes_whole_seconds_and_reads_fractions() {
        let at = Timestamp::from_second(1_800_000_000).unwrap() + SignedDuration::from_millis(750);
        let json = serde_json::to_string(&Doc { at, maybe: None }).unwrap();
        assert_eq!(json, r#"{"at":"2027-01-15T08:00:00Z"}"#);
        let back: Doc = serde_json::from_str(
            r#"{"at":"2027-01-15T08:00:00.123Z","maybe":"2027-01-15T09:00:00-07:00"}"#,
        )
        .unwrap();
        assert_eq!(
            back.at,
            Timestamp::from_second(1_800_000_000).unwrap() + SignedDuration::from_millis(123)
        );
        assert_eq!(
            back.maybe,
            Some(Timestamp::from_second(1_800_000_000 + 8 * 3600).unwrap())
        );
    }
}
