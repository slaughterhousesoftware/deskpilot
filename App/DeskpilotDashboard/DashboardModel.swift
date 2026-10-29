import AppKit
import Foundation
import Observation
import SwiftUI
import DeskpilotKit

/// The outcome of a settings command, flattened so a timeout reads like any other failure.
struct CommandOutcome: Equatable {
    let success: Bool
    let message: String
}

/// How much of the calendar the History tab is looking at.
enum HistoryRange: String, CaseIterable, Identifiable {
    case day, week, month
    var id: String { rawValue }
    var title: String {
        switch self {
        case .day: return "Day"
        case .week: return "Week"
        case .month: return "Month"
        }
    }
    /// Days in one step of the navigator, and in the period the charts show.
    var days: Int {
        switch self {
        case .day: return 1
        case .week: return 7
        case .month: return 30
        }
    }
}

/// One desk day for the day chart: its segments, its first arrival and last moment, the
/// stretch it plots when it is the day chosen, and whether it is still in progress.
struct DayTrack: Equatable {
    let dayStart: Date
    let segments: [PostureSegment]
    let bounds: PresenceBounds?
    let domain: ClosedRange<Date>
    let isToday: Bool

    /// The spells at the desk and the breaks between them; not the night either side.
    var drawn: [PostureSegment] {
        segments.filter { !DashboardCharts.isOffClock($0, bounds: bounds, openEnded: isToday) }
    }
}

/// What the ring above the chart shows: time at the desk and its three parts, for the day
/// window at rest, or a day's average over the week or month at rest.
struct RingFigures: Equatable {
    var atDesk: TimeInterval = 0
    var standing: TimeInterval = 0
    var sitting: TimeInterval = 0
    var breaks: TimeInterval = 0
}

/// Everything the Dashboard shows, read from the two files the menu bar app writes into the
/// App Group (`snapshot.json`, `history.json`), plus the settings commands it writes back
/// through `CommandQueue`.
///
/// The Dashboard is a pure reader of the desk: it never talks to Bluetooth. Refreshing is a
/// plain 2 s poll that only runs while a window is on screen.
@MainActor
@Observable
final class DashboardModel {
    /// The desk's own default day boundary, used until a history document tells us otherwise.
    private static let defaultMiddleOfNightHour = 4

    /// Settings is the fourth destination in the dashboard toolbar.
    var showsSettings = false

    private(set) var snapshot: DeskSnapshot?
    private(set) var history: HistoryDocument?
    /// The hours the person is normally asleep (see `NightWindow`), from the history.
    private var nightWindow: NightWindow?
    /// Refreshed with the polled data so every "now"-dependent view (the now marker, the
    /// footer's age, the open segment's end) moves in one step rather than drifting apart.
    private(set) var now = Date()

    /// The desk day the History tab is showing. Always a `DayRollup.dayStart` value.
    private(set) var selectedDayStart: Date

    /// Day only: the stretch the day chart was scrolled to, once it came to rest. Nil shows
    /// the selected day's own stretch.
    private(set) var dayWindow: ClosedRange<Date>?
    /// Every segment from the first day in the history up to now, walked once per reload; the
    /// charts slice their days out of it as they scroll.
    private(set) var timeline: [PostureSegment] = []
    /// The desk day of the first event in the history, where scrolling back stops.
    private(set) var firstDayStart: Date?
    /// Days already sliced out of `timeline`, until it next changes. Filled while views draw,
    /// so it must not be observed.
    @ObservationIgnored private var columnCache: [Date: DayColumn] = [:]
    @ObservationIgnored private var trackCache: [Date: DayTrack] = [:]
    /// The last `DashboardCharts.heatmapWeeks` weeks up to today, one entry per
    /// desk day.
    private(set) var heatmap: [HeatmapDay] = []
    /// A scroll preview changes only the grid highlight, not the settled chart/ring selection.
    private(set) var heatmapPreviewEnd: Date?
    /// Live summary inputs never change the scroller's settled anchor.
    private(set) var summaryDayWindow: ClosedRange<Date>?
    private(set) var summaryPeriodOffset: Double?
    private(set) var summaryIsSettling = false
    /// Invalidates an in-flight scroll even when Today/the same day is selected again.
    private(set) var navigationRevision = 0

    var highlightedHeatmapDays: ClosedRange<Date> {
        let end = heatmapPreviewEnd ?? selectedDayStart
        return day(-(range.days - 1), from: end)...end
    }

