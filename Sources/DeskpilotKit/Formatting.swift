import Foundation

public enum Formatting {
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    public static func height(tenths: Int?) -> String {
        guard let tenths else { return "--" }
        return String(format: "%.1f\"", Double(tenths) / 10)
    }

    /// "12:34" until `date`; "now" when overdue.
    public static func countdown(to date: Date, now: Date = Date()) -> String {
        let remaining = Int(date.timeIntervalSince(now).rounded())
        if remaining <= 0 { return "now" }
        return String(format: "%d:%02d", remaining / 60, remaining % 60)
    }

    public static func countdownMinutes(to date: Date, now: Date = Date()) -> String {
        let remaining = Int((date.timeIntervalSince(now) / 60).rounded(.up))
        return remaining <= 0 ? "now" : "\(remaining)m"
    }
}
