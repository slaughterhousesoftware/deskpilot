import AppKit
import SwiftUI
import DeskpilotKit

/// Today at the desk as a small strip, drawn the way the Health app's sleep card draws the
/// night (`SleepCardPainter` in DeskpilotKit has the construction and its provenance): standing,
/// sitting, and breaks away from the desk in grey on a third lane, like the Dashboard's day
/// chart, with an hour axis under it. Each lane's total for the day stands at its right end,
/// in a column of its own, the way Health sets its axis values beside a chart.
struct MenuTimelineStrip: View {
    let segments: [PostureSegment]
    let now: Date
    /// The hour the person's day usually starts; the strip begins there (or at today's first
    /// spell, if that was earlier). 6 AM until there's history to go on.
    var dayStartHour: Int? = nil
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    /// The drawing's measurements, overridable by name (`tools/strip-harness` iterates on them
    /// without rebuilding the app).
    enum Tuning {
        static var overrides: [String: Double] = [:]
        static func set(_ key: String, _ value: Double) { overrides[key] = value }
        static subscript(key: String, default value: Double) -> CGFloat { CGFloat(overrides[key] ?? value) }
    }
    private static var height: CGFloat { Tuning["height", default: 72] }          // three lanes of 24 pt
    private static let axisHeight: CGFloat = 19
    /// Room above the lanes for the now line's dot to sit on their top edge.
    private static var headroom: CGFloat { nowLine ? 6 : 0 }
    private static var sessionGap: TimeInterval { Double(Tuning["sessionGap", default: 20]) * 60 }   // minutes away that end a session
    private static var blockShare: CGFloat { Tuning["blockShare", default: 0.62] } // 15 pt blocks
    private static var radiusShare: CGFloat { Tuning["radiusShare", default: 0.16] }
    private static var haloIn: CGFloat { Tuning["haloIn", default: 1.37] }    // edge facing the other lane
    private static var haloOut: CGFloat { Tuning["haloOut", default: 0.94] }  // far edge and sides
    private static var soft: CGFloat { Tuning["soft", default: 0.1] }
    private static var merge: CGFloat { Tuning["merge", default: 2.05] }   // 0.16 H: about two minutes on a day-long strip
    private static var supersample: CGFloat { Tuning["ss", default: 2] }
    private static var neckWidth: CGFloat { Tuning["neck", default: 1.9] }
    private static var closing: CGFloat { Tuning["close", default: 2.7] }
    private static var minimumBlockWidth: CGFloat { Tuning["minBlock", default: 2] }
    private static var darkTint: CGFloat { Tuning["darkTint", default: 0.55] }
    private static var lightTint: CGFloat { Tuning["lightTint", default: 0.36] }
    private static let minimumSpan: TimeInterval = 3 * 3600
    /// Strength of the dotted guides and the hour labels' style (0 tertiary, 1 secondary).
    private static var guideOpacity: Double { Double(Tuning["guide", default: 0.3]) }
    private static var strongLabels: Bool { Tuning["labels", default: 1] > 0 }
    /// Bare hour numbers ("8", "10", "12") after the first, like a ruler, so a label fits every
    /// two hours. Off: every label says "AM" or "PM".
    private static var shortHours: Bool { Tuning["short", default: 0] > 0 }
    /// A faint rounded plate behind the lanes, to lift them off the menu's glass.
    private static var plate: Bool { Tuning["plate", default: 0] > 0 }
    /// The whole day, its usual start (or the first spell, if earlier) to midnight, rather than first
    /// spell to now: the rest of the day stays empty and the now line sits where the day is.
    private static var fullDay: Bool { Tuning["fullDay", default: 1] > 0 }
    /// The Dashboard's red current-time line through the lanes, with its dot.
    private static var nowLine: Bool { Tuning["now", default: 1] > 0 }
    /// Each lane's total at its right end, in a column the lanes and hours stop short of.
    private static var totals: Bool { Tuning["totals", default: 1] > 0 }
    /// The time now under the red line: 0 none, 1 red figures, 2 white on a red capsule.
    /// Hour labels it would touch give way to it.
    private static var nowLabel: Int { Int(Tuning["nowLabel", default: 2]) }
    /// How strongly the rest of the day (after now) draws its hours and guides, 1 the same as
    /// the past; lower lets the empty future recede.
    private static var future: Double { Double(Tuning["future", default: 0.55]) }
    /// The hour axis runs the full width, on under the totals: they sit over the part of the
    /// day still to come, and the scale stretches late at night so now never reaches them.
    private static var axisUnder: Bool { Tuning["under", default: 1] > 0 }
    /// Space between the end of the lanes and the totals column.
    private static var totalsGap: CGFloat { Tuning["totalsGap", default: 10] }