    /// How far past `highlightedHeatmapDays`' last day a scroll has carried the heatmap's
    /// highlight, from -0.5 to 0.5 of a day, so it slides rather than steps.
    private(set) var heatmapPreviewFraction: Double = 0

    /// The highlight's end in days from today, fractional mid-scroll: what the heatmap glides on.
    var heatmapSelectionPosition: Double {
        Double(days(from: todayStart, to: highlightedHeatmapDays.upperBound)) + heatmapPreviewFraction
    }

    func previewHeatmap(endingAt date: Date, fraction: Double = 0) {
        let containing = dayStart(containing: date)
        let end = min(containing, todayStart)
        if heatmapPreviewEnd != end { heatmapPreviewEnd = end }
        // Past today, the highlight stops on it.
        let carried = containing > todayStart ? 0 : min(fraction, end == todayStart ? 0 : 0.5)
        if heatmapPreviewFraction != carried { heatmapPreviewFraction = carried }
    }

    func previewSummary(dayWindow window: ClosedRange<Date>, settling: Bool = false) {
        if summaryIsSettling != settling { summaryIsSettling = settling }
        if summaryDayWindow != window { summaryDayWindow = window }
        // The window's middle, as a day and how far through it.
        let middle = window.lowerBound.addingTimeInterval(window.upperBound.timeIntervalSince(window.lowerBound) / 2)
        let through = middle.timeIntervalSince(dayStart(containing: middle)) / 86_400
        previewHeatmap(endingAt: middle, fraction: through - 0.5)
    }

    func previewSummary(periodOffset offset: Double, settling: Bool = false) {
        guard offset.isFinite else { return }
        if summaryIsSettling != settling { summaryIsSettling = settling }
        if summaryPeriodOffset != offset { summaryPeriodOffset = offset }
        let whole = offset.rounded()
        previewHeatmap(endingAt: day(-Int(whole), from: selectedDayStart), fraction: whole - offset)
    }

    /// Every write is skipped when it changes nothing: an observed property notifies its
    /// readers whenever it's set, equal or not, and this runs on every range switch and step.
    func clearHeatmapPreview() {
        if heatmapPreviewFraction != 0 { heatmapPreviewFraction = 0 }
        if heatmapPreviewEnd != nil { heatmapPreviewEnd = nil }
        if summaryDayWindow != nil { summaryDayWindow = nil }
        if summaryPeriodOffset != nil { summaryPeriodOffset = nil }
        if summaryIsSettling { summaryIsSettling = false }
    }

    /// The History tab's range. The selected day is the period's last day.
    var range: HistoryRange = .day {
        didSet {
            navigationRevision += 1
            if dayWindow != nil { dayWindow = nil }
            clearHeatmapPreview()
        }
    }

    // With `DESKPILOT_SIMULATE` set (see the menu bar app's `DeskModel.dataDirectory`) the files
    // live in the simulated scratch folder, so the dashboard can be exercised on a machine
    // with no desk and nothing of the user's.
    private let snapshotStore = DashboardModel.dataDirectory.map(SnapshotStore.init(directory:)) ?? SnapshotStore()
    private let historyStore = DashboardModel.dataDirectory.map(HistoryStore.init(directory:)) ?? HistoryStore()
    private let commandQueue = DashboardModel.dataDirectory.map(CommandQueue.init(directory:)) ?? CommandQueue()

