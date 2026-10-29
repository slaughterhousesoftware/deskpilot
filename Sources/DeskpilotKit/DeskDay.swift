import Foundation

/// What counts as the working day at the desk, shared by the menu's strip and the Dashboard.
///
/// The desk logs presence in spells of five minutes or more, and at the edges of a day it logs
/// some that aren't the day at all: eight minutes at 4:22 AM, sixteen hours after the last
/// spell and seven before the next (Oct 18), or a string of short ones through the night
/// (Oct 19). Taken as the day's first arrival, one of those turns the whole morning into a
/// break.
///
/// So a day runs from its first real stretch at the desk to its last, and:
/// - a *stray* is a cluster of desk time (spells joined across gaps shorter than `isolation`)
///   that totals under `strayLimit`, lies before the day's first real cluster or after its
///   last, is cut off from it by `isolation` or more away, and falls in the person's `night`
///   (`NightWindow`): the hours they are normally asleep. Strays become away time, so they
///   neither start nor stretch the day.
/// - five minutes at the desk in the evening is not a stray, however far from the rest of the
///   day: that is someone using their computer. Only the night is the sensor's.
/// - a *break* is away time between real desk time, however long. A short visit in the middle
///   of the day stays: that's someone coming back, not the sensor.
/// - on a day still under way (`openEnded`), the latest cluster is never a stray - it may be
///   someone who has only just come back.
public enum DeskDay {
    public static let isolation: TimeInterval = 60 * 60
    public static let strayLimit: TimeInterval = 15 * 60

    /// `segments` (chronological, contiguous) with the strays at either end turned to away
    /// time, and neighbouring away time merged.
    public static func withoutStrays(_ segments: [PostureSegment], openEnded: Bool = false,
                                     night: NightWindow = .around(middleOfNightHour: 4),
                                     isolation: TimeInterval = isolation,
                                     strayLimit: TimeInterval = strayLimit,
                                     calendar: Calendar = .current) -> [PostureSegment] {
        // Clusters of desk time, as index ranges into `segments`, with their desk minutes.
        var clusters: [(first: Int, last: Int, atDesk: TimeInterval)] = []
        for (index, segment) in segments.enumerated() where segment.state != .away {
            if let last = clusters.last, segment.start.timeIntervalSince(segments[last.last].end) < isolation {
                clusters[clusters.count - 1] = (last.first, index, last.atDesk + segment.duration)
            } else {
                clusters.append((index, index, segment.duration))
            }
        }
        guard clusters.count > 1 else { return segments }
        // Small, and at a time the person is normally asleep.
        func looksStray(_ cluster: (first: Int, last: Int, atDesk: TimeInterval)) -> Bool {
            cluster.atDesk < strayLimit && night.contains(segments[cluster.first].start, calendar: calendar)
        }
        var stray = Set<Int>()
        // From the morning in: strays until the first real cluster.
        var lead = 0
        while lead < clusters.count - 1, looksStray(clusters[lead]) {
            stray.formUnion(clusters[lead].first...clusters[lead].last)
            lead += 1
        }
        // From the night in, unless the day is still going: strays back to the last real one.
        if !openEnded {
            var tail = clusters.count - 1
            while tail > lead, looksStray(clusters[tail]) {
                stray.formUnion(clusters[tail].first...clusters[tail].last)
                tail -= 1
            }
        }
        guard !stray.isEmpty else { return segments }
        var cleaned: [PostureSegment] = []
        for (index, segment) in segments.enumerated() {
            let state = stray.contains(index) && segment.state != .away ? PostureState.away : segment.state
            if let previous = cleaned.last, previous.state == state, previous.end == segment.start {
                cleaned[cleaned.count - 1] = PostureSegment(start: previous.start, end: segment.end, state: state)
            } else {
                cleaned.append(PostureSegment(start: segment.start, end: segment.end, state: state))
            }
        }
        return cleaned
    }
}

