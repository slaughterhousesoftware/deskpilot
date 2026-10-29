import Charts
import SwiftUI
import DeskpilotKit

/// A line at a column's left edge in the week or month chart.
enum DividerStyle { case dashed, solid }

/// One desk day as a column in the week or month chart.
struct DayColumn: Identifiable, Equatable {
    let dayStart: Date
    let key: String
    /// Standing and sitting spells only; away is the gap between them.
    let spells: [PostureSegment]
    let atDesk: TimeInterval
    let standing: TimeInterval
    let sitting: TimeInterval
    let breaks: TimeInterval
    var id: Date { dayStart }
    var used: Bool { atDesk > 0 }
}

/// A week or a month of desk days as vertical columns, the way a sleep app draws nights:
/// one column per day, the clock running down the column, standing and sitting as coloured
/// blocks at the hours they happened, and grey for the breaks between the day's first
/// arrival and its last moment at the desk.
///
/// The x axis is a plain number, columns from the first of `days`, so the window can sit
/// part-way through a column while it scrolls: only the columns, their lines and labels
/// move, under a frame and clock that stay put.
struct PeriodColumnsChart: View {
    /// The window's days and a few either side, oldest first.
    let days: [DayColumn]
    /// Where the window starts, in columns from the first of `days`; fractional mid-scroll.
    let visibleStart: Double
    let visibleCount: Int
    /// The clock's span, as negated hours into the day (see `hourDomain(for:nowMarker:)`).
    let hourDomain: ClosedRange<Double>
    /// Which columns get an x label, and what it says.
    let label: (DayColumn) -> String?
    /// The line at this column's left edge, if any: Health dashes its day (week) or week
    /// (month) lines and draws a solid one where a week (week) or month (month) begins.
    let divider: (DayColumn) -> DividerStyle?
    /// Whether the last column is closed by a dashed line at its right edge, as Health's week is.
    let closesLastColumn: Bool
    let barRatio: CGFloat
    /// The hour the desk day starts at (its middle-of-night hour), so the clock axis reads
    /// in real times of day.
    let dayStartHour: Int
    /// Current time, only supplied when today may be on screen.
    let nowMarker: Date?
    /// True while the content moves under a still pointer, so the callout can't name a column
    /// that has slid away from it.
    var isScrolling = false
    /// What `label` and `divider` depend on beyond the days themselves (the range, the label
    /// spacing, today), so two charts can be compared without comparing closures.
    var labelKey = ""
    /// The plot's width, for turning scrolled points into columns.
    var onPlotWidth: (CGFloat) -> Void = { _ in }
    let onSelect: (Date) -> Void

    private static let calendar = Calendar.current
    private var calendar: Calendar { Self.calendar }
    @Environment(\.colorScheme) private var colorScheme

    @State private var hover: Hover?
    /// The plot's height, for keeping clock labels clear of the time now's capsule.
    @State private var plotHeight: CGFloat = DashboardCharts.chartHeight
    /// The last column hovered, kept after the pointer leaves so the spotlight can fade out
    /// where it was.
    @State private var lastHover: Hover?

    private struct Hover: Equatable {
        let index: Int
        let day: DayColumn
    }

    /// Where a hovered day is now: its index can go stale if the days are rebuilt under a
    /// still pointer, its date can't.
    private func index(of hover: Hover) -> Int? {
        days.firstIndex { $0.dayStart == hover.day.dayStart }
    }

    var body: some View {
        // The same headroom as `DayTimelineChart`, with room for the clock's top label.
        chart
            .padding(.top, DashboardCharts.chartHeadroom)
            .onChange(of: isScrolling) { _, scrolling in
                if scrolling { hover = nil }
            }
            .onChange(of: hover) { old, new in HoverMotion.follow(old, new, last: &lastHover) }
    }

    /// Hours since the day started, negated so the morning is at the top of the chart.
    private static func plotHour(_ date: Date, in day: DayColumn) -> Double {
        -date.timeIntervalSince(day.dayStart) / 3600
    }

    private static func isCurrent(_ day: DayColumn, now: Date?) -> Bool {
        guard let now, let end = calendar.date(byAdding: .day, value: 1, to: day.dayStart) else { return false }
        return day.dayStart <= now && now < end
    }

    private func axisLabel(_ day: DayColumn) -> String? {
        label(day) ?? (Self.isCurrent(day, now: nowMarker)
            ? day.dayStart.formatted(.dateTime.month(.abbreviated).day()) : nil)
    }

