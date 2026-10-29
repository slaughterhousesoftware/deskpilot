import SwiftUI
import DeskpilotKit

/// One square of the heatmap: a desk day and how long the desk was in use.
struct HeatmapDay: Identifiable, Equatable {
    let day: Date
    let atDesk: TimeInterval
    var id: Date { day }
}

/// A year of desk days as a GitHub-style grid: one square per day, weeks as columns,
/// the deeper the blue the longer the desk was in use that day (relative to the best day in
/// the grid). Hover for the day's number; click to end the current chart period on that day.
struct DeskHeatmap: View, Animatable {
    let days: [HeatmapDay]
    /// Every desk day shown in the chart above, including the current scroll preview.
    let selectedDays: ClosedRange<Date>
    let onSelect: (Date) -> Void
    /// Where the gold run ends, in squares from the grid's first: the selected days' last,
    /// carried part of the way to the next while a scroll is between days. Animatable, so the
    /// gold slides from square to square rather than jumping.
    private var selectionEnd: Double

    /// Larger cells keep the full year legible within the 640-point dashboard.
    private let cell: CGFloat
    private let showWeekdayLabels: Bool
    private var weekdayGutter: CGFloat { showWeekdayLabels ? 32 : 0 }
    private static let gap: CGFloat = 2
    private let calendar = Calendar.current

    @State private var hover: Hover?
    /// The last square hovered, kept after the pointer leaves so the spotlight can fade out
    /// where it was.
    @State private var lastHover: Hover?
    private struct Hover: Equatable {
        let day: HeatmapDay
        let column: Int
        let row: Int
    }


    // Worked out once per value rather than per square: the grid redraws on every frame of a
    // scroll (the gold run slides), so nothing per square may touch the calendar.
    private let maxAtDesk: TimeInterval
    private let firstWeekStart: Date
    /// Squares from the first week's start to `days[0]`: the days run on consecutively from
    /// there, so day `i` is square `firstOffset + i`, in column `/ 7`, row `% 7`.
    private let firstOffset: Int
    /// How many days the gold run covers.
    private let selectionLength: Double

    /// `fitWidth`, when given, sizes the squares so the whole grid, weekday labels and all, is
    /// exactly that wide; otherwise they're `cellSize`.
    init(days: [HeatmapDay], selectedDays: ClosedRange<Date>, selectionFraction: Double = 0,
         onSelect: @escaping (Date) -> Void, cellSize: CGFloat = 8, fitWidth: CGFloat? = nil,
         showWeekdayLabels: Bool = true) {
        self.showWeekdayLabels = showWeekdayLabels
        self.days = days
        self.selectedDays = selectedDays
        self.onSelect = onSelect
        maxAtDesk = days.map(\.atDesk).max() ?? 0
        if let first = days.first?.day {
            firstWeekStart = Calendar.current.dateInterval(of: .weekOfYear, for: first)?.start ?? first
        } else {
            firstWeekStart = Date()
        }
        let firstWeek = firstWeekStart
        let lastWeekStart = days.last.flatMap { Calendar.current.dateInterval(of: .weekOfYear, for: $0.day)?.start }
        let columns = lastWeekStart.flatMap {
            Calendar.current.dateComponents([.weekOfYear], from: firstWeek, to: $0).weekOfYear
        }.map { $0 + 1 } ?? 0
        let gutter: CGFloat = showWeekdayLabels ? 32 : 0
        if let fitWidth, columns > 0 {
            cell = max(4, (fitWidth - 4 - gutter + Self.gap) / CGFloat(columns) - Self.gap)
        } else {
            cell = cellSize
        }
        let endIndex = Calendar.current.dateComponents([.day], from: firstWeekStart,
                                                       to: Calendar.current.startOfDay(for: selectedDays.upperBound)).day ?? 0
        selectionEnd = Double(endIndex) + selectionFraction
        firstOffset = days.first.map {
            Calendar.current.dateComponents([.day], from: firstWeek, to: Calendar.current.startOfDay(for: $0.day)).day ?? 0
        } ?? 0
        selectionLength = Double((Calendar.current.dateComponents([.day], from: selectedDays.lowerBound,
                                                                  to: selectedDays.upperBound).day ?? 0) + 1)
    }

    var animatableData: Double {
        get { selectionEnd }
        set { selectionEnd = newValue }
    }

