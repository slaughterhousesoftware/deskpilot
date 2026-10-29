import Foundation
import SwiftUI
import DeskpilotKit

/// The single colour, symbol and wording vocabulary for the three posture states. Every part of
/// the Dashboard - the tiles, the day timeline, the week chart and both legends - reads its
/// colours from here, so a state always looks the same wherever it appears.
enum PostureStyle {
    /// Draw order and legend order: the two "at the desk" states first, then away.
    static let ordered: [PostureState] = [.standing, .sitting, .away]

    /// The shared palette keeps posture colours consistent with the menu popup.
    static func color(_ state: PostureState) -> Color {
        switch state {
        case .standing: return DeskpilotAppearance.standing
        case .sitting: return DeskpilotAppearance.sitting
        case .away: return Color.gray.opacity(0.14)
        }
    }

    /// A break away from the desk, the same in the ring, the charts and the menu bar strip:
    /// a solid medium grey with enough contrast over the translucent cards.
    /// (`color(.away)` is the faint wash for empty cells.)
    static func breakColor(_ scheme: ColorScheme) -> Color {
        Color(white: scheme == .dark ? 0.48 : 0.62)
    }

    /// The posture colours for words: deepened in the light appearance so small text reads
    /// on a white card, as the balance bar's figures are.
    static func textColor(_ state: PostureState, _ scheme: ColorScheme) -> Color {
        switch state {
        case .standing: return scheme == .dark ? DeskpilotAppearance.standing : Color(red: 0, green: 0.46, blue: 0.42)
        case .sitting: return scheme == .dark ? DeskpilotAppearance.sitting : Color(red: 0, green: 0.37, blue: 0.73)
        case .away: return .secondary
        }
    }

    static func label(_ state: PostureState) -> String {
        switch state {
        case .standing: return "Standing"
        case .sitting: return "Sitting"
        case .away: return "Away"
        }
    }

    /// The desk pictogram for a state - the same drawings the menu bar uses.
    static func glyph(_ state: PostureState) -> DeskGlyph {
        switch state {
        case .standing: return .standing
        case .sitting: return .sitting
        case .away: return .outOfReach
        }
    }

    /// The row a state sits on in the day chart: standing above sitting above a break, like
    /// the stages of a sleep chart.
    static func level(_ state: PostureState) -> Double {
        switch state {
        case .standing: return 2
        case .sitting: return 1
        case .away: return 0
        }
    }
}

/// A moment the day chart steps from one row to another: the boundary between two adjacent
/// at-desk segments in different postures.
struct PostureStep: Identifiable {
    let date: Date
    let from: PostureState
    let to: PostureState
    var id: Date { date }
}

/// A day's numbers as the Dashboard talks about them: `PostureTimeline`'s raw totals plus the
/// distinction those totals can't make on their own - away time that is a *break* between two
/// spells at the desk, versus away time before you first arrived or after you left for the day.
struct DaySummary: Identifiable, Equatable {
    let totals: DayTotals
    /// Away time between the first arrival and the last moment at the desk. The night before
    /// you sat down is not a break, so it isn't counted here.
    let breakAway: TimeInterval

    var id: Date { totals.day }
    var day: Date { totals.day }
    /// Standing plus sitting: the time the desk was actually in use.
    var atDesk: TimeInterval { totals.standing + totals.sitting }
    /// Share of desk time spent standing, 0...1, or nil if the desk wasn't used that day.
    var standingShare: Double? {
        guard atDesk > 0 else { return nil }
        return totals.standing / atDesk
    }
}

/// The first arrival and the last moment at the desk on one day.
struct PresenceBounds: Equatable {
    let first: Date
    let last: Date
}