    /// The span of the clock for these days: an hour of headroom around the earliest and
    /// latest spell, never narrower than eight hours. Worked out for the window at rest and
    /// held while it scrolls, so the clock doesn't twitch under the fingers.
    static func hourDomain(for days: [DayColumn], nowMarker: Date?) -> ClosedRange<Double> {
        var starts: [Double] = []
        var ends: [Double] = []
        for day in days {
            for spell in day.spells {
                starts.append(spell.start.timeIntervalSince(day.dayStart) / 3600)
                ends.append(spell.end.timeIntervalSince(day.dayStart) / 3600)
            }
        }
        if let nowMarker, let day = days.first(where: { isCurrent($0, now: nowMarker) }) {
            let hour = -plotHour(nowMarker, in: day)
            starts.append(hour)
            ends.append(hour)
        }
        guard let first = starts.min(), let last = ends.max() else { return -18 ... -5 }
        var lo = max(0, (first - 1).rounded(.down))
        var hi = min(24, (last + 1).rounded(.up))
        if hi - lo < 8 { hi = min(24, lo + 8) }
        if hi - lo < 8 { lo = max(0, hi - 8) }
        return -hi ... -lo
    }

    /// Where column `index`'s left edge falls, in the chart's coordinates.
    private func leftEdge(_ index: Int, plot: CGRect) -> CGFloat {
        plot.minX + CGFloat(Double(index) - visibleStart) * plot.width / CGFloat(visibleCount)
    }

    private var chart: some View {
        // No marks of its own: the chart supplies the scales, the clock and the plot frame,
        // and the columns are drawn into its background where they can be slid and clipped.
        Chart {
        }
        .chartXScale(domain: visibleStart ... visibleStart + Double(visibleCount))
        .chartYScale(domain: hourDomain)
        .chartXAxis {
            // Room for the labels only: `columnLines` draws them, beside the lines at the
            // columns' left edges.
            AxisMarks(values: [visibleStart]) { _ in
                AxisValueLabel(verticalSpacing: 1) {
                    Text("Mon").font(.caption).hidden()
                }
            }
        }
        .chartYAxis {
            // Health's clock: a solid light rule every two hours, labelled on the right.
            AxisMarks(position: .trailing, values: .stride(by: 2)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                    .foregroundStyle(DashboardCharts.ruleColor)
                if let hour = value.as(Double.self), !nearNowCapsule(hour) {
                    // Snug against the plot, as Health sets them, in a column as wide as the time
                    // now's capsule at its widest, the same on every page.
                    AxisValueLabel(horizontalSpacing: Self.clockSpacing) {
                        Text(clock(-hour)).font(.caption).foregroundStyle(.secondary)
                            .fixedSize()
                            .frame(width: Self.clockWidth, alignment: .leading)
                    }
                }
            }
        }
        .chartPlotStyle { plot in
            plot
                .overlay(alignment: .bottom) { Rectangle().fill(DashboardCharts.ruleColor).frame(height: 1) }
                .overlay(alignment: .leading) { Rectangle().fill(DashboardCharts.ruleColor).frame(width: 1) }
        }
        .chartBackground { proxy in
            GeometryReader { geometry in
                if let plotFrame = proxy.plotFrame {
                    let plot = geometry[plotFrame]
                    columnLines(plot: plot, size: geometry.size)
                        .onChange(of: plot.width, initial: true) { _, width in onPlotWidth(width) }
                        .onChange(of: plot.height, initial: true) { _, height in plotHeight = height }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let plotFrame = proxy.plotFrame {
                    // Over the clock's rules, as marks would be.
                    columns(proxy: proxy, plot: geometry[plotFrame])
                        .mask(alignment: .topLeading) {
                            SpotlightMask(focus: lastHover.flatMap(index(of:)).map { columnRect($0, plot: geometry[plotFrame]) },
                                          active: hover?.day.used == true, cornerRadius: 3)
                        }
                    currentTimeMarker(proxy: proxy, plot: geometry[plotFrame])
                    // Days with desk time only: an empty day has nothing to say.
                    let shown = hover.flatMap { hover in hover.day.used ? index(of: hover).map { (hover.day, $0) } : nil }
                    let plot = geometry[plotFrame]
                    GlassPopover(anchor: shown.map { dayRect($0.1, proxy: proxy, plot: plot) },
                                 bounds: plot, sides: [.trailing, .leading, .top, .bottom],
                                 obstacles: shown.map { shown in
                                     days.indices.filter { $0 != shown.1 && days[$0].used }
                                         .map { dayRect($0, proxy: proxy, plot: plot) }
                                         .filter { $0.intersects(plot) }
                                 } ?? []) {
                        if let day = shown?.0 ?? lastHover?.day {
                            DayCallout(day: day.dayStart, atDesk: day.atDesk, split: (day.standing, day.sitting))
                        }
                    }
                }
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        // A capture's pretend pointer stands in for the real one.
                        guard DashboardSnapshot.devHover == nil else { return }
                        switch phase {
                        case .active(let point):
                            hover = isScrolling ? nil : hoverInfo(at: point, proxy: proxy, geometry: geometry)
                        case .ended:
                            hover = nil
                        }
                    }
                    .task(id: [geometry.size.width, geometry.size.height, visibleStart, days.first?.dayStart.timeIntervalSince1970 ?? 0]) {
                        guard let seed = DashboardSnapshot.devHover, let plotFrame = proxy.plotFrame else { return }
                        let plot = geometry[plotFrame]
                        hover = hoverInfo(at: CGPoint(x: plot.minX + plot.width * seed.x, y: plot.minY + plot.height * seed.y),
                                          proxy: proxy, geometry: geometry)
                    }
                    .onTapGesture { location in
                        if let day = hoverInfo(at: location, proxy: proxy, geometry: geometry)?.day {
                            onSelect(day.dayStart)
                        }
                    }
            }
        }
        .frame(height: DashboardCharts.chartHeight)
        .accessibilityLabel("Desk days")
    }

