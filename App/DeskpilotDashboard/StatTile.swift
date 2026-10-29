import SwiftUI
import DeskpilotKit

/// One of the four numbers across the top of the History tab: a tinted glyph, a caption, and a
/// large rounded figure, on a soft card.
struct StatTile: View {
    let title: String
    let value: String
    /// The desk pictogram for posture tiles; `systemImage` is the fallback for the rest.
    var glyph: DeskGlyph?
    var systemImage: String = "circle"
    let tint: Color
    /// A quieter second line under the figure. The row is reserved on every tile whether or
    /// not it has one, so the four cards stay the same height.
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let glyph {
                    DeskGlyphShape(glyph)
                        .fill(tint)
                        .frame(width: 16 * glyph.aspectRatio, height: 16)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 14, alignment: .leading)
                }
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(.title, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detail ?? " ")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .opacity(detail == nil ? 0 : 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(HierarchicalShapeStyle.quaternary.opacity(0.5),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(detail.map { "\(title): \(value), \($0)" } ?? "\(title): \(value)")
    }
}

/// The shared legend under both charts. Deliberately hand-built rather than Swift Charts'
/// own, so the two charts read as one picture with one key.
struct PostureLegend: View {
    var states: [PostureState] = PostureStyle.ordered

    var body: some View {
        HStack(spacing: 16) {
            ForEach(states, id: \.self) { state in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(PostureStyle.color(state))
                        .frame(width: 10, height: 10)
                    DeskGlyphShape(PostureStyle.glyph(state))
                        .fill(.secondary)
                        .frame(width: 14 * DeskGlyph.standing.aspectRatio, height: 14)
                    Text(PostureStyle.label(state))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// The spotlight's motion: it glides from one item to the next, settling without a bounce;
/// appearing and leaving is a quick fade.
enum HoverMotion {
    static let glide = Animation.spring(duration: 0.26, bounce: 0)
    static let fade = Animation.easeOut(duration: 0.14)
    /// How far everything but the hovered item recedes.
    static let dimmed = 0.32

    /// `last` follows `new` while something is hovered and stays put after, so the spotlight
    /// fades out where it was rather than snapping away. Arriving from nothing jumps straight
    /// there; moving between items glides.
    static func follow<Value>(_ old: Value?, _ new: Value?, last: inout Value?) {
        guard let new else { return }
        if old == nil {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { last = new }
        } else {
            withAnimation(glide) { last = new }
        }
    }
}

/// Masks a chart's marks so only `focus` stays at full strength and the rest recede.
struct SpotlightMask: View {
    let focus: CGRect?
    let active: Bool
    var cornerRadius: CGFloat = 6

    var body: some View {
        let rect = focus ?? .zero
        ZStack(alignment: .topLeading) {
            Rectangle().opacity(active ? HoverMotion.dimmed : 1)
                .animation(HoverMotion.fade, value: active)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The words inside the callouts, written the way the summary at the top writes its time.
enum CalloutText {
    /// "6h 8min", "45min".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int((seconds / 60).rounded()))
        let hours = minutes / 60
        return hours > 0 ? "\(hours)h \(minutes % 60)min" : "\(minutes)min"
    }

    /// "Sunday, Oct 18".
    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }
}

/// A session in the day chart: its posture in its colour, how long, and when.
struct SessionCallout: View {
    let segment: PostureSegment
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(PostureStyle.label(segment.state))
                .font(.caption.weight(.semibold))
                .foregroundStyle(PostureStyle.textColor(segment.state, scheme))
            Text(CalloutText.duration(segment.duration))
                .font(.title3.weight(.medium))
            Text((segment.start..<segment.end).formatted(.interval.hour().minute()))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .monospacedDigit()
    }
}

/// A whole day: its date, its time at the desk, and that time split into standing and sitting.
struct DayCallout: View {
    let day: Date
    let atDesk: TimeInterval
    /// Standing and sitting, when known; the heatmap only knows the total.
    var split: (standing: TimeInterval, sitting: TimeInterval)?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(CalloutText.day(day))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if atDesk > 0 {
                Text(CalloutText.duration(atDesk))
                    .font(.title3.weight(.medium))
                if let split {
                    Divider().padding(.top, 6).padding(.bottom, 5)
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 2) {
                        row(.standing, split.standing)
                        row(.sitting, split.sitting)
                    }
                    .font(.caption)
                }
            }
        }
        .monospacedDigit()
    }

    private func row(_ state: PostureState, _ seconds: TimeInterval) -> some View {
        GridRow {
            Text(PostureStyle.label(state))
                .fontWeight(.medium)
                .foregroundStyle(PostureStyle.textColor(state, scheme))
            Text(CalloutText.duration(seconds))
                .gridColumnAlignment(.trailing)
        }
    }
}