    nonisolated static var dataDirectory: URL? {
        guard SimulatedTransport.scenarioFromEnvironment != nil else { return nil }
        if let path = ProcessInfo.processInfo.environment["DESKPILOT_DEV_DATA_DIRECTORY"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("tempo-simulated")
    }
    private let calendar = Calendar.current
    private var refreshTask: Task<Void, Never>?
    private var visibleWindows = 0
    @ObservationIgnored private var historyModificationDate: Date?
    @ObservationIgnored private var lastChartRefresh = Date.distantPast

    init() {
        let today = DayRollup.dayStart(now: Date(), middleOfNightHour: Self.defaultMiddleOfNightHour)
        selectedDayStart = today
        reload()
    }

    // MARK: - Lifecycle

    /// Balanced by `windowDisappeared()`. Counted rather than a flag so several windows (or a
    /// window being rebuilt during a scene update) can't leave polling switched off.
    func windowAppeared() {
        visibleWindows += 1
        guard refreshTask == nil else { return }
        reload()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.reload()
            }
        }
    }

    func windowDisappeared() {
        visibleWindows = max(0, visibleWindows - 1)
        guard visibleWindows == 0 else { return }
        refreshTask?.cancel()
        refreshTask = nil
    }

    // MARK: - Reading

    /// Keep controls responsive, but only decode changed history and redraw unchanged
    /// charts every 30 seconds. The service writes snapshots on change and history on
    /// revision change; rebuilding the full chart on every 2-second poll wastes CPU.
    func reload() {
        let current = Date()
        let incomingSnapshot = snapshotStore.read()
        if incomingSnapshot != snapshot { snapshot = incomingSnapshot }
        let attributes = try? FileManager.default.attributesOfItem(atPath: historyStore.fileURL.path)
        let modificationDate = attributes?[.modificationDate] as? Date
        let historyChanged = lastChartRefresh == .distantPast || modificationDate != historyModificationDate
        if historyChanged {
            history = historyStore.read()
            historyModificationDate = modificationDate
            nightWindow = history.map { NightWindow.usual(document: $0, now: current) }
        }
        guard historyChanged || current.timeIntervalSince(lastChartRefresh) >= 30 else { return }
        lastChartRefresh = current
        now = current

        // Follow the clock across a desk-day boundary.
        let today = todayStart
        if selectedDayStart > today { selectedDayStart = today }
        recompute()
    }

    private func recompute() {
        let events = history?.events ?? []
        let threshold = history?.standingThresholdInches
        firstDayStart = events.map(\.date).min().map {
            DayRollup.dayStart(now: $0, middleOfNightHour: middleOfNightHour, calendar: calendar)
        }
        let start = firstDayStart ?? todayStart
        timeline = PostureTimeline.segments(events: events, from: start, to: max(now, start),
                                            standingThresholdInches: threshold)
        columnCache = [:]
        trackCache = [:]
        recomputeHeatmap()
    }

    private func recomputeHeatmap() {
        heatmap = PostureTimeline.totals(events: history?.events ?? [],
                                         dayStarts: DashboardCharts.heatmapDayStarts(todayStart: todayStart, calendar: calendar),
                                         standingThresholdInches: history?.standingThresholdInches,
                                         now: now,
                                         calendar: calendar)
            .map { HeatmapDay(day: $0.day, atDesk: $0.standing + $0.sitting) }
    }

    // MARK: - Days

    /// The desk day `days` after `day` (before it, if negative).
    func day(_ days: Int, from day: Date) -> Date {
        calendar.date(byAdding: .day, value: days, to: day) ?? day.addingTimeInterval(86_400 * Double(days))
    }

    /// Whole desk days from `from` to `to`; by calendar date, so a daylight-saving change
    /// can't make a 23-hour day count as none.
    func days(from: Date, to: Date) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: from),
                                to: calendar.startOfDay(for: to)).day ?? 0
    }

    /// The desk day `date` falls in.
    func dayStart(containing date: Date) -> Date {
        DayRollup.dayStart(now: date, middleOfNightHour: middleOfNightHour, calendar: calendar)
    }

    /// The desk day starting at `dayStart`, cut out of `timeline`: the segments
    /// `PostureTimeline.segments` would walk for that day alone, except that two in the same
    /// posture either side of a zero-length blip are one, and stray visits at the day's edges
    /// are away; away wherever the history says nothing.
    private func segments(forDay dayStart: Date) -> [PostureSegment] {
        let end = DashboardCharts.dayEnd(dayStart: dayStart, now: now, calendar: calendar)
        guard end > dayStart else { return [] }
        var result: [PostureSegment] = []
        func append(_ start: Date, _ end: Date, _ state: PostureState) {
            guard end > start else { return }
            if let last = result.last, last.state == state, last.end == start {
                result[result.count - 1] = PostureSegment(start: last.start, end: end, state: state)
            } else {
                result.append(PostureSegment(start: start, end: end, state: state))
            }
        }
        // The first segment still running at the day's start.
        var low = 0
        var high = timeline.count
        while low < high {
            let middle = (low + high) / 2
            if timeline[middle].end <= dayStart { low = middle + 1 } else { high = middle }
        }
        var cursor = dayStart
        for segment in timeline[low...] {
            guard segment.start < end else { break }
            let start = max(segment.start, dayStart)
            append(cursor, start, .away)
            append(start, min(segment.end, end), segment.state)
            cursor = max(cursor, min(segment.end, end))
        }
        append(cursor, end, .away)
        // Stray visits at the day's edges (see `DeskDay`) are the sensor, not the day.
        let night = nightWindow ?? .around(middleOfNightHour: history?.middleOfNightHour ?? 4)
        return DeskDay.withoutStrays(result, openEnded: dayStart >= todayStart, night: night)
    }

    /// One day for the day chart.
    func track(for dayStart: Date) -> DayTrack {
        // Read even on a cache hit, so the view asking is redrawn when the history changes.
        _ = timeline
        if let cached = trackCache[dayStart] { return cached }
        let segments = segments(forDay: dayStart)
        let bounds = DashboardCharts.presenceBounds(segments)
        let isToday = dayStart >= todayStart
        let domain = DashboardCharts.timelineDomain(bounds: bounds,
                                                    dayStart: dayStart,
                                                    dayFullEnd: day(1, from: dayStart),
                                                    now: now,
                                                    isToday: isToday,
                                                    calendar: calendar)
        let track = DayTrack(dayStart: dayStart, segments: segments, bounds: bounds, domain: domain, isToday: isToday)
        trackCache[dayStart] = track
        return track
    }

    /// Every day touching `window`, oldest first, none past today.
    func tracks(overlapping window: ClosedRange<Date>) -> [DayTrack] {
        var day = dayStart(containing: window.lowerBound)
        let last = min(dayStart(containing: window.upperBound), todayStart)
        var tracks: [DayTrack] = []
        while day <= last {
            tracks.append(track(for: day))
            day = self.day(1, from: day)
        }
        return tracks
    }

    /// One day as a week or month column.
    func column(for dayStart: Date) -> DayColumn {
        _ = timeline
        if let cached = columnCache[dayStart] { return cached }
        let timeline = segments(forDay: dayStart)
        let spells = timeline.filter { $0.state != .away }
        let column = DayColumn(dayStart: dayStart,
                               key: DashboardCharts.dayKey(dayStart),
                               spells: spells,
                               atDesk: spells.reduce(0) { $0 + $1.duration },
                               standing: spells.filter { $0.state == .standing }.reduce(0) { $0 + $1.duration },
                               sitting: spells.filter { $0.state == .sitting }.reduce(0) { $0 + $1.duration },
                               breaks: DashboardCharts.breakAway(timeline, openEnded: dayStart >= todayStart))
        columnCache[dayStart] = column
        return column
    }

    /// The `count` days ending at `end`, oldest first, none past today.
    func columns(endingAt end: Date, count: Int) -> [DayColumn] {
        DashboardCharts.dayStarts(endingAt: end, count: count, calendar: calendar)
            .filter { $0 <= todayStart }
            .map(column(for:))
    }

    /// The selected day's stretch, or wherever the day chart came to rest.
    var restingDayWindow: ClosedRange<Date> {
        dayWindow ?? track(for: selectedDayStart).domain
    }

    /// Figures follow the visible window. Partially visible period columns contribute
    /// proportionally, so the average changes continuously while the chart slides.
    var ringFigures: RingFigures {
        guard range == .day else {
            let offset = summaryPeriodOffset ?? 0
            let whole = Int(floor(offset))
            let fraction = offset - Double(whole)
            let end = day(-whole, from: selectedDayStart)
            let visible = columns(endingAt: end, count: range.days + 1)
            let weighted = visible.enumerated().compactMap { index, column -> (DayColumn, Double)? in
                let weight = index == 0 ? fraction : index == visible.count - 1 ? 1 - fraction : 1
                return column.used && weight > 0 ? (column, weight) : nil
            }
            let totalWeight = weighted.reduce(0) { $0 + $1.1 }
            guard totalWeight > 0 else { return RingFigures() }
            func average(_ value: (DayColumn) -> TimeInterval) -> TimeInterval {
                weighted.reduce(0) { $0 + value($1.0) * $1.1 } / totalWeight
            }
            return RingFigures(atDesk: average(\.atDesk), standing: average(\.standing),
                               sitting: average(\.sitting), breaks: average(\.breaks))
        }
        let window = summaryDayWindow ?? restingDayWindow
        var figures = RingFigures()
        for track in tracks(overlapping: window) {
            for segment in track.drawn {
                let overlap = min(segment.end, window.upperBound).timeIntervalSince(max(segment.start, window.lowerBound))
                guard overlap > 0 else { continue }
                switch segment.state {
                case .standing: figures.standing += overlap
                case .sitting: figures.sitting += overlap
                case .away: figures.breaks += overlap
                }
            }
        }
        figures.atDesk = figures.standing + figures.sitting
        return figures
    }

    // MARK: - Derived state

    var middleOfNightHour: Int { history?.middleOfNightHour ?? Self.defaultMiddleOfNightHour }

    var todayStart: Date {
        DayRollup.dayStart(now: now, middleOfNightHour: middleOfNightHour, calendar: calendar)
    }

    var hasHistory: Bool { !(history?.events.isEmpty ?? true) }

    /// True once the menu bar app has written a snapshot recently enough to still be running.
    var menuBarAppIsRunning: Bool {
        guard let snapshot else { return false }
        return now.timeIntervalSince(snapshot.updatedAt) < DeskSnapshot.staleAfter
    }

    var deskIsConnected: Bool { menuBarAppIsRunning && snapshot?.connected == true }

    /// Settings writes are refused by the menu bar app unless the desk is settled.
    var canEditPresets: Bool { deskIsConnected && snapshot?.isMoving != true }

    // MARK: - Navigation

    var canGoForward: Bool { selectedDayStart < todayStart }

    /// Whether the period before this one has any history in it.
    var canGoBack: Bool {
        guard let previousEnd else { return false }
        return previousEnd >= (firstDayStart ?? todayStart)
    }

    /// The last day of the period before the selected one.
    private var previousEnd: Date? {
        calendar.date(byAdding: .day, value: -range.days, to: selectedDayStart)
    }

    /// The last day of the period after the selected one, never past today; nil on today.
    private var nextEnd: Date? {
        guard canGoForward else { return nil }
        return min(calendar.date(byAdding: .day, value: range.days, to: selectedDayStart) ?? selectedDayStart,
                   todayStart)
    }

    /// Steps back one period (a day, a week, a month).
    func goToPreviousDay() {
        if canGoBack, let previousEnd { select(previousEnd) }
    }

    func goToNextDay() {
        if let nextEnd { select(nextEnd) }
    }

    func goToToday() { select(todayStart) }

    func select(_ day: Date) {
        navigationRevision += 1
        clearHeatmapPreview()
        let day = min(day, todayStart)
        if selectedDayStart != day { selectedDayStart = day }
        if dayWindow != nil { dayWindow = nil }
    }

    /// The day chart has come to rest on `window`: the day under its middle becomes the
    /// selected one, without the chart jumping to that day's own stretch.
    func rest(dayWindowAt window: ClosedRange<Date>) {
        navigationRevision += 1
        clearHeatmapPreview()
        let middle = window.lowerBound.addingTimeInterval(window.upperBound.timeIntervalSince(window.lowerBound) / 2)
        let day = min(dayStart(containing: middle), todayStart)
        let today = track(for: todayStart).domain
        // Back at today's live edge, follow the clock again rather than stay pinned.
        let atLiveEdge = day == todayStart
            && abs(window.upperBound.timeIntervalSince(today.upperBound)) < 60
            && abs(window.upperBound.timeIntervalSince(window.lowerBound) - today.upperBound.timeIntervalSince(today.lowerBound)) < 60
        let resting = atLiveEdge ? nil : window
        if dayWindow != resting { dayWindow = resting }
        if day != selectedDayStart {
            selectedDayStart = day
        }
    }

    // MARK: - Commands

    /// Sends `command` to the menu bar app (`CommandQueue.send`: enqueue, nudge it awake,
    /// wait up to 15 s for its result file) and words the outcome for the settings sheet.
    func send(_ command: DeskCommand) async -> CommandOutcome {
        if let result = await commandQueue.send(command) {
            reload()
            return CommandOutcome(success: result.success,
                                  message: result.message ?? (result.success ? "Saved." : "That didn't work."))
        }
        // `send` has already withdrawn the command, so what we're about to report can't happen
        // minutes after the fact.
        return CommandOutcome(success: false,
                              message: menuBarAppIsRunning
                                  ? "The desk didn't answer. Try again in a moment."
                                  : "Deskpilot isn't running. Open it and try again.")
    }

    /// Brings the menu bar app to the front (it has no Dock icon, so this is how the user
    /// starts it from here). Prefers the installed copy, then whatever Launch Services knows.
    func openMenuBarApp() {
        let installedPath = "/Applications/Deskpilot.app"
        if FileManager.default.fileExists(atPath: installedPath) {
            NSWorkspace.shared.open(URL(fileURLWithPath: installedPath))
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.kevinpatel.tempo") {
            NSWorkspace.shared.open(url)
        }
    }
}