    private var atDesk: [PostureSegment] { segments.filter { $0.state != .away } }
    /// The spells at the desk and every break since the first of them (today is still going,
    /// so the time since the last spell is a break too); not the night before.
    private var drawn: [PostureSegment] {
        guard let first = atDesk.first else { return [] }
        return segments.filter { $0.state != .away || $0.end > first.start }
    }

    /// Desk sessions: runs of desk time separated by `sessionGap` or more away.
    static func sessions(of segments: [PostureSegment]) -> [(start: Date, end: Date)] {
        var sessions: [(start: Date, end: Date)] = []
        for spell in segments where spell.state != .away {
            if let last = sessions.last, spell.start.timeIntervalSince(last.end) < sessionGap {
                sessions[sessions.count - 1].end = max(last.end, spell.end)
            } else {
                sessions.append((spell.start, spell.end))
            }
        }
        return sessions
    }

    /// The sessions as one line of text, the way the sleep card states the time in bed:
    /// "10:33–11:46 AM · 2:33 PM – Now".
    static func sessionsText(of segments: [PostureSegment], now: Date) -> String {
        let sessions = sessions(of: segments)
        return sessions.enumerated().map { index, session in
            let ongoing = index == sessions.count - 1 && now.timeIntervalSince(session.end) < sessionGap
            return ongoing ? "\(session.start.formatted(date: .omitted, time: .shortened)) – Now"
                           : (session.start..<session.end).formatted(date: .omitted, time: .shortened)
        }.joined(separator: ", ")
    }

    var body: some View {
        if let first = atDesk.first {
            let (start, end) = span(from: first.start)
            Canvas { context, size in
                draw(in: &context, size: size, start: start, end: end)
            }
            .frame(height: Self.headroom + Self.height + Self.axisHeight)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Today: standing \(Formatting.duration(total(.standing))), sitting \(Formatting.duration(total(.sitting)))")
        }
    }

