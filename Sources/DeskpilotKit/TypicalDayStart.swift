import Foundation

/// When the person's desk day usually begins: the median of their first arrival over the
/// recent days before today, as a clock hour. The menu's strip starts there instead of at a
/// fixed 6 AM, so the hours they actually spend at the desk get the room.
public enum TypicalDayStart {
    /// The hour from the saved history, or nil with fewer than `minimumDays` days to go on.
    public static func hour(document: HistoryDocument, now: Date, days: Int = 14, minimumDays: Int = 3,
                            calendar: Calendar = .current) -> Int? {
        let today = DayRollup.dayStart(now: now, middleOfNightHour: document.middleOfNightHour, calendar: calendar)
        guard let from = calendar.date(byAdding: .day, value: -days, to: today) else { return nil }
        let segments = PostureTimeline.segments(events: document.events, from: from, to: today,
                                                standingThresholdInches: document.standingThresholdInches)
        return hour(segments: segments, middleOfNightHour: document.middleOfNightHour,
                    minimumDays: minimumDays, calendar: calendar)
    }

    /// The hour from chronological segments. A day's first arrival is its first real stretch at
    /// the desk, after any stray visits (see `DeskDay`); days split at `middleOfNightHour`, so an
    /// arrival at 1 AM counts as a late one, not an early one.
    public static func hour(segments: [PostureSegment], middleOfNightHour: Int, minimumDays: Int = 3,
                            calendar: Calendar = .current) -> Int? {
        // Each day on its own, without the stray visits at its edges (see `DeskDay`), as
        // minutes after midnight with arrivals before the day boundary carried past 24:00.
        let minutes = DeskDay.realEdges(segments: segments, middleOfNightHour: middleOfNightHour,
                                        night: .around(middleOfNightHour: middleOfNightHour), calendar: calendar)
            .map(\.arrival).sorted()
        guard minutes.count >= max(1, minimumDays) else { return nil }
        let middle = minutes.count / 2
        let median = minutes.count % 2 == 1 ? minutes[middle] : (minutes[middle - 1] + minutes[middle]) / 2
        return (median / 60) % 24
    }
}