    /// The columns, clipped to the plot. The working day in grey underneath, so a break
    /// shows as grey between the stretches at the desk; each unbroken stretch at the desk as
    /// one rounded column; and the spells painted over it square-cornered and slightly
    /// overlapping, so a column reads as one piece with no hairlines between sitting and
    /// standing.
    private func columns(proxy: ChartProxy, plot: CGRect) -> some View {
        let palette = ColumnPalette(breaks: PostureStyle.breakColor(colorScheme),
                                    sitting: PostureStyle.color(.sitting), standing: PostureStyle.color(.standing))
        return Canvas(rendersAsynchronously: true) { context, _ in
            context.clip(to: Path(plot))
            let band = plot.width / CGFloat(visibleCount)
            let width = band * barRatio
            for (index, day) in days.enumerated() {
                let left = leftEdge(index, plot: plot) + (band - width) / 2
                guard left + width > plot.minX, left < plot.maxX else { continue }
                Self.drawColumn(day, left: left, width: width, in: &context, proxy: proxy, plot: plot, palette: palette)
            }
        }
        .allowsHitTesting(false)
    }

    private struct ColumnPalette {
        let breaks: Color
        let sitting: Color
        let standing: Color
    }

    /// One day's column: the working day in grey underneath, so a break shows as grey
    /// between the stretches at the desk; each unbroken stretch at the desk painted solid, and
    /// the spells over it slightly overlapping, so a column reads as one piece with no
    /// hairlines between sitting and standing. Square-cornered throughout.
    private static func drawColumn(_ day: DayColumn, left: CGFloat, width: CGFloat, in context: inout GraphicsContext,
                                   proxy: ChartProxy, plot: CGRect, palette: ColumnPalette) {
        // Sides on whole pixels: a side partway across one draws it half-covered, and the
        // layers stacked on a coloured band (grey, the stretch, the spell) would add up to a
        // nearly solid pixel there and only a faint one beside grey - coloured bands looking
        // half a pixel wider each side than the breaks between them.
        let scale = max(1, context.environment.displayScale)
        let right = ((left + width) * scale).rounded() / scale
        let left = (left * scale).rounded() / scale
        let width = right - left
        func rect(from top: Double, to bottom: Double) -> CGRect? {
            guard let y0 = proxy.position(forY: top), let y1 = proxy.position(forY: bottom) else { return nil }
            return CGRect(x: left, y: plot.minY + min(y0, y1), width: width, height: abs(y1 - y0))
        }
        guard let first = day.spells.first?.start, let last = day.spells.last?.end,
              let frame = rect(from: plotHour(first, in: day), to: plotHour(last, in: day)) else { return }
        context.fill(Path(frame), with: .color(palette.breaks))
        for stretch in DashboardCharts.stretches(day.spells) {
            if let frame = rect(from: plotHour(stretch.lowerBound, in: day), to: plotHour(stretch.upperBound, in: day)) {
                context.fill(Path(frame), with: .color(palette.sitting))
            }
        }
        for spell in day.spells {
            if let frame = rect(from: plotHour(spell.start, in: day) + 0.01, to: plotHour(spell.end, in: day) - 0.01) {
                context.fill(Path(frame), with: .color(spell.state == .standing ? palette.standing : palette.sitting))
            }
        }
    }

