import Charts
import SwiftUI
import DeskpilotKit

/// Opaque surfaces: the desktop never changes the contrast of text or charts.
enum DashboardSurface {
    static func background(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.105) : Color(white: 0.955)
    }

    static func panel(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 35 / 255, green: 38 / 255, blue: 44 / 255) : .white
    }
}

/// Consistent padding and solid surfaces for the dashboard's chart panels.
struct InsightCard<Content: View>: View {
    /// Zero for content that pads itself and runs to the card's edges.
    var horizontalPadding: CGFloat = 16
    var trailingPadding: CGFloat? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .padding(.vertical, 14)
            .padding(.leading, horizontalPadding)
            .padding(.trailing, trailingPadding ?? horizontalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { CardPane(cornerRadius: 12) }
    }
}

/// Opaque raised panels give the chart and year grid the same quiet surface.
struct CardPane: View {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape.fill(DashboardSurface.panel(colorScheme))
            .overlay(shape.strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.06), lineWidth: 0.5))
    }
}

/// A card's small grey caption: "Time at desk", "Past year".
struct CardCaption: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
    }
}

/// A duration the way Health sets its figures: digits at size, the unit letters smaller.
struct DurationText: View {
    let value: TimeInterval
    var size: CGFloat = 40

    var body: some View {
        text
            .monospacedDigit()
            .lineLimit(1)
    }

    private var text: Text {
        var result = Text("")
        var run = ""
        var runIsDigits = true
        func flush() {
            guard !run.isEmpty else { return }
            result = result + Text(run).font(.system(size: runIsDigits ? size : size * 0.6,
                                                    weight: .semibold, design: .rounded))
            run = ""
        }
        for character in Formatting.duration(value) where character != " " {
            if character.isNumber != runIsDigits { flush(); runIsDigits = character.isNumber }
            run.append(character)
        }
        flush()
        return result
    }
}

/// One posture's figure below the chart, the way Health pairs a label with its value
/// ("Steps / 5,253"): the name in its posture's colour, the figure under it.
struct PostureFigure: View {
    let state: PostureState
    let value: TimeInterval

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(state == .away ? "Breaks" : PostureStyle.label(state))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(state == .away ? AnyShapeStyle(.secondary) : AnyShapeStyle(PostureStyle.color(state)))
            Text(Formatting.duration(value))
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

/// The center remains a duration; arc lengths show the same posture totals as the graph.
/// Hovering a sector draws it out from the ring, quiets the others, and turns the center to
/// that part's desk glyph, time and share - in place: the figure rolls to the new value and
/// the glyph and share fade in their own slots, rather than one readout fading over another.
/// Anywhere over the ring picks the sector at that angle (the gaps between sectors and the
/// hole keep the current one), and leaving waits a moment before letting go, so moving
/// around the ring never flashes back to the total.
struct DeskDurationRing: View {
    let atDesk: TimeInterval
    let standing: TimeInterval
    let sitting: TimeInterval
    let breaks: TimeInterval
    /// Used only by the developer comparison renderer to match the reference's center.
    var comparisonScore: Int? = nil
    /// The sector drawn out before any hover; for the developer renderer.
    var initialHover: Int? = nil
    /// A composition can place the total beside the ring and name its breakdown here.
    var centerCaptionAtRest: String? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovered: Int?
    /// The pending let-go after the pointer leaves, cancelled if it comes back first.
    @State private var release: Task<Void, Never>?
    private var shown: Int? { hovered ?? initialHover }

    /// The ring at rest, and how far a hovered sector reaches past it.
    private static let size: CGFloat = 112
    private static let popOut: CGFloat = 6
    private static var frameSize: CGFloat { size + 2 * popOut }
    private static var restOuter: CGFloat { size / frameSize }
    private static var restInner: CGFloat { size * 0.76 / frameSize }

    private var values: [TimeInterval] { [max(0, standing), max(0, breaks), max(0, sitting)] }
    /// The desk pictograms: standing, a break (the empty desk with Z's drifting up), sitting.
    private static let glyphs: [DeskGlyph] = [.standing, .resting, .sitting]
    /// The same posture colours and break grey as the charts below, from `PostureStyle`.
    private var colors: [Color] {
        [PostureStyle.color(.standing), PostureStyle.breakColor(colorScheme), PostureStyle.color(.sitting)]
    }

    /// Health's mint sector ends at twelve o'clock; blue sweeps around the bottom.
    private var rotation: Double {
        let total = values.reduce(0, +)
        return total > 0 ? -360 * values[0] / total : 0
    }

