import Charts
import SwiftUI
import DeskpilotKit

/// A stretch of the desk's days as a stepped chart, the way a sleep chart shows its stages:
/// standing on the top row, sitting under it and breaks away from the desk in grey at the
/// bottom, like the sleep card's Awake row, with a connector at every change (drawn by
/// `SleepCardPainter`, the construction recovered from Apple's own card). Time before a day's
/// first arrival and after its last moment at the desk is left blank - that is the night, not
/// a break. A solid red current-time marker shows while now is on screen, and the session
/// under the pointer is spotlit, with a callout beside it.
///
/// `domain` is the window on screen and `tracks` every day it touches; scrolling moves the
/// window through time, so the blocks, hour lines and markers slide under rows and a frame
/// that stay put.
struct DayTimelineChart: View {
    let tracks: [DayTrack]
    let domain: ClosedRange<Date>
    /// When non-nil, the current-time marker is drawn here (today may be on screen).
    let nowMarker: Date?
    /// True while the content moves under a still pointer, so the callout can't name a spell
    /// that has slid away from it.
    var isScrolling = false
    /// The plot's width, for turning scrolled points into time.
    var onPlotWidth: (CGFloat) -> Void = { _ in }
    /// Days either side of the window, whose glow is built in the background ahead of a scroll
    /// reaching them.
    var neighbours: [DayTrack] = []
    /// Bumped when a day's glow finishes building in the background, to draw it in.
    @State private var glowsReady = 0

    /// Height of each posture row's block, in row units (rows are one unit apart).
    private static let band = 0.5
    /// Blocks sit a little below the middle of their row, as in Health's sleep chart, leaving
    /// the top of the row for its name.
    private static func rowCenter(_ state: PostureState) -> Double { PostureStyle.level(state) - 0.1 }
    /// The rows' names, top to bottom, set in the top-left corner of each row like Health's
    /// "Awake", "REM", "Core", "Deep".
    private static let rowNames: [(level: Double, name: String)] = [(2, "Standing"), (1, "Sitting"), (0, "Away")]
    /// The pale layer's strength over the card. Light is Apple's, measured off the sleep card
    /// (about 28% of the block's colour over the background). Dark is stronger: over a
    /// near-black card the same share turns the links between blocks a muddy navy and the
    /// breaks' grey all but disappears.
    private static let tint = (light: 0.28, dark: 0.6)
    /// Room either side of a day's blocks for their glow.
    private static let glowRoom: CGFloat = 24
    private static let axisFontSize: CGFloat = 10
    /// How far from a block, in points, the pointer still counts as on it.
    private static let hoverSlop: CGFloat = 10
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    /// One day's blocks and the transitions between blocks on different rows, laid out from
    /// the day's own first block rather than from the window. Scrolling only moves the layer,
    /// so its blocks - and the painter's cached glow for them - stay the same.
    private struct DayLayer {
        let id: Date
        let x: CGFloat
        let width: CGFloat
        let blocks: [SleepCardBlock]
        let junctions: [SleepCardJunction]
        let blockHeight: CGFloat
    }

    private func layers(proxy: ChartProxy, plot: CGRect) -> [DayLayer] {
        layers(of: tracks, proxy: proxy, plot: plot, onScreenOnly: true)
    }

