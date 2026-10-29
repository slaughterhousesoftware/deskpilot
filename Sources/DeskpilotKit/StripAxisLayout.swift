import Foundation

/// Chooses the hour labels for the menu's timeline strip. The day's first hour sits flush left
/// and its last flush right, and every candidate interval (every hour, two, three...) fills in
/// between them. A label that would touch an end steps aside; an interval whose own labels
/// would touch each other is out. Of the rest, the one that leaves the smallest empty stretch
/// on the axis wins, and among near ties the calmer, wider interval.
///
/// The interval depends only on the scale and the ends, never on the time now, so it holds
/// still all day; the time now's label then only moves aside the hour labels it touches.
public enum StripAxisLayout {
    /// A label's horizontal extent, in points.
    public struct Span: Equatable, Sendable {
        public var left: Double
        public var right: Double
        public init(left: Double, right: Double) {
            self.left = left
            self.right = right
        }
        public init(left: Double, width: Double) {
            self.init(left: left, right: left + width)
        }
    }

    /// One interval to consider: its hours' labels in order along the axis.
    public struct Option: Equatable, Sendable {
        public let step: Int
        public let labels: [Span]
        public init(step: Int, labels: [Span]) {
            self.step = step
            self.labels = labels
        }
    }

    /// The interval chosen and which of its labels are drawn (indices into its `labels`).
    public struct Choice: Equatable, Sendable {
        public let step: Int
        public let shown: [Int]
    }

    /// The least space between any two labels, in points.
    public static let gap: Double = 8

    /// The least space beside the time now's capsule, which has an edge of its own.
    public static let nowGap: Double = 4

    /// The interval for these ends, and which of its labels show beside `now`'s label.
    public static func plan(_ options: [Option], ends: [Span], now: Span?, gap: Double = gap, nowGap: Double = nowGap) -> Choice? {
        guard let choice = choose(options, fixed: ends, gap: gap),
              let option = options.first(where: { $0.step == choice.step }) else { return nil }
        guard let now else { return choice }
        let shown = choice.shown.filter { index in
            let label = option.labels[index]
            return label.right + nowGap <= now.left || now.right + nowGap <= label.left
        }
        return Choice(step: choice.step, shown: shown)
    }

    /// The interval that fills the axis most evenly around `fixed` labels. `tolerance` is how
    /// much larger an empty stretch a wider interval may leave and still be preferred.
    public static func choose(_ options: [Option], fixed: [Span], gap: Double = gap, tolerance: Double = 8) -> Choice? {
        func touches(_ a: Span, _ b: Span) -> Bool { a.left < b.right + gap && b.left < a.right + gap }

        var scored: [(choice: Choice, widest: Double)] = []
        for option in options {
            let shown = option.labels.indices.filter { index in
                !fixed.contains { touches($0, option.labels[index]) }
            }
            let kept = shown.map { option.labels[$0] }
            // Labels of the same interval that run into each other: too dense.
            if zip(kept, kept.dropFirst()).contains(where: { touches($0, $1) }) { continue }
            let all = (fixed + kept).sorted { $0.left < $1.left }
            let widest = zip(all, all.dropFirst()).map { $1.left - $0.right }.max() ?? 0
            scored.append((Choice(step: option.step, shown: shown), widest))
        }
        guard let best = scored.map(\.widest).min() else { return nil }
        return scored.filter { $0.widest <= best + tolerance }
            .max { $0.choice.step < $1.choice.step }?.choice
    }

    /// Where along an axis to centre the time now's capsule: on now, or moved off it by at most
    /// `maxShift` if that leaves more of the hour `labels` showing (a label shows if it keeps
    /// `gap` clear of the capsule; `half` is half the capsule's length). Fewest labels hidden
    /// wins, and among those, the smallest move.
    public static func nowCentre(now: Double, half: Double, maxShift: Double, labels: [Span],
                                 gap: Double = nowGap) -> Double {
        let reach = (now - maxShift)...(now + maxShift)
        let candidates = [now] + labels.flatMap { [$0.left - gap - half, $0.right + gap + half] }.filter(reach.contains)
        func hidden(_ centre: Double) -> Int {
            labels.filter { $0.right + gap > centre - half && centre + half + gap > $0.left }.count
        }
        return candidates.min { (hidden($0), abs($0 - now)) < (hidden($1), abs($1 - now)) } ?? now
    }
}