/// One stacked slice of one bar in the week chart.
///
/// The x axis is a plain ordered category - one slot per desk day, keyed by `dayKey` - rather
/// than a date scale. A `.day`-binned date scale centres its marks in the bin while
/// `AxisMarks(values:)` marks the bin's *start*, which drew every bar half a day to the right
/// of its own weekday letter, and it leaves the set of slots up to whatever days happen to
/// carry data. Seven fixed categories place each bar over its label and guarantee that a day
/// with no desk time still gets a slot rather than vanishing.
struct DayBarSlice: Identifiable {
    /// The desk day this slice belongs to (starts at the desk's middle-of-night hour).
    let dayStart: Date
    /// The x category: `dayStart` as "yyyy-MM-dd", stable and unique across the week.
    let dayKey: String
    let state: PostureState
    let hours: Double

    var id: String { "\(dayKey)-\(state.rawValue)" }
}

/// Pure data preparation for the two charts. Kept free of view state so it can be reasoned
/// about (and later tested) on its own.
enum DashboardCharts {
    /// The plot height of the week and month charts, whose columns run the whole clock.
    static let chartHeight: CGFloat = 200
    /// The day chart's: three rows need less room than a sleep chart's four stages.
    static let dayChartHeight: CGFloat = 170
    /// Room between the date controls and every chart's plot, for what sits just above it:
    /// the week and month clock's top label, and the day chart's Now dot.
    static let chartHeadroom: CGFloat = 20
    /// The charts' rules - row and hour lines, plot edges - light, as Health's are.
    static let ruleColor = Color.gray.opacity(0.3)
    /// Health's short dashes, for hour lines (day) and day or week lines (week, month).
    static let hourStroke = StrokeStyle(lineWidth: 1, dash: [2, 2])
    static let yAxisLabelSpacing: CGFloat = 6

    // MARK: - Days

    /// The `count` consecutive desk days ending at (and including) `dayStart`, oldest first.
    static func dayStarts(endingAt dayStart: Date, count: Int, calendar: Calendar = .current) -> [Date] {
        guard count > 0 else { return [] }
        return (0..<count).reversed().map { offset in
            calendar.date(byAdding: .day, value: -offset, to: dayStart)
                ?? dayStart.addingTimeInterval(-86_400 * Double(offset))
        }
    }

    /// The end of the desk day that begins at `dayStart`: a full 24 hours later, or `now` if
    /// the day is still in progress.
    static func dayEnd(dayStart: Date, now: Date, calendar: Calendar = .current) -> Date {
        let full = calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(86_400)
        return min(full, max(now, dayStart))
    }