    /// The time the strip spans: from the hour the day usually starts (or today's first spell,
    /// if earlier) to midnight, or later if it's late; or with `fullDay` off, first spell to now.
    /// It runs in whole grid steps from its start, so the hour grid ends on its own beat.
    private func span(from first: Date) -> (Date, Date) {
        guard Self.fullDay else { return (first, max(now, first.addingTimeInterval(Self.minimumSpan))) }
        let calendar = Calendar.current
        let hour = calendar.dateInterval(of: .hour, for: first)?.start ?? first
        let usual = calendar.date(bySettingHour: dayStartHour ?? 6, minute: 0, second: 0, of: first) ?? hour
        let start = min(hour, usual)
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: start)) ?? now
        let nowHour = calendar.dateInterval(of: .hour, for: now)?.end ?? now
        let latest = max(midnight, nowHour)
        let step = Self.gridStep(from: start)
        var end = start
        while end < latest { end = end.addingTimeInterval(step) }
        return (start, end)
    }

    /// The hours between grid lines for a day starting at `start`: the first of 3, 4, 2 or 6
    /// that divides the time to midnight, so the grid lands on midnight (a day from 8 AM goes
    /// 8, 12, 4, 8, 12); three hours if none does.
    private static func gridStep(from start: Date) -> TimeInterval {
        let calendar = Calendar.current
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: start)) ?? start
        let hours = Int((midnight.timeIntervalSince(start) / 3600).rounded())
        let step = [3, 4, 2, 6].first { hours % $0 == 0 } ?? 3
        return TimeInterval(step * 3600)
    }

    private static func base(_ state: PostureState) -> NSColor {
        NSColor(state == .standing ? DeskpilotAppearance.standing : DeskpilotAppearance.sitting)
    }
    /// A break: an opaque grey, quiet beside the posture colours on either menu. The system
    /// grey in dark mode; in light mode a step darker than the Dashboard's, since the menu's
    /// pale glass sits close to the lighter one.
    private var breakColor: NSColor { NSColor(white: colorScheme == .dark ? 0.48 : 0.55, alpha: 1) }
    private static func lane(_ state: PostureState) -> Int {
        switch state {
        case .standing: return 0
        case .sitting: return 1
        case .away: return 2
        }
    }

    /// How much of the block colour the halos and necks carry: they're drawn opaque in one
    /// layer that's composited at this opacity, so overlapping pieces never double up and the
    /// tint sits on whatever the menu's background is.
    private var tint: Double { colorScheme == .dark ? Self.darkTint : Self.lightTint }


    /// Today's time in one lane, the spell under way counted up to now; breaks only from the
    /// first spell on, as the lanes draw them.
    private func total(_ state: PostureState) -> TimeInterval {
        drawn.filter { $0.state == state }
            .reduce(0) { $0 + max(0, min($1.end, now).timeIntervalSince($1.start)) }
    }

    /// The totals' colours: the lanes' own, deepened on the light menu so small type reads
    /// (the lanes' own colours were tried there on 2026-10-29 and were hard to see on the
    /// glass); breaks in a strong grey (the secondary style washes out on the glass).
    private func totalStyle(_ state: PostureState) -> AnyShapeStyle {
        switch state {
        case .standing:
            return AnyShapeStyle(colorScheme == .dark ? DeskpilotAppearance.standing : Color(red: 0, green: 0.42, blue: 0.38))
        case .sitting:
            return AnyShapeStyle(colorScheme == .dark ? DeskpilotAppearance.sitting : Color(red: 0, green: 0.33, blue: 0.70))
        case .away:
            return AnyShapeStyle(Color.primary.opacity(0.72))
        }
    }

    /// The time now's red: the system's own.
    private var nowRed: Color { Color(nsColor: .systemRed) }

    private func draw(in context: inout GraphicsContext, size full: CGSize, start: Date, end dayEnd: Date) {
        context.translateBy(x: 0, y: Self.headroom)
        // The totals, measured first: the lanes end where their column begins. The column is
        // at least as wide as "9h 59m", so it doesn't shift as the minutes tick over.
        // Bold, a point up from the hours: on the menu's bright glass, lighter type washes out.
        let totalFont = Font.system(size: 12, weight: .bold).monospacedDigit()
        let lanes: [PostureState] = [.standing, .sitting, .away]
        // Every lane shows its figure, "0m" included, so a morning with no break yet still
        // says so rather than leaving the lane unlabelled.
        let totals = lanes.map { state -> GraphicsContext.ResolvedText? in
            guard Self.totals else { return nil }
            return context.resolve(Text(Formatting.duration(total(state))).font(totalFont).foregroundStyle(totalStyle(state)))
        }
        let unbounded = CGSize(width: 200, height: 40)
        let widest = ([context.resolve(Text("9h 59m").font(totalFont))] + totals.compactMap { $0 })
            .map { $0.measure(in: unbounded).width }.max() ?? 0
        let column = Self.totals ? ceil(widest) + Self.totalsGap : 0
        let size = CGSize(width: full.width, height: full.height - Self.axisHeight - Self.headroom)
        // Where the lanes stop and the totals begin.
        let lanesEnd = size.width - column
        // The width the hours are spread over: the whole strip when the axis runs on under the
        // totals, otherwise just the lanes.
        let plotWidth = Self.axisUnder ? size.width : lanesEnd
        let inset = Self.haloIn + Self.closing + 1
        // With the axis under the totals, the day ends no sooner than it takes to keep now a few
        // points short of them: late at night the hours close up and the axis runs past midnight.
        // Then on to the next hour on the label grid, so the end gets its line and label.
        var hours = Int((dayEnd.timeIntervalSince(start) / 3600).rounded(.up))
        if Self.axisUnder && Self.totals {
            let reach = (lanesEnd - 4 - inset) / (plotWidth - 2 * inset)
            if reach > 0 {
                hours = max(hours, Int((now.timeIntervalSince(start) / Double(reach) / 3600).rounded(.up)))
            }
        }
        // The labels' step: every hour, two, three, four or six, the tightest the widest label
        // fits. Every label sits the same 3 points right of its line, so the space between two
        // labels is the step less the label, and the gap is all a step has to leave.
        let widestHour = ["10 AM", "12 PM", "10 PM"]
            .map { context.resolve(Text($0).font(.system(size: 11, weight: .semibold))).measure(in: unbounded).width }.max() ?? 36
        func labelStep(_ hours: Int) -> Int {
            let pointsPerHour = (plotWidth - 2 * inset) / CGFloat(max(1, hours))
            return [1, 2, 3, 4, 6].first { CGFloat($0) * pointsPerHour >= widestHour + CGFloat(StripAxisLayout.gap) } ?? 6
        }
        while hours % labelStep(hours) != 0 { hours += 1 }
        let step = labelStep(hours)
        let end = start.addingTimeInterval(TimeInterval(hours * 3600))
        let span = end.timeIntervalSince(start)
        func x(_ date: Date) -> CGFloat {
            (inset + (plotWidth - 2 * inset) * CGFloat(date.timeIntervalSince(start) / span)).rounded()
        }
        // The hour axis: evenly spaced hours set beside their dotted lines, and the time now on
        // its capsule (see below).
        // Round dots with clear space between them: closer, and they run together into lines.
        let guide = StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [0.1, 4.5])
        // The axis itself: a solid hairline the hours stand on.
        let baseline = StrokeStyle(lineWidth: 1)
        let calendar = Calendar.current
        // A strong grey rather than the secondary style, which washes out on the glass.
        let labelStyle = Color.primary.opacity(Self.strongLabels ? 0.68 : 0.45)
        if Self.plate {
            context.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: lanesEnd, height: size.height).insetBy(dx: -2, dy: -2), cornerRadius: 6, style: .continuous),
                         with: .color(.primary.opacity(colorScheme == .dark ? 0.07 : 0.05)))
        }
        let labelY = size.height + 4
        let unboundedLabel = CGSize(width: 200, height: 40)
        func hourLabel(_ date: Date, anchor: Bool = false, sample: String? = nil) -> GraphicsContext.ResolvedText {
            if let sample {
                return context.resolve(Text(sample).font(.system(size: 11, weight: .semibold)).foregroundStyle(labelStyle))
            }
            let onTheHour = calendar.component(.minute, from: date) == 0
            let bare = Self.shortHours && !anchor
            let text = !onTheHour ? date.formatted(date: .omitted, time: .shortened)
                : bare ? date.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)))
                : date.formatted(.dateTime.hour())
            return context.resolve(Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(labelStyle))
        }
        // Past and future: labels and guides after now drawn at `future`.
        func strength(_ date: Date) -> Double { date > now ? Self.future : 1 }

        // The time now, centred under its line and kept inside the strip.
        let showsNowLabel = Self.nowLine && Self.nowLabel > 0 && now >= start && now <= end
        let nowText = context.resolve(Text(now.formatted(date: .omitted, time: .shortened))
            .font(.system(size: 11, weight: .semibold)).monospacedDigit()
            .foregroundStyle(Self.nowLabel == 2 ? Color.white : nowRed))
        let nowSize = nowText.measure(in: unboundedLabel)
        let pad: CGFloat = Self.nowLabel == 2 ? 5 : 0
        let nowWidth = nowSize.width + 2 * pad

        // The labelled hours: every `step` hours from the strip's start, each label just right
        // of its dotted line, as Health sets them, so they're all exactly the same distance
        // apart, every `step` (above). The strip's end is on the same grid.
        let beside: CGFloat = 3
        var ticks: [Date] = []
        var tick = start
        while tick < end {
            ticks.append(tick)
            tick = tick.addingTimeInterval(TimeInterval(step * 3600))
        }
        // The capsule centred on now, or slid along its flat middle if that leaves more hour
        // labels showing, and kept inside the strip.
        func widthOfLabel(_ date: Date) -> CGFloat { hourLabel(date).measure(in: unboundedLabel).width }
        let nowCentre = StripAxisLayout.nowCentre(
            now: Double(x(now)), half: Double(nowWidth / 2),
            maxShift: Double(max(0, nowWidth / 2 - (nowSize.height + 2) / 2)),
            labels: ticks.map { .init(left: Double(x($0) + beside), width: Double(widthOfLabel($0))) })
        let nowLeft = min(max(0, CGFloat(nowCentre) - nowWidth / 2), plotWidth - nowWidth)
        let nowSpan = StripAxisLayout.Span(left: Double(nowLeft), width: Double(nowWidth))
        // A dotted line through the lanes at every labelled hour and at the end, whether or not
        // its label is showing, so the grid stays regular. Lines crossing the totals break
        // around the figures rather than run through them.
        var lines = context
        if Self.totals {
            let laneHeight = size.height / 3
            var mask = Path(CGRect(x: -10, y: -10, width: size.width + 20, height: size.height + 20))
            for (index, text) in totals.enumerated() {
                guard let text else { continue }
                let measured = text.measure(in: unbounded)
                let centre = laneHeight * (CGFloat(index) + 0.5)
                mask.addRect(CGRect(x: size.width - measured.width - 4, y: centre - measured.height / 2 - 1,
                                    width: measured.width + 8, height: measured.height + 2))
            }
            lines.clip(to: mask, style: FillStyle(eoFill: true))
        }
        for tick in ticks + [end] {
            let tx = x(tick) + 0.5
            lines.stroke(Path { $0.move(to: CGPoint(x: tx, y: 0)); $0.addLine(to: CGPoint(x: tx, y: size.height)) },
                         with: .color(.primary.opacity(Self.guideOpacity * strength(tick))), style: guide)
        }
        // The labels, but none the time now's capsule would touch. The strip's end, when its
        // line is drawn, is labelled too: flush with the edge, ending at its line, as charts
        // label their last value, so the axis says where the day it allows for runs to. It
        // keeps clear of the label before it.
        var lastRight = -Double.infinity
        func place(_ date: Date, left: Double) {
            let label = hourLabel(date)
            let right = left + Double(label.measure(in: unboundedLabel).width)
            guard right <= Double(plotWidth), left >= lastRight + StripAxisLayout.gap else { return }
            if showsNowLabel, right + StripAxisLayout.nowGap > nowSpan.left, nowSpan.right + StripAxisLayout.nowGap > left { return }
            var faded = context
            faded.opacity = strength(date)
            faded.draw(label, at: CGPoint(x: CGFloat(left), y: labelY), anchor: .topLeading)
            lastRight = right
        }
        for tick in ticks {
            place(tick, left: Double(x(tick) + beside))
        }
        place(end, left: Double(plotWidth - hourLabel(end).measure(in: unboundedLabel).width))
        if Self.totals && !Self.axisUnder {
            // The day's end closes the lanes with the hours' dotted line, so the totals read
            // as a column beside the chart rather than more of it.
            let ex = x(end) + 0.5
            context.stroke(Path { $0.move(to: CGPoint(x: ex, y: 0)); $0.addLine(to: CGPoint(x: ex, y: size.height)) },
                           with: .color(.primary.opacity(Self.guideOpacity * strength(end))), style: guide)
        }
        let laneHeight = size.height / 3
        let blockHeight = (laneHeight * Self.blockShare).rounded()
        let radius = blockHeight * Self.radiusShare
        func laneCentre(_ state: PostureState) -> CGFloat { laneHeight * (CGFloat(Self.lane(state)) + 0.5) }
        func block(_ spell: PostureSegment) -> SleepCardBlock {
            let x0 = x(spell.start)
            let x1 = max(x(min(spell.end, end)), x0 + Self.minimumBlockWidth)
            return SleepCardBlock(rect: CGRect(x: x0, y: (laneCentre(spell.state) - blockHeight / 2).rounded(), width: x1 - x0, height: blockHeight),
                                  lane: Self.lane(spell.state),
                                  color: spell.state == .away ? breakColor : Self.base(spell.state))
        }

        // Dotted guides at the lanes' edges, running on under the totals so each figure sits
        // in its lane's row.
        // After now they take the future's strength, back to full under the totals.
        let split = min(max(0, x(now)), lanesEnd)
        let underTotals = Self.axisUnder ? Self.future : 1
        for y in [CGFloat(0.5), laneHeight.rounded() + 0.5, (2 * laneHeight).rounded() + 0.5, size.height - 0.5] {
            let isAxis = y == size.height - 0.5
            for (from, to, alpha) in [(CGFloat(0), split, 1.0), (split, lanesEnd, Self.future), (lanesEnd, size.width, underTotals)] where to > from {
                context.stroke(Path { $0.move(to: CGPoint(x: from, y: y)); $0.addLine(to: CGPoint(x: to, y: y)) },
                               with: .color(.primary.opacity(Self.guideOpacity * alpha)), style: isAxis ? baseline : guide)
            }
        }
        // Each lane's total, set right in the column, centred on its lane.
        for (state, text) in zip(lanes, totals) {
            guard let text else { continue }
            context.draw(text, at: CGPoint(x: size.width, y: laneCentre(state)), anchor: .trailing)
        }

        let spells = drawn
        let blocks = spells.map(block)
        var junctions: [SleepCardJunction] = []
        for (index, next) in spells.enumerated().dropFirst() {
            let previous = spells[index - 1]
            guard previous.state != next.state, next.start.timeIntervalSince(previous.end) < 120 else { continue }
            junctions.append(SleepCardJunction(a: index - 1, b: index, x: x(next.start)))
        }
        let metrics = SleepCardMetrics(haloIn: Self.haloIn, haloOut: Self.haloOut, neck: Self.neckWidth, closing: Self.closing,
                                       radius: radius, merge: Self.merge, soft: Self.soft, supersample: Self.supersample,
                                       minimumBlockWidth: Self.minimumBlockWidth)
        SleepCardPainter.draw(in: &context, size: size, scale: displayScale, blocks: blocks, junctions: junctions,
                              metrics: metrics, tint: tint)
        if Self.nowLine, now <= end {
            // The Dashboard's marker: a solid red line under its dot, which sits on the lanes'
            // top edge in the headroom above them; a point and a half wide, so the red
            // doesn't glare against the blue.
            let nx = x(now)
            let red = nowRed
            // With the capsule, the line runs on down into it, as Calendar's does.
            let lineEnd = showsNowLabel && Self.nowLabel == 2 ? labelY : size.height
            context.stroke(Path { $0.move(to: CGPoint(x: nx, y: 0)); $0.addLine(to: CGPoint(x: nx, y: lineEnd)) },
                           with: .color(red), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            context.fill(Path(ellipseIn: CGRect(x: nx - 3.5, y: -3.5, width: 7, height: 7)), with: .color(red))
            if showsNowLabel {
                let rect = CGRect(x: nowLeft, y: labelY - 1, width: nowWidth, height: nowSize.height + 2)
                if Self.nowLabel == 2 {
                    context.fill(Path(roundedRect: rect, cornerRadius: rect.height / 2, style: .continuous), with: .color(red))
                }
                context.draw(nowText, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
            }
        }
    }
}

/// Hosts a view outside the menu's vibrancy. A menu item's `NSHostingView` blends whatever it
/// draws into the menu material, which turned the strip's teal and mint into grey-teal
/// (48,176,199 drawn came out as 90,174,196 on screen); the sleep card's colours are exact.
struct NonVibrant<Content: View>: NSViewRepresentable {
    let content: Content

    func makeNSView(context: Context) -> NSHostingView<Content> { NonVibrantHostingView(rootView: content) }
    func updateNSView(_ view: NSHostingView<Content>, context: Context) { view.rootView = content }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSHostingView<Content>, context: Context) -> CGSize? {
        let fitting = nsView.fittingSize
        return CGSize(width: proposal.width ?? fitting.width, height: fitting.height)
    }
}

private final class NonVibrantHostingView<Content: View>: NSHostingView<Content> {
    override var allowsVibrancy: Bool { false }
}