    private func layers(of tracks: [DayTrack], proxy: ChartProxy, plot: CGRect, onScreenOnly: Bool) -> [DayLayer] {
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        guard span > 0,
              let startX = proxy.position(forX: domain.lowerBound),
              let endX = proxy.position(forX: domain.upperBound), endX > startX else { return [] }
        let perSecond = (endX - startX) / CGFloat(span)
        guard let top = proxy.position(forY: Self.band / 2), let bottom = proxy.position(forY: -Self.band / 2) else { return [] }
        return tracks.compactMap { track in
            let drawn = track.drawn
            guard let origin = drawn.first?.start, let end = drawn.last?.end else { return nil }
            let room = Self.glowRoom
            let width = (CGFloat(end.timeIntervalSince(origin)) * perSecond + 2 * room).rounded(.up)
            // On the pixel grid, so the blocks are crisp wherever the scroll comes to rest.
            let x = ((plot.minX + startX + CGFloat(origin.timeIntervalSince(domain.lowerBound)) * perSecond - room)
                * displayScale).rounded() / displayScale
            guard !onScreenOnly || (x + width > plot.minX && x < plot.maxX) else { return nil }
            func localX(_ date: Date) -> CGFloat { (room + CGFloat(date.timeIntervalSince(origin)) * perSecond).rounded() }
            var blocks: [SleepCardBlock] = []
            for segment in drawn {
                let level = Self.rowCenter(segment.state)
                guard let rowTop = proxy.position(forY: level + Self.band / 2),
                      let rowBottom = proxy.position(forY: level - Self.band / 2) else { continue }
                let x0 = localX(segment.start)
                let rect = CGRect(x: x0, y: (plot.minY + rowTop).rounded(),
                                  width: max(2, localX(segment.end) - x0), height: (rowBottom - rowTop).rounded())
                blocks.append(SleepCardBlock(rect: rect, lane: Self.lane(segment.state), color: blockColor(segment.state)))
            }
            var junctions: [SleepCardJunction] = []
            for (index, next) in drawn.enumerated().dropFirst() {
                let previous = drawn[index - 1]
                guard previous.state != next.state, next.start.timeIntervalSince(previous.end) < 120 else { continue }
                junctions.append(SleepCardJunction(a: index - 1, b: index, x: localX(next.start)))
            }
            return DayLayer(id: track.dayStart, x: x, width: width, blocks: blocks, junctions: junctions,
                            blockHeight: (bottom - top).rounded())
        }
    }

    @State private var hover: Hover?
    /// The last thing hovered, kept after the pointer leaves so the spotlight can fade out
    /// where it was.
    @State private var lastHover: Hover?

    private struct Hover: Equatable {
        let segment: PostureSegment
        /// Before the day's first arrival or after its last moment at the desk: the night,
        /// which has nothing to read out.
        let offClock: Bool
    }

    private static func lane(_ state: PostureState) -> Int {
        switch state {
        case .standing: return 0
        case .sitting: return 1
        case .away: return 2
        }
    }
    /// Solid, for the painter: the posture colours, and the charts' grey for a break.
    private func blockColor(_ state: PostureState) -> NSColor {
        NSColor(state == .away ? PostureStyle.breakColor(colorScheme) : PostureStyle.color(state))
    }
    var body: some View {
        // The same headroom as `PeriodColumnsChart`, so the three ranges' charts sit in one
        // frame, with room for the Now dot above the plot.
        chart
            .padding(.top, DashboardCharts.chartHeadroom)
            .onChange(of: isScrolling) { _, scrolling in
                if scrolling { hover = nil }
            }
            .onChange(of: hover) { old, new in HoverMotion.follow(old, new, last: &lastHover) }
    }

    private var chart: some View {
        timelineChart.frame(height: DashboardCharts.dayChartHeight)
    }