    /// "Today", "Yesterday", or "Wednesday, Sep 2".
    static func dayTitle(dayStart: Date, todayStart: Date, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day],
                                           from: calendar.startOfDay(for: dayStart),
                                           to: calendar.startOfDay(for: todayStart)).day ?? 0
        switch days {
        case 0: return "Today"
        case 1: return "Yesterday"
        default: return dayTitleFormatter.string(from: dayStart)
        }
    }

    /// The one-letter weekday initial used along the week chart's x axis.
    static func weekdayInitial(_ date: Date) -> String {
        String(weekdayFormatter.string(from: date).prefix(1))
    }

    // MARK: - Week chart

    /// Flattens the week into stacked slices of *desk time only* - standing at the bottom,
    /// sitting above it. Away is deliberately absent: stacking it made every bar the full 24
    /// hours, which said nothing and pushed the axis to 30 h.
    static func slices(_ days: [DaySummary]) -> [DayBarSlice] {
        days.flatMap { day -> [DayBarSlice] in
            [(PostureState.standing, day.totals.standing), (.sitting, day.totals.sitting)]
                .compactMap { state, seconds in
                    guard seconds > 0 else { return nil }
                    return DayBarSlice(dayStart: day.day,
                                       dayKey: dayKey(day.day),
                                       state: state,
                                       hours: seconds / 3600)
                }
        }
    }

    /// The week chart's x categories, oldest first. Passed to `chartXScale` so all seven days
    /// keep their slot even when nothing happened on them.
    static func dayKeys(_ days: [DaySummary]) -> [String] {
        days.map { dayKey($0.day) }
    }

    /// A stable, sortable, locale-independent identifier for a desk day.
    static func dayKey(_ dayStart: Date) -> String {
        dayKeyFormatter.string(from: dayStart)
    }

    /// The tallest bar rounded up to an even number of hours, so `.stride(by: 2)` lands on the
    /// top of the axis. Never below 2 h, so an empty week still draws a sensible scale.
    static func weekAxisMaxHours(_ days: [DaySummary]) -> Double {
        let tallest = days.map { $0.atDesk / 3600 }.max() ?? 0
        return max(2, (tallest / 2).rounded(.up) * 2)
    }

    /// Days looked up by their x category, for the week chart's axis labels and hover.
    static func daysByKey(_ days: [DaySummary]) -> [String: DaySummary] {
        Dictionary(days.map { (dayKey($0.day), $0) }, uniquingKeysWith: { _, latest in latest })
    }

    // MARK: - Heatmap

    /// How many weeks the heatmap covers, including the current one: a year, like GitHub's
    /// contribution graph, which at 10 pt squares and 3 pt gaps fills the fixed window.
    static let heatmapWeeks = 53

    /// Every desk day from the start of the week `heatmapWeeks - 1` weeks ago up to today.
    static func heatmapDayStarts(todayStart: Date, calendar: Calendar = .current) -> [Date] {
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: todayStart)?.start ?? todayStart
        guard let firstWeek = calendar.date(byAdding: .weekOfYear, value: -(heatmapWeeks - 1), to: thisWeek),
              let firstDay = calendar.date(bySettingHour: calendar.component(.hour, from: todayStart),
                                           minute: 0, second: 0, of: firstWeek) else { return [todayStart] }
        var days: [Date] = []
        var day = firstDay
        while day <= todayStart {
            days.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return days
    }

    /// 0 for a day the desk wasn't used, then four steps up to the best day in the grid.
    static func heatLevel(atDesk: TimeInterval, max: TimeInterval) -> Int {
        guard atDesk > 0, max > 0 else { return 0 }
        return Swift.max(1, Swift.min(4, Int((atDesk / max * 4).rounded(.up))))
    }

    // MARK: - Presence

    /// The first and last moments the desk was in use on this day, or nil if it never was.
    static func presenceBounds(_ segments: [PostureSegment]) -> PresenceBounds? {
        let atDesk = segments.filter { $0.state != .away }
        guard let first = atDesk.first, let last = atDesk.last else { return nil }
        return PresenceBounds(first: first.start, last: last.end)
    }

    /// True for away time that sits outside the working day rather than inside it: before the
    /// first arrival, or after the last time at the desk. This is the night, not a break, and
    /// neither the break figures nor the chart's grey should claim it. On a day still in
    /// progress (`openEnded`) the time since the last spell is a break that hasn't ended yet,
    /// not the night, so only the morning counts as off the clock.
    static func isOffClock(_ segment: PostureSegment, bounds: PresenceBounds?, openEnded: Bool = false) -> Bool {
        guard segment.state == .away else { return false }
        guard let bounds else { return true }
        return segment.end <= bounds.first || (!openEnded && segment.start >= bounds.last)
    }

    /// Unbroken spells at the desk: runs of adjacent standing/sitting segments merged into one
    /// range each, in order. A break (or the night) ends a spell.
    static func stretches(_ segments: [PostureSegment]) -> [ClosedRange<Date>] {
        var stretches: [ClosedRange<Date>] = []
        var open: (start: Date, end: Date)?
        for segment in segments {
            if segment.state == .away {
                if let spell = open { stretches.append(spell.start...spell.end) }
                open = nil
            } else if let spell = open, spell.end == segment.start {
                open = (spell.start, segment.end)
            } else {
                if let spell = open { stretches.append(spell.start...spell.end) }
                open = (segment.start, segment.end)
            }
        }
        if let spell = open { stretches.append(spell.start...spell.end) }
        return stretches
    }

    /// How many breaks were taken: away spells between the first arrival and the last moment
    /// at the desk.
    static func breakCount(_ segments: [PostureSegment], openEnded: Bool = false) -> Int {
        let bounds = presenceBounds(segments)
        return segments.filter { $0.state == .away && !isOffClock($0, bounds: bounds, openEnded: openEnded) }.count
    }

    /// Away time that is genuinely a break: everything grey that falls between the first
    /// arrival and the last moment at the desk.
    static func breakAway(_ segments: [PostureSegment], openEnded: Bool = false) -> TimeInterval {
        let bounds = presenceBounds(segments)
        return segments
            .filter { $0.state == .away && !isOffClock($0, bounds: bounds, openEnded: openEnded) }
            .reduce(0) { $0 + $1.duration }
    }

    // MARK: - Day timeline

    /// Where the chart steps between rows: every boundary where one at-desk segment runs
    /// straight into another in the other posture.
    static func steps(_ segments: [PostureSegment]) -> [PostureStep] {
        zip(segments, segments.dropFirst()).compactMap { earlier, later in
            guard earlier.state != .away, later.state != .away, earlier.state != later.state,
                  earlier.end == later.start else { return nil }
            return PostureStep(date: later.start, from: earlier.state, to: later.state)
        }
    }

    /// Show the entire desk day, including late-night sessions. Calendar day boundaries
    /// preserve the complete 23- or 25-hour window across daylight-saving changes.
    static func timelineDomain(bounds: PresenceBounds?, dayStart: Date, dayFullEnd: Date,
                               now: Date, isToday: Bool,
                               calendar: Calendar = .current) -> ClosedRange<Date> {
        let end = dayFullEnd > dayStart ? dayFullEnd
            : calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        return dayStart...end
    }

    /// The segment covering `date`, if any. Segments are contiguous and sorted, so a linear
    /// scan is both correct and fast enough for a day's worth of them.
    static func segment(at date: Date, in segments: [PostureSegment]) -> PostureSegment? {
        segments.first { $0.start <= date && date < $0.end } ?? segments.last { $0.end == date }
    }

    /// "9:12 – 9:34 AM": the day period is printed once when both ends share it, and in a
    /// 24-hour locale (where `periodFormatter` yields nothing) not at all.
    static func timeRange(_ segment: PostureSegment) -> String {
        let startPeriod = periodFormatter.string(from: segment.start)
        let endPeriod = periodFormatter.string(from: segment.end)
        let sharesPeriod = !startPeriod.isEmpty && startPeriod == endPeriod
        let startText = sharesPeriod
            ? bareTimeFormatter.string(from: segment.start)
            : timeFormatter.string(from: segment.start)
        return "\(startText) – \(timeFormatter.string(from: segment.end))"
    }

    /// "22 min", or "1 h 04 min" once a segment runs past the hour.
    static func segmentLength(_ segment: PostureSegment) -> String {
        let minutes = Int((segment.duration / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        return String(format: "%d h %02d min", minutes / 60, minutes % 60)
    }

    // MARK: - Footer

    /// "2 s ago" / "4 min ago" / "3 h ago", for the freshness line under the charts.
    static func relativeAge(of date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date).rounded()))
        if seconds < 60 { return "\(seconds) s ago" }
        if seconds < 3600 { return "\(seconds / 60) min ago" }
        return "\(seconds / 3600) h ago"
    }

    // MARK: - Formatters

    private static let dayTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEEMMMd")
        return formatter
    }()

    /// Fixed format, POSIX locale, so the key is a key and not something a locale can restyle.
    private static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEE")
        return formatter
    }()

    /// The locale's own clock: "9:34 AM" where there is a day period, "09:34" where there isn't.
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter
    }()

    /// Twelve-hour clock without the day period. Only used when `periodFormatter` proves the
    /// locale has one, so it never forces a 12-hour clock on a 24-hour locale.
    private static let bareTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("hmm")
        return formatter
    }()

    /// Only the day period ("AM"/"PM"), used to decide whether the range needs it twice. In
    /// locales with no day period this is the empty string for every date, so the range simply
    /// prints both ends in their plain form.
    private static let periodFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("a")
        return formatter
    }()
}
