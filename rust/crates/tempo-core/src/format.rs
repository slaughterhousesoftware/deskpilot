//! Short strings for UIs. Kept identical to the Swift app's so every front end reads alike.

use jiff::{SignedDuration, Timestamp};

/// `1h 5m` or `5m`.
pub fn duration(d: SignedDuration) -> String {
    let total = d.as_secs_f64().round() as i64;
    let h = total / 3600;
    let m = (total % 3600) / 60;
    if h > 0 {
        format!("{h}h {m}m")
    } else {
        format!("{m}m")
    }
}

/// `26.7"`, or `--` when unknown.
pub fn height(tenths: Option<u16>) -> String {
    match tenths {
        Some(t) => format!("{:.1}\"", f64::from(t) / 10.0),
        None => "--".to_string(),
    }
}

/// `12:34` until `date`; `now` when overdue.
pub fn countdown(to: Timestamp, now: Timestamp) -> String {
    let remaining = to.duration_since(now).as_secs_f64().round() as i64;
    if remaining <= 0 {
        return "now".to_string();
    }
    format!("{}:{:02}", remaining / 60, remaining % 60)
}

/// `12m` until `date`, rounded up; `now` when overdue.
pub fn countdown_minutes(to: Timestamp, now: Timestamp) -> String {
    let remaining = (to.duration_since(now).as_secs_f64() / 60.0).ceil() as i64;
    if remaining <= 0 {
        "now".to_string()
    } else {
        format!("{remaining}m")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::time::seconds;

    #[test]
    fn formats() {
        assert_eq!(duration(seconds(3600 + 300)), "1h 5m");
        assert_eq!(duration(seconds(59)), "0m");
        assert_eq!(duration(seconds(0)), "0m");
        assert_eq!(height(Some(267)), "26.7\"");
        assert_eq!(height(None), "--");
        let now = Timestamp::from_second(1_800_000_000).unwrap();
        assert_eq!(countdown(now + seconds(754), now), "12:34");
        assert_eq!(countdown(now, now), "now");
        assert_eq!(countdown(now + seconds(61), now), "1:01");
        assert_eq!(countdown_minutes(now + seconds(61), now), "2m");
        assert_eq!(countdown_minutes(now - seconds(1), now), "now");
    }
}