    private var timelineChart: some View {
        // Read here, in the view's own body, so a glow finishing redraws the chart.
        let ready = glowsReady
        let redraw = { glowsReady &+= 1 }
        // No marks of its own: the chart supplies the scales, axis and plot frame, and the
        // rows are drawn into its background by `SleepCardPainter`.
        return Chart {
        }
        .chartXScale(domain: domain, range: .plotDimension(padding: 0))
        .chartYScale(domain: -0.5...2.5)
        .chartBackground { proxy in
            // The rows and their glow, drawn as the sleep card draws them: the halos, the
            // necks between rows with their flares, then the solid blocks - a layer per day,
            // clipped to the plot as they slide past its edges.
            GeometryReader { geometry in
                if let plotFrame = proxy.plotFrame {
                    let plot = geometry[plotFrame]
                    ZStack(alignment: .topLeading) {
                        ForEach(Self.rowNames, id: \.level) { row in
                            if let top = proxy.position(forY: row.level + 0.5) {
                                Text(row.name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize()
                                    .offset(x: plot.minX + 6, y: plot.minY + top + 3)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .onChange(of: plot.width, initial: true) { _, width in
                        onPlotWidth(max(0, width))
                    }
                    // The glow is never built on the main thread: a day the scroll reaches before
                    // its glow is ready shows its blocks, and the glow draws in when built.
                    ZStack(alignment: .topLeading) {
                        ForEach(layers(proxy: proxy, plot: plot), id: \.id) { layer in
                            Canvas { context, size in
                                _ = ready
                                SleepCardPainter.drawWhenReady(in: &context, size: size, scale: displayScale,
                                                               blocks: layer.blocks, junctions: layer.junctions,
                                                               metrics: SleepCardMetrics.forBlockHeight(layer.blockHeight),
                                                               tint: colorScheme == .dark ? Self.tint.dark : Self.tint.light,
                                                               onReady: redraw)
                            }
                            .frame(width: layer.width, height: geometry.size.height)
                            .offset(x: layer.x)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .mask(alignment: .topLeading) {
                        Rectangle()
                            .frame(width: max(0, plot.width), height: geometry.size.height)
                            .offset(x: plot.minX)
                    }
                    .mask(alignment: .topLeading) {
                        SpotlightMask(focus: lastHover.flatMap { spotlight($0, proxy: proxy, plot: plot) },
                                      active: hover.map { !$0.offClock } == true)
                    }
                    // The neighbouring days' glow, built in the background before a scroll gets there.
                    Color.clear
                        .task(id: "\(neighbours.map(\.dayStart.timeIntervalSince1970)) \(plot.size) \(colorScheme) \(displayScale)") {
                            for layer in layers(of: neighbours, proxy: proxy, plot: plot, onScreenOnly: false) {
                                SleepCardPainter.prepare(size: CGSize(width: layer.width, height: geometry.size.height), scale: displayScale,
                                                         blocks: layer.blocks, junctions: layer.junctions,
                                                         metrics: SleepCardMetrics.forBlockHeight(layer.blockHeight))
                            }
                        }
                }
            }
        }
        .chartYAxis {
            // Health's rows: a thin solid rule between each, names inside rather than labels
            // beside the plot.
            AxisMarks(values: [0.5, 1.5]) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                    .foregroundStyle(Self.ruleColor)
            }
        }
        .chartLegend(.hidden)
        .chartXAxis {
            // Room for the hour labels only: `hourLabels` lays them out and the overlay draws them,
            // clipped to the plot so they slide in and out with the day.
            AxisMarks(values: [domain.lowerBound]) { _ in
                AxisValueLabel(verticalSpacing: 6) {
                    Text("12 PM").font(.system(size: Self.axisFontSize)).hidden()
                }
            }
            // The hourly grid is independent of label density and ends at the baseline.
            AxisMarks(values: .stride(by: .hour, count: 1)) { value in
                if let date = value.as(Date.self), date >= domain.lowerBound {
                    AxisGridLine(stroke: Self.hourStroke)
                        .foregroundStyle(Self.ruleColor)
                }
            }
        }
        .chartPlotStyle { plot in
            // Solid edges left, right and along the bottom; none across the top.
            plot
                .overlay(alignment: .bottom) { Rectangle().fill(Self.ruleColor).frame(height: 1) }
                .overlay(alignment: .leading) { Rectangle().fill(Self.ruleColor).frame(width: 1) }
                .overlay(alignment: .trailing) { Rectangle().fill(Self.ruleColor).frame(width: 1) }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
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
                    .task(id: [geometry.size.width, geometry.size.height, domain.lowerBound.timeIntervalSince1970]) {
                        guard let seed = DashboardSnapshot.devHover, let plotFrame = proxy.plotFrame else { return }
                        let plot = geometry[plotFrame]
                        hover = hoverInfo(at: CGPoint(x: plot.minX + plot.width * seed.x, y: plot.minY + plot.height * seed.y),
                                          proxy: proxy, geometry: geometry)
                    }
                if let plotFrame = proxy.plotFrame {
                    let plot = geometry[plotFrame]
                    hourLabels(plot: plot)
                    if let nowMarker, domain.contains(nowMarker), let x = proxy.position(forX: nowMarker) {
                        currentTimeMarker(x: geometry[plotFrame].minX + x, plot: geometry[plotFrame])
                    }
                    let shown = hover.flatMap { $0.offClock ? nil : $0.segment }
                    // Wherever it covers least of the other blocks, inside the chart.
                    GlassPopover(anchor: shown.flatMap { blockRect($0, proxy: proxy, plot: plot) },
                                 bounds: plot, sides: [.top, .bottom, .trailing, .leading],
                                 obstacles: shown.map { otherBlocks(than: $0, proxy: proxy, plot: plot) } ?? []) {
                        if let segment = shown ?? lastHover?.segment { SessionCallout(segment: segment) }
                    }
                }
            }
        }
        .transaction { $0.animation = nil }
        .accessibilityLabel("Day timeline")
    }

    private static let ruleColor = DashboardCharts.ruleColor
    private static let hourStroke = DashboardCharts.hourStroke

    /// The hour axis, as Health and ECharts set theirs:
    /// - a label every 1, 2, 4 or 6 hours (as close as the widest fits, from the scale alone, so
    ///   it holds still while the day slides past), counted from the day's boundary hour, each
    ///   just right of its dotted line, so they're all exactly the same distance apart;
    /// - labels slide with their lines and are clipped at the plot's edges, never nudged; the
    ///   leftmost sticks to the left edge as its line passes out of view, until the next one
    ///   pushes it off, like a list's section header, so the left edge always has a time;
    /// - the time now's capsule outranks them: a label it would touch steps aside.
    /// The day's arrival and departure aren't on it.
    private func hourLayout(width: CGFloat) -> (labels: [(left: CGFloat, text: String, date: Date)], capsule: ClosedRange<Double>?) {
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        guard span > 0, width > 0 else { return ([], nil) }
        let font = NSFont.systemFont(ofSize: Self.axisFontSize)
        func x(_ date: Date) -> CGFloat { CGFloat(date.timeIntervalSince(domain.lowerBound) / span) * width }
        func measure(_ text: String) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width + 1 }
        let beside: CGFloat = 3
        let gap = CGFloat(StripAxisLayout.gap)
        let calendar = Calendar.current
        let pointsPerHour = width * 3600 / CGFloat(span)
        let widest = ["10 AM", "12 PM", "10 PM"].map(measure).max() ?? 40
        // Labels all sit `beside` right of their lines, so a step needs only the label and the gap.
        let step = [1, 2, 4, 6].first { CGFloat($0) * pointsPerHour >= widest + gap } ?? 6
        let boundary = calendar.component(.hour, from: tracks.first?.dayStart ?? domain.lowerBound)
        // From the last labelled hour before the window (it may still be sticking) to the end.
        var hour = calendar.dateInterval(of: .hour, for: domain.lowerBound)?.start ?? domain.lowerBound
        while (calendar.component(.hour, from: hour) - boundary + 24) % step != 0 {
            hour = hour.addingTimeInterval(-3600)
        }
        var ticks: [(date: Date, text: String, natural: CGFloat, width: CGFloat)] = []
        while hour < domain.upperBound {
            let text = hour.formatted(.dateTime.hour())
            ticks.append((hour, text, x(hour) + beside, measure(text)))
            hour = hour.addingTimeInterval(TimeInterval(step * 3600))
        }
        let capsule = nowMarker.flatMap { now in
            nowCapsuleSpan(width: width, labels: ticks.map { .init(left: Double($0.natural), width: Double($0.width)) })
        }
        var placed: [(left: CGFloat, text: String, date: Date)] = []
        for (index, tick) in ticks.enumerated() {
            var left = tick.natural
            if left < 0 {
                // Sticking at the edge, unless the next label is already pushing it off.
                let next = index + 1 < ticks.count ? ticks[index + 1].natural : .infinity
                left = min(0, next - gap - tick.width)
            }
            guard left + tick.width > 0, left < width else { continue }
            if let capsule, Double(left + tick.width) + StripAxisLayout.nowGap > capsule.lowerBound,
               capsule.upperBound + StripAxisLayout.nowGap > Double(left) { continue }
            placed.append((left, tick.text, tick.date))
        }
        return (placed, capsule)
    }

    /// The hour labels under the plot, clipped to its width.
    private func hourLabels(plot: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(hourLayout(width: plot.width).labels, id: \.date) { label in
                Text(label.text)
                    .font(.system(size: Self.axisFontSize))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .offset(x: plot.minX + label.left, y: plot.maxY + 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .mask(alignment: .topLeading) {
            Rectangle()
                .frame(width: max(0, plot.width), height: plot.maxY + 40)
                .offset(x: plot.minX)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    /// The time now as the menu's strip shows it: white on a red capsule, on the axis.
    private var nowText: String? {
        guard let nowMarker, domain.contains(nowMarker) else { return nil }
        return nowMarker.formatted(date: .omitted, time: .shortened)
    }
    private static let nowFont = NSFont.monospacedDigitSystemFont(ofSize: axisFontSize, weight: .semibold)
    private static let nowPadding: CGFloat = 5
    private static let nowHeight: Double = 15
    /// The height SwiftUI gives a line of the hour labels.
    private static let axisLineHeight = NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: axisFontSize))

    /// The capsule's horizontal extent on an axis `width` wide: centred on now, or slid along
    /// its flat middle if that leaves more of the hour `labels` showing, and kept inside.
    private func nowCapsuleSpan(width: CGFloat, labels: [StripAxisLayout.Span]) -> ClosedRange<Double>? {
        guard let nowMarker, let text = nowText else { return nil }
        let capsule = (text as NSString).size(withAttributes: [.font: Self.nowFont]).width + 2 * Self.nowPadding
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        let x = nowMarker.timeIntervalSince(domain.lowerBound) / span * Double(width)
        let centre = StripAxisLayout.nowCentre(now: x, half: capsule / 2, maxShift: max(0, capsule / 2 - Self.nowHeight / 2),
                                               labels: labels)
        let left = min(max(0, centre - capsule / 2), Double(width) - capsule)
        return left...(left + capsule)
    }

    /// The current time: a solid red line from its dot above the plot down into a red capsule
    /// on the axis holding the time, as in the menu's strip; hour labels it would touch have
    /// stepped aside (see `axisLabels`).
    private func currentTimeMarker(x: CGFloat, plot: CGRect) -> some View {
        let top = plot.minY - 6
        // Centred on the hour labels' line, whose top sits 6 below the plot.
        let capsuleY = plot.maxY + 6 + Self.axisLineHeight / 2
        let capsule = hourLayout(width: plot.width).capsule
        return ZStack {
            Path { path in
                path.move(to: CGPoint(x: x, y: top))
                path.addLine(to: CGPoint(x: x, y: capsule == nil ? plot.maxY : capsuleY))
            }
            .stroke(Color.red, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            Circle().fill(Color.red).frame(width: 6, height: 6)
                .position(x: x, y: top)
            if let capsule, let text = nowText {
                Text(text)
                    .font(Font(Self.nowFont))
                    .foregroundStyle(.white)
                    .fixedSize()
                    .frame(width: capsule.upperBound - capsule.lowerBound, height: Self.nowHeight)
                    .background(Capsule().fill(Color.red))
                    .position(x: plot.minX + (capsule.lowerBound + capsule.upperBound) / 2, y: capsuleY)
            }
        }
        .allowsHitTesting(false)
    }

    /// The hovered block's visible part, in the overlay's coordinates.
    private func blockRect(_ segment: PostureSegment, proxy: ChartProxy, plot: CGRect) -> CGRect? {
        let level = Self.rowCenter(segment.state)
        guard let x0 = proxy.position(forX: max(segment.start, domain.lowerBound)),
              let x1 = proxy.position(forX: min(segment.end, domain.upperBound)),
              let top = proxy.position(forY: level + Self.band / 2),
              let bottom = proxy.position(forY: level - Self.band / 2) else { return nil }
        return CGRect(x: plot.minX + x0, y: plot.minY + top, width: max(2, x1 - x0), height: bottom - top)
    }

    /// Every drawn block but `segment`, for the popover to keep clear of.
    private func otherBlocks(than segment: PostureSegment, proxy: ChartProxy, plot: CGRect) -> [CGRect] {
        tracks.flatMap(\.drawn).filter { $0 != segment }.compactMap { other in
            blockRect(other, proxy: proxy, plot: plot).flatMap { $0.intersects(plot) ? $0 : nil }
        }
    }

    /// The hovered block with room for its glow, in the background's coordinates.
    private func spotlight(_ hover: Hover, proxy: ChartProxy, plot: CGRect) -> CGRect? {
        let segment = hover.segment
        let level = Self.rowCenter(segment.state)
        guard !hover.offClock,
              let x0 = proxy.position(forX: max(segment.start, domain.lowerBound)),
              let x1 = proxy.position(forX: min(segment.end, domain.upperBound)),
              let top = proxy.position(forY: level + Self.band / 2),
              let bottom = proxy.position(forY: level - Self.band / 2) else { return nil }
        // Room for its glow above and below, but hardly any to the sides, where the next
        // block may sit right against it.
        return CGRect(x: plot.minX + x0, y: plot.minY + top, width: max(2, x1 - x0), height: bottom - top)
            .insetBy(dx: -1.5, dy: -7)
    }

    private func hoverInfo(at point: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> Hover? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let plot = geometry[plotFrame]
        guard plot.contains(point) else { return nil }
        guard let date: Date = proxy.value(atX: point.x - plot.origin.x), domain.contains(date) else { return nil }
        // A block in the row under the pointer, if one is near enough: a minute's standing is a
        // sliver a point or two wide, so it is caught from either side rather than only dead on.
        if let level = proxy.value(atY: point.y - plot.minY, as: Double.self) {
            let row = PostureStyle.ordered.min { abs(Self.rowCenter($0) - level) < abs(Self.rowCenter($1) - level) }
            var best: (segment: PostureSegment, distance: CGFloat)?
            for track in tracks {
                for segment in track.drawn where segment.state == row {
                    guard let x0 = proxy.position(forX: max(segment.start, domain.lowerBound)),
                          let x1 = proxy.position(forX: min(segment.end, domain.upperBound)), x1 >= x0 else { continue }
                    let x = point.x - plot.minX
                    let distance = x < x0 ? x0 - x : (x > x1 ? x - x1 : 0)
                    if distance <= Self.hoverSlop, distance < (best?.distance ?? .infinity) { best = (segment, distance) }
                }
            }
            if let best { return Hover(segment: best.segment, offClock: false) }
        }
        for track in tracks {
            guard let segment = DashboardCharts.segment(at: date, in: track.segments) else { continue }
            return Hover(segment: segment,
                         offClock: DashboardCharts.isOffClock(segment, bounds: track.bounds, openEnded: track.isToday))
        }
        return nil
    }
}

/// Compared by what it draws, not by its closure, so a parent redrawing for other reasons
/// doesn't rebuild the chart when nothing in it changed.
extension DayTimelineChart: Equatable {
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.tracks == b.tracks && a.domain == b.domain && a.nowMarker == b.nowMarker
            && a.isScrolling == b.isScrolling && a.neighbours == b.neighbours
    }
}