/// The hours a person is normally asleep, as a window on the clock: the only time a short,
/// isolated visit at the desk is taken for the sensor rather than for them.
///
/// From their history it is the stretch from three hours after they usually leave the desk
/// for the day to three hours before they usually arrive (`usual`); for someone who works
/// 9 to 6 that is 9 PM to 6 AM. So a five-minute visit at 8 PM stays, and so does one at
/// 4 AM for someone who often starts at 5 - "never done that before" is what the window
/// measures. With fewer than three days to go on, it is the three hours either side of the
/// desk's middle-of-night hour (`around`), 1 to 7 AM by default.
public struct NightWindow: Equatable, Sendable {
    /// Minutes after midnight; the window runs from `start` round through midnight to `end`
    /// when `end` is the smaller.
    public let start: Int
    public let end: Int
    /// How far past the usual hours the day may run before it counts as night.
    public static let margin = 3 * 60
    private static let minutesPerDay = 24 * 60

    public init(start: Int, end: Int) {
        self.start = ((start % Self.minutesPerDay) + Self.minutesPerDay) % Self.minutesPerDay
        self.end = ((end % Self.minutesPerDay) + Self.minutesPerDay) % Self.minutesPerDay
    }

    public static func around(middleOfNightHour: Int) -> NightWindow {
        NightWindow(start: middleOfNightHour * 60 - margin, end: middleOfNightHour * 60 + margin)
    }

    /// From the median first arrival and last departure over the recent days before today;
    /// `around` the middle of the night with fewer than `minimumDays` of them.
    public static func usual(document: HistoryDocument, now: Date, days: Int = 14, minimumDays: Int = 3,
                             calendar: Calendar = .current) -> NightWindow {
        let fallback = around(middleOfNightHour: document.middleOfNightHour)
        let today = DayRollup.dayStart(now: now, middleOfNightHour: document.middleOfNightHour, calendar: calendar)
        guard let from = calendar.date(byAdding: .day, value: -days, to: today) else { return fallback }
        let segments = PostureTimeline.segments(events: document.events, from: from, to: today,
                                                standingThresholdInches: document.standingThresholdInches)
        let edges = DeskDay.realEdges(segments: segments, middleOfNightHour: document.middleOfNightHour,
                                      night: fallback, calendar: calendar)
        guard edges.count >= max(1, minimumDays) else { return fallback }
        return usual(arrivals: edges.map(\.arrival), departures: edges.map(\.departure),
                     middleOfNightHour: document.middleOfNightHour) ?? fallback
    }

    /// From days' first arrivals and last departures, as minutes after midnight with times
    /// before the middle of the night carried past 24:00 (a 1 AM departure is a late one).
    /// nil when the usual day leaves no night at all.
    public static func usual(arrivals: [Int], departures: [Int], middleOfNightHour: Int) -> NightWindow? {
        guard !arrivals.isEmpty, arrivals.count == departures.count else { return nil }
        let arrive = median(arrivals), leave = median(departures)
        let start = leave + margin, end = arrive + minutesPerDay - margin
        guard end - start >= 60 else { return nil }
        return NightWindow(start: start, end: end)
    }

    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return start <= end ? (minute >= start && minute < end) : (minute >= start || minute < end)
    }

    private static func median(_ values: [Int]) -> Int {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}

extension DeskDay {
    /// Each day's first real arrival and last real departure, as clock minutes with times
    /// before the middle of the night carried past 24:00, from chronological segments.
    static func realEdges(segments: [PostureSegment], middleOfNightHour: Int, night: NightWindow,
                          calendar: Calendar) -> [(arrival: Int, departure: Int)] {
        var byDay: [Date: [PostureSegment]] = [:]
        for segment in segments {
            let day = DayRollup.dayStart(now: segment.start, middleOfNightHour: middleOfNightHour, calendar: calendar)
            byDay[day, default: []].append(segment)
        }
        func minutes(_ date: Date) -> Int {
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            let hour = parts.hour ?? 0
            return (hour < middleOfNightHour ? hour + 24 : hour) * 60 + (parts.minute ?? 0)
        }
        return byDay.values.compactMap { day in
            let real = withoutStrays(day, night: night, calendar: calendar).filter { $0.state != .away && $0.duration >= 60 }
            guard let first = real.first, let last = real.last else { return nil }
            return (minutes(first.start), minutes(last.end))
        }
    }
}