    /// How much of square `index` the gold run covers, 0 to 1.
    private func selectionWeight(_ index: Int) -> Double {
        let lo = selectionEnd - selectionLength + 0.5, hi = selectionEnd + 0.5
        return min(1, max(0, min(hi, Double(index) + 0.5) - max(lo, Double(index) - 0.5)))
    }
    private var columnCount: Int {
        days.isEmpty ? 0 : (firstOffset + days.count - 1) / 7 + 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: showWeekdayLabels ? 3 : 6) {
                monthLabels.padding(.leading, weekdayGutter)
                HStack(alignment: .top, spacing: showWeekdayLabels ? 6 : 0) {
                    if showWeekdayLabels { weekdayLabels }
                    grid
                }
            }
            .padding(2)

        }
        .frame(width: max(0, CGFloat(columnCount) * (cell + Self.gap) - Self.gap) + 4 + weekdayGutter)
        .onChange(of: selectedDays) { _, _ in
            hover = nil
            seedDevHover()
        }
        .onAppear(perform: seedDevHover)
        .onChange(of: hover) { old, new in HoverMotion.follow(old, new, last: &lastHover) }
    }

    // MARK: - Pieces

    private var weekdayLabels: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<7, id: \.self) { row in
                let date = calendar.date(byAdding: .day, value: row, to: firstWeekStart)!
                let weekday = calendar.component(.weekday, from: date)
                if [2, 4, 6].contains(weekday) {
                    Text(date.formatted(.dateTime.weekday(.abbreviated)))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .frame(width: 26, alignment: .leading)
                        .position(x: 13, y: CGFloat(row) * (cell + Self.gap) + cell / 2)
                }
            }
        }
        .frame(width: 26, height: 7 * cell + 6 * Self.gap)
    }

    /// The squares, drawn as one canvas rather than a view each: the gold run slides on every
    /// frame of a scroll, and ~371 views redrawn that often were most of the frame. Hover and
    /// clicks find their square from the pointer.
    private var grid: some View {
        let step = cell + Self.gap
        let size = CGSize(width: max(0, CGFloat(columnCount) * step - Self.gap), height: 7 * step - Self.gap)
        let base = (0...4).map { Self.color(level: $0) }
        let gold = (0...4).map(Self.goldColor(level:))
        return Canvas(rendersAsynchronously: true) { context, _ in
            for (index, day) in days.enumerated() {
                let square = firstOffset + index
                let rect = CGRect(x: CGFloat(square / 7) * step, y: CGFloat(square % 7) * step, width: cell, height: cell)
                let path = Path(roundedRect: rect, cornerRadius: 1.5, style: .continuous)
                let level = min(max(level(of: day), 0), 4)
                let weight = selectionWeight(square)
                if weight < 1 { context.fill(path, with: .color(base[level].opacity(1 - weight))) }
                if weight > 0 { context.fill(path, with: .color(gold[level].opacity(weight))) }
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            // A visual capture represents the resting view, regardless of the desktop pointer.
            guard !DashboardSnapshot.capturesNativeWindow else { return }
            switch phase {
            case .active(let point): hover = square(at: point)
            case .ended: hover = nil
            }
        }
        .gesture(SpatialTapGesture().onEnded { value in
            guard let square = square(at: value.location) else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                hover = nil
                onSelect(square.day.day)
            }
        })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Desk use, past year")
        .accessibilityValue(accessibilitySummary)
        .accessibilityAddTraits(.isButton)
        .mask(alignment: .topLeading) {
            SpotlightMask(focus: lastHover.map { hover in
                              CGRect(x: CGFloat(hover.column) * step, y: CGFloat(hover.row) * step,
                                     width: cell, height: cell).insetBy(dx: -1, dy: -1)
                          },
                          active: hover != nil, cornerRadius: 2.5)
        }
        .overlay(alignment: .topLeading) {
            if let hover { hoverMarker(hover) }
        }
        .overlay(alignment: .topLeading) {
            GeometryReader { geometry in
                // Above its square, free to rise over the month labels and out of the grid.
                // Days with desk time only.
                GlassPopover(anchor: hover.flatMap { $0.day.atDesk > 0 ? CGRect(x: CGFloat($0.column) * step, y: CGFloat($0.row) * step,
                                                                                width: cell, height: cell) : nil },
                             bounds: CGRect(x: 0, y: -400, width: geometry.size.width, height: 400 + geometry.size.height),
                             sides: [.top]) {
                    if let day = (hover ?? lastHover)?.day { DayCallout(day: day.day, atDesk: day.atDesk) }
                }
            }
        }
    }

    /// The square under `point` in the grid, if it's a day's (not a gap, or past the days).
    private func square(at point: CGPoint) -> Hover? {
        let step = cell + Self.gap
        guard point.x >= 0, point.y >= 0 else { return nil }
        let column = Int(point.x / step), row = Int(point.y / step)
        guard row < 7, point.x - CGFloat(column) * step <= cell, point.y - CGFloat(row) * step <= cell else { return nil }
        let index = column * 7 + row - firstOffset
        guard days.indices.contains(index) else { return nil }
        return Hover(day: days[index], column: column, row: row)
    }

    /// The selected days, for VoiceOver.
    private var accessibilitySummary: String {
        let shown = days.filter { selectedDays.contains($0.day) }
        let total = shown.reduce(0) { $0 + $1.atDesk }
        guard let first = shown.first?.day, let last = shown.last?.day else { return "" }
        let span = first == last ? first.formatted(.dateTime.month(.wide).day())
            : "\(first.formatted(.dateTime.month(.wide).day())) to \(last.formatted(.dateTime.month(.wide).day()))"
        return "\(span), \(Formatting.duration(total)) at desk"
    }

    /// A ring round the hovered square, so it can be found among the rest at a glance.
    private func hoverMarker(_ hover: Hover) -> some View {
        let step = cell + Self.gap
        return RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.85), lineWidth: 1.5)
            .frame(width: cell + 3, height: cell + 3)
            .offset(x: CGFloat(hover.column) * step - 1.5, y: CGFloat(hover.row) * step - 1.5)
            .allowsHitTesting(false)
    }

    /// Month names over the column where each month begins - a dozen labels, not a slot for
    /// every column, worked out once per grid and remembered.
    private var monthLabels: some View {
        let step = cell + Self.gap
        return ZStack(alignment: .topLeading) {
            ForEach(Self.monthStarts(firstWeekStart: firstWeekStart, columns: columnCount, cell: cell), id: \.column) { month in
                Text(month.label)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .offset(x: CGFloat(month.column) * step)
            }
        }
        .frame(width: max(0, CGFloat(columnCount) * step - Self.gap), height: showWeekdayLabels ? 14 : 18, alignment: .topLeading)
    }

    private struct MonthStart { let column: Int; let label: String }
    @MainActor private static var monthStartCache: [String: [MonthStart]] = [:]

    /// The columns where a month begins and its name fits before the next one's.
    @MainActor private static func monthStarts(firstWeekStart: Date, columns: Int, cell: CGFloat) -> [MonthStart] {
        let key = "\(firstWeekStart.timeIntervalSince1970) \(columns) \(cell)"
        if let cached = monthStartCache[key] { return cached }
        let calendar = Calendar.current
        let months = (0..<columns).map { column in
            calendar.component(.month, from: calendar.date(byAdding: .day, value: column * 7, to: firstWeekStart) ?? firstWeekStart)
        }
        let font = NSFont.systemFont(ofSize: 11, weight: .regular)
        var result: [MonthStart] = []
        for column in 0..<columns where column == 0 || months[column - 1] != months[column] {
            let next = ((column + 1)..<columns).first { months[$0] != months[column] } ?? columns
            let start = calendar.date(byAdding: .day, value: column * 7, to: firstWeekStart) ?? firstWeekStart
            let label = start.formatted(.dateTime.month(.abbreviated))
            let available = CGFloat(next - column) * (cell + gap) - gap
            if (label as NSString).size(withAttributes: [.font: font]).width <= available {
                result.append(MonthStart(column: column, label: label))
            }
        }
        monthStartCache[key] = result
        return result
    }

    // MARK: - Helpers

    /// A native capture's pretend pointer (see `DashboardSnapshot.devHover`), with
    /// `DESKPILOT_DEV_HOVER_HEATMAP=1`, so it doesn't compete with the chart's for the summary.
    private func seedDevHover() {
        guard let seed = DashboardSnapshot.devHover, !days.isEmpty,
              ProcessInfo.processInfo.environment["DESKPILOT_DEV_HOVER_HEATMAP"] == "1" else { return }
        let day = days[min(days.count - 1, Int(Double(days.count) * seed.x))]
        let index = days.firstIndex(of: day).map { $0 + firstOffset } ?? 0
        hover = Hover(day: day, column: index / 7, row: index % 7)
    }

    private func level(of day: HeatmapDay) -> Int {
        DashboardCharts.heatLevel(atDesk: day.atDesk, max: maxAtDesk)
    }

    /// A selected square's gold, deeper the longer the desk was in use.
    private static func goldColor(level: Int) -> Color {
        let intensity = [0.30, 0.50, 0.68, 0.85, 1.0][min(max(level, 0), 4)]
        return DeskpilotAppearance.heatmapSelection.opacity(intensity)
    }

    /// Five steps from "not used" to "the best day in the grid".
    static func color(level: Int) -> Color {
        switch level {
        case 0: return Color.gray.opacity(0.22)
        case 1: return DeskpilotAppearance.sitting.opacity(0.3)
        case 2: return DeskpilotAppearance.sitting.opacity(0.55)
        case 3: return DeskpilotAppearance.sitting.opacity(0.8)
        default: return DeskpilotAppearance.sitting
        }
    }
}