    private var ring: some View {
        let palette = colors
        return Chart {
            ForEach(0..<values.count, id: \.self) { index in
                if values[index] > 0 {
                    SectorMark(angle: .value("Duration", values[index]),
                               innerRadius: .ratio(Self.restInner),
                               outerRadius: .ratio(shown == index ? 1 : Self.restOuter),
                               angularInset: 1.8)
                        .cornerRadius(4)
                        .foregroundStyle(palette[index])
                        .opacity(shown == nil || shown == index ? 1 : 0.4)
                }
            }
        }
        .chartLegend(.hidden)
        .rotationEffect(.degrees(rotation))
        .accessibilityHidden(true)
    }

    /// Changes the hovered sector with one quiet ease: no bounce, so moving along the ring
    /// doesn't set it wobbling.
    private func select(_ index: Int?) {
        guard index != hovered else { return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.22)) {
            hovered = index
        }
    }

    /// What the pointer at `point` should show: the sector at its angle anywhere on the ring
    /// or just around it; `.keep` in the hole, so crossing it doesn't drop the selection;
    /// `.leave` once it is well clear of the ring.
    private enum Target: Equatable { case sector(Int), keep, leave }

    private func target(at point: CGPoint) -> Target {
        let center = Self.frameSize / 2
        let dx = point.x - center
        let dy = point.y - center
        let radius = (dx * dx + dy * dy).squareRoot()
        if radius > center + 4 { return .leave }
        if radius < center * Self.restInner - 6 { return .keep }
        return sector(at: point).map(Target.sector) ?? .keep
    }

    /// The sector at `point`'s angle around the ring.
    private func sector(at point: CGPoint) -> Int? {
        let total = values.reduce(0, +)
        guard total > 0 else { return nil }
        let center = Self.frameSize / 2
        let dx = point.x - center
        let dy = point.y - center
        // Clockwise from twelve o'clock, then back into the chart's own unrotated angles.
        var angle = atan2(dx, -dy) * 180 / .pi - rotation
        angle = angle.truncatingRemainder(dividingBy: 360)
        if angle < 0 { angle += 360 }
        var end = 0.0
        for (index, value) in values.enumerated() where value > 0 {
            end += 360 * value / total
            if angle < end { return index }
        }
        return values.lastIndex { $0 > 0 }
    }

    @ViewBuilder private var center: some View {
        if let comparisonScore {
            Text(comparisonScore, format: .number)
                .font(.system(size: 37, weight: .bold))
        } else if shown == nil, let centerCaptionAtRest {
            Text(centerCaptionAtRest)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        } else {
            // One readout in every state: the glyph and share slots are kept (empty at rest),
            // so the figure never moves. The figures change at once - a rolling or fading
            // number smears while the pointer sweeps across sectors - and only the glyph fades.
            let total = values.reduce(0, +)
            let part = shown.flatMap { values.indices.contains($0) ? $0 : nil }
            let figure = part.map { values[$0] } ?? atDesk
            VStack(spacing: 1) {
                ZStack {
                    ForEach(Self.glyphs.indices, id: \.self) { index in
                        let glyph = Self.glyphs[index]
                        DeskGlyphShape(glyph)
                            .fill(colors[index])
                            .frame(width: 15 * glyph.aspectRatio, height: 15)
                            .opacity(part == index ? 1 : 0)
                    }
                }
                .frame(height: 15)
                .animation(.easeOut(duration: 0.12), value: part)
                Group {
                    DurationText(value: figure, size: 22)
                        .minimumScaleFactor(0.75)
                    Text(total > 0 ? (part.map { values[$0] } ?? 0) / total : 0,
                         format: .percent.precision(.fractionLength(0)))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .opacity(part == nil ? 0 : 1)
                }
                .transaction { $0.animation = nil }
            }
            .frame(width: 76)
        }
    }

    var body: some View {
        let total = values.reduce(0, +)
        ZStack {
            if total > 0 {
                // A pale concentric rim follows the screenshot, without an extruded drop shadow.
                ring
                    .scaleEffect(1.06)
                    .opacity(0.13)
                ring
            } else {
                Circle().stroke(.primary.opacity(0.07), lineWidth: 13.5)
                    .padding(6.75 + Self.popOut)
            }
            center
        }
        .frame(width: Self.frameSize, height: Self.frameSize)
        .contentShape(Circle())
        .onContinuousHover { phase in
            let target: Target
            switch phase {
            case .active(let point): target = self.target(at: point)
            case .ended: target = .leave
            }
            switch target {
            case .sector(let index):
                release?.cancel()
                release = nil
                select(index)
            case .keep:
                release?.cancel()
                release = nil
            case .leave:
                // A short grace, so brushing past the edge doesn't flash the total.
                guard hovered != nil, release == nil else { return }
                release = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                    release = nil
                    select(nil)
                }
            }
        }
        .onDisappear { release?.cancel() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Formatting.duration(atDesk)) at desk. Standing \(Formatting.duration(standing)), sitting \(Formatting.duration(sitting)), breaks \(Formatting.duration(breaks)).")
    }
}