    /// The columns' left-edge lines, down to the baseline, and each day's label centred under
    /// its column. Cut off at the plot's edges as they slide past them.
    private func columnLines(plot: CGRect, size: CGSize) -> some View {
        let bottom = plot.maxY
        let band = plot.width / CGFloat(visibleCount)
        var dashed = Path()
        var solid = Path()
        func line(at x: CGFloat) -> Path {
            Path { $0.move(to: CGPoint(x: x, y: plot.minY)); $0.addLine(to: CGPoint(x: x, y: bottom)) }
        }
        // (Not over the plot's solid left edge.)
        for (index, day) in days.enumerated() {
            guard let style = divider(day) else { continue }
            let x = leftEdge(index, plot: plot).rounded()
            guard x > plot.minX + 0.5, x < plot.maxX + 0.5 else { continue }
            if style == .solid { solid.addPath(line(at: x)) } else { dashed.addPath(line(at: x)) }
        }
        if closesLastColumn, !days.isEmpty {
            let x = (leftEdge(days.count - 1, plot: plot) + band).rounded()
            if x > plot.minX + 0.5, x < plot.maxX + 0.5 { dashed.addPath(line(at: x)) }
        }
        return ZStack(alignment: .topLeading) {
            dashed.stroke(DashboardCharts.ruleColor, style: DashboardCharts.hourStroke)
            solid.stroke(DashboardCharts.ruleColor, style: StrokeStyle(lineWidth: 1))
            ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                let x = leftEdge(index, plot: plot)
                if x + band > plot.minX, x < plot.maxX, let text = axisLabel(day) {
                    let isToday = Self.isCurrent(day, now: nowMarker)
                    // Today's, wider than a month's column, ends at its column's right edge
                    // rather than running on under the clock - the same place whether the
                    // chart is still or sliding, so it never jumps. A frame wide enough for any
                    // label, holding it at its right end, puts it there.
                    let slot: CGFloat = 80
                    let fitsColumn = band >= 40
                    // A weight up from the hour labels: these name the columns, and at caption
                    // size the regular face looked thin - the red one most of all.
                    Text(text)
                        .font(.caption.weight(isToday ? .semibold : .medium))
                        .foregroundStyle(isToday ? Color.red : Color.secondary)
                        .fixedSize()
                        .frame(width: slot, alignment: isToday && !fitsColumn ? .trailing : .leading)
                        .offset(x: isToday && !fitsColumn ? x + band - slot - 1 : labelLeft(text, column: x, band: band, plot: plot),
                                y: plot.maxY + 1)
                        .help(day.dayStart.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Clipped at both of the plot's edges alike, so a day's line and label slide in and out
        // together instead of a label turning up ahead of its column.
        .mask(alignment: .topLeading) {
            Rectangle()
                .frame(width: plot.width + 1, height: size.height)
                .offset(x: plot.minX)
        }
        .allowsHitTesting(false)
    }

    /// A day label's left edge: centred under its column, but kept inside the plot while its
    /// column is - it stops at the edge as the column reaches it, then goes on out with the
    /// column, so nothing jumps as the chart slides.
    private func labelLeft(_ text: String, column x: CGFloat, band: CGFloat, plot: CGRect) -> CGFloat {
        let width = ceil((text as NSString).size(withAttributes: [.font: Self.labelFont]).width)
        let centred = x + (band - width) / 2
        let right = max(plot.maxX, x + band) - width
        let left = min(plot.minX, x)
        return min(max(centred, left), right)
    }
    private static let labelFont = NSFont.systemFont(
        ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .semibold)

    /// The time now on its capsule, in the locale's own clock: "10:18 AM", as the day chart
    /// and the menu's strip show it.
    private static func nowText(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
    private static let nowFontSize: CGFloat = 10
    private static let nowFont = Font.system(size: nowFontSize, weight: .semibold).monospacedDigit()
    private static let nowNSFont = NSFont.monospacedDigitSystemFont(ofSize: nowFontSize, weight: .semibold)
    private static let nowPadding: CGFloat = 4
    /// The clock's column: as wide as the capsule at its widest (or an hour label, if wider),
    /// and its gap from the plot.
    private static let clockWidth: CGFloat = {
        let calendar = Calendar.current
        let widestNow = [(22, 59), (12, 59), (23, 59)]
            .compactMap { calendar.date(bySettingHour: $0.0, minute: $0.1, second: 0, of: Date()) }
            .map { (nowText($0) as NSString).size(withAttributes: [.font: nowNSFont]).width }
            .max() ?? 45
        // The capsule's leading padding reaches back into the gap before the column.
        return ceil(max(widestNow + nowPadding, widestClockLabel))
    }()
    private static let clockSpacing: CGFloat = 6
    /// The clock's widest hour label, where the capsule lines up its end.
    private static let widestClockLabel: CGFloat = {
        let calendar = Calendar.current
        return [10, 12, 22, 0].compactMap { calendar.date(bySettingHour: $0, minute: 0, second: 0, of: Date()) }
            .map { ceil(($0.formatted(.dateTime.hour()) as NSString).size(withAttributes: [.font: labelFont]).width) }.max() ?? 30
    }()

    /// Where today's time-now capsule sits on the clock, as a plot hour, while today's column
    /// reaches the clock (the only time the capsule shows).
    private var nowCapsuleHour: Double? {
        guard let nowMarker, let index = days.firstIndex(where: { Self.isCurrent($0, now: nowMarker) }),
              index == days.count - 1 else { return nil }
        return Self.plotHour(nowMarker, in: days[index])
    }

    private static let nowHeight: Double = 15
    /// Half a clock label's figures, top to bottom: what the capsule has to keep clear of.
    private static let labelHalfHeight = Double(NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize).capHeight) / 2
    private static let nowLabelGap: Double = 2

    /// Where the capsule's middle sits, as a plot hour: on now, or up to 4 pt off it (the line
    /// still meets its rounded end squarely) if that leaves more clock labels showing.
    private var nowCapsuleCentre: Double? {
        guard let now = nowCapsuleHour else { return nil }
        let span = hourDomain.upperBound - hourDomain.lowerBound
        guard span > 0, plotHeight > 0 else { return now }
        let scale = Double(plotHeight) / span
        // The clock's labels, every two hours.
        let labels = stride(from: (hourDomain.lowerBound / 2).rounded(.up) * 2, through: hourDomain.upperBound, by: 2).map {
            StripAxisLayout.Span(left: $0 * scale - Self.labelHalfHeight, right: $0 * scale + Self.labelHalfHeight)
        }
        let centre = StripAxisLayout.nowCentre(now: now * scale, half: Self.nowHeight / 2, maxShift: 4,
                                               labels: labels, gap: Self.nowLabelGap)
        return centre / scale
    }

    /// A clock label the capsule would touch: its figures within the capsule's height and a
    /// little room.
    private func nearNowCapsule(_ hour: Double) -> Bool {
        guard let centre = nowCapsuleCentre else { return false }
        let span = hourDomain.upperBound - hourDomain.lowerBound
        guard span > 0, plotHeight > 0 else { return false }
        return abs(hour - centre) * Double(plotHeight) / span < Self.nowHeight / 2 + Self.labelHalfHeight + Self.nowLabelGap
    }

    /// Calendar's solid red current-time rule spans today's column, and runs on to a red
    /// capsule on the clock holding the time, as Calendar's week view and the menu's strip
    /// mark now; clock labels it would touch step aside.
    @ViewBuilder private func currentTimeMarker(proxy: ChartProxy, plot: CGRect) -> some View {
        if let nowMarker, let index = days.firstIndex(where: { Self.isCurrent($0, now: nowMarker) }),
           let yPosition = proxy.position(forY: Self.plotHour(nowMarker, in: days[index])) {
            let band = plot.width / CGFloat(visibleCount)
            let edge = leftEdge(index, plot: plot)
            // The week's rule spans today's band, its dot just before it, as Calendar's. A
            // month's bands are narrow and their gutters wide, where that put the dot in the
            // gap, touching the day before: there it starts at the bar's own left edge.
            let wide = band >= 40
            let start = wide ? edge : edge + band * (1 - barRatio) / 2
            let left = max(plot.minX, start)
            let right = min(plot.maxX, edge + band)
            let y = min(plot.maxY, max(plot.minY, plot.minY + yPosition))
            if right > left {
                ZStack(alignment: .topLeading) {
                    Path { path in
                        path.move(to: CGPoint(x: left, y: y))
                        path.addLine(to: CGPoint(x: right, y: y))
                    }
                    .stroke(Color.red, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    // Calendar's dot where the line enters today's column.
                    if start >= plot.minX {
                        Circle().fill(Color.red).frame(width: 6, height: 6)
                            .position(x: wide ? left - 3 : left, y: y)
                    }
                    if edge + band <= plot.maxX + 0.5 {
                        // Its time starts where the hours do, its padding reaching back into the
                        // gap before them.
                        let text = Self.nowText(nowMarker)
                        let capsuleWidth = ceil((text as NSString).size(withAttributes: [.font: Self.nowNSFont]).width) + 2 * Self.nowPadding
                        let capsuleLeft = plot.maxX + Self.clockSpacing - Self.nowPadding
                        let capsuleY = nowCapsuleCentre.flatMap { proxy.position(forY: $0) }.map { plot.minY + $0 } ?? y
                        // On into the capsule, under it, so it meets the rounded end wherever
                        // the capsule has moved to.
                        Path { path in
                            path.move(to: CGPoint(x: right, y: y))
                            path.addLine(to: CGPoint(x: capsuleLeft + Self.nowHeight / 2, y: y))
                        }
                        .stroke(Color.red, style: StrokeStyle(lineWidth: 2))
                        Text(text)
                            .font(Self.nowFont)
                            .foregroundStyle(.white)
                            .fixedSize()
                            .padding(.horizontal, Self.nowPadding)
                            .frame(height: Self.nowHeight)
                            .background(Capsule().fill(Color.red))
                            .fixedSize()
                            .alignmentGuide(.leading) { _ in 0 }
                            .offset(x: capsuleLeft, y: capsuleY - Self.nowHeight / 2)
                    }
                }
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Today, now: \(nowMarker.formatted(date: .omitted, time: .shortened))")
            }
        }
    }

    /// Column `index`'s drawn part - its first arrival to its last moment at the desk - or, for a
    /// day without any, its band's middle.
    private func dayRect(_ index: Int, proxy: ChartProxy, plot: CGRect) -> CGRect {
        let day = days[index]
        let band = plot.width / CGFloat(visibleCount)
        let width = band * barRatio
        let left = leftEdge(index, plot: plot) + (band - width) / 2
        guard let first = day.spells.first?.start, let last = day.spells.last?.end,
              let y0 = proxy.position(forY: Self.plotHour(first, in: day)),
              let y1 = proxy.position(forY: Self.plotHour(last, in: day)) else {
            return CGRect(x: left, y: plot.midY, width: width, height: 0)
        }
        return CGRect(x: left, y: plot.minY + min(y0, y1), width: width, height: abs(y1 - y0))
    }

    /// Column `index`'s whole band, top to bottom of the plot.
    private func columnRect(_ index: Int, plot: CGRect) -> CGRect {
        let band = plot.width / CGFloat(visibleCount)
        return CGRect(x: leftEdge(index, plot: plot), y: plot.minY - 4, width: band, height: plot.height + 8)
    }

    /// "7 AM" for a number of hours past the desk day's start.
    private func clock(_ hoursIntoDay: Double) -> String {
        let hour = (dayStartHour + Int(hoursIntoDay.rounded())) % 24
        let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(.dateTime.hour())
    }

    private func hoverInfo(at point: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> Hover? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let plot = geometry[plotFrame]
        guard plot.contains(point) else { return nil }
        let column = visibleStart + Double((point.x - plot.minX) / plot.width) * Double(visibleCount)
        let index = Int(column.rounded(.down))
        guard days.indices.contains(index) else { return nil }
        return Hover(index: index, day: days[index])
    }
}

/// Compared by what it draws, not by its closures, so a parent redrawing for other reasons
/// (a range switch, a step elsewhere) doesn't rebuild the chart when nothing in it changed.
extension PeriodColumnsChart: Equatable {
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.days == b.days && a.visibleStart == b.visibleStart && a.visibleCount == b.visibleCount
            && a.hourDomain == b.hourDomain && a.closesLastColumn == b.closesLastColumn && a.barRatio == b.barRatio
            && a.dayStartHour == b.dayStartHour && a.nowMarker == b.nowMarker && a.isScrolling == b.isScrolling
            && a.labelKey == b.labelKey
    }
}
