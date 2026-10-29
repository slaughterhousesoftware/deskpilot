import Foundation

/// Calendar-aligned tick candidates for one native chart axis. Exact session times have
/// priority; Swift Charts performs the final text layout and collision resolution.
public enum TimelineAxisLayout {
    public static let minimumLabelSpacing: Double = 20

    public struct Session: Equatable, Sendable {
        public let start: Date
        public let end: Date?

        public init(start: Date, end: Date? = nil) {
            self.start = start
            self.end = end
        }
    }

    public enum Kind: Hashable, Sendable {
        case hour, start, end, range
    }

    public struct TickInterval: Equatable, Sendable {
        public let component: Calendar.Component
        public let count: Int
        let approximateSeconds: TimeInterval
    }

    public struct Plan: Sendable {
        public let labels: [Label]
        public let interval: TickInterval
    }

    public struct Label: Identifiable, Equatable, Sendable {
        public struct ID: Hashable, Sendable {
            let date: Date
            let end: Date?
            let kind: Kind
        }

        public let date: Date
        public let end: Date?
        public let kind: Kind
        public let text: String
        /// The native axis position: the label's middle. It is the event's own time unless
        /// the label is a combined range or had to move inside an edge to fit.
        public let positionDate: Date
        public let priority: Double
        public let tickX: Double
        public let left: Double
        public let width: Double
        public var id: ID { ID(date: date, end: end, kind: kind) }
        public var right: Double { left + width }
        public var isSession: Bool { kind != .hour }
    }

    /// Density depends on the scale and measured clock text, never on which sessions
    /// happen to be visible. Panning therefore keeps the same clock-aligned tick family.
    /// The measurer uses the renderer's font, including locale-specific text.
    public static func plan(
        in domain: ClosedRange<Date>, width: Double, sessions: [Session],
        calendar: Calendar = .current, locale: Locale = .current,
        minimumSpacing: Double = minimumLabelSpacing, edgeInset: Double = 2, contentInset: Double = 0,
        showWindowBounds: Bool = false,
        measure: (String, Bool) -> Double
    ) -> Plan? {
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        guard width.isFinite, width > 0, span.isFinite, span > 0,
              minimumSpacing.isFinite, edgeInset.isFinite,
              contentInset.isFinite, contentInset >= 0, width > 2 * contentInset else { return nil }
        let inset = max(0, edgeInset)
        let gap = max(0, minimumSpacing)
        let available = width - 2 * inset
        guard available > 0 else { return nil }

        let exact = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale,
                                     calendar: calendar, timeZone: calendar.timeZone)
        let hour = Date.FormatStyle(locale: locale, calendar: calendar,
                                    timeZone: calendar.timeZone).hour()
        let interval = Date.IntervalFormatStyle(date: .omitted, time: .shortened,
                                                locale: locale, calendar: calendar,
                                                timeZone: calendar.timeZone)

        func position(_ date: Date) -> Double {
            contentInset + date.timeIntervalSince(domain.lowerBound) / span * (width - 2 * contentInset)
        }

        func candidate(_ date: Date, kind: Kind, end: Date? = nil, text: String, priority: Double) -> Label? {
            guard domain.contains(date) else { return nil }
            let measured = measure(text, kind != .hour)
            guard measured.isFinite, measured > 0 else { return nil }
            let labelWidth = ceil(measured)
            guard labelWidth <= available else { return nil }
            let x = position(date)
            let center = end.map { (x + position($0)) / 2 } ?? x
            let left = min(width - inset - labelWidth, max(inset, center - labelWidth / 2))
            // The native axis centres each label on its position, so a label pushed inside an
            // edge (and a range, centred between its ends) is positioned at its own middle;
            // otherwise the window's first time would hang off the plot's leading edge.
            let middle = left + labelWidth / 2
            let positionDate = kind == .range || abs(middle - x) > 0.001
                ? domain.lowerBound.addingTimeInterval((middle - contentInset) / (width - 2 * contentInset) * span)
                : date
            return Label(date: date, end: end, kind: kind, text: text,
                         positionDate: positionDate, priority: priority, tickX: x, left: left, width: labelWidth)
        }

        func collides(_ a: Label, _ b: Label) -> Bool {
            a.left < b.right + gap && b.left < a.right + gap
        }

        var candidates: [Label] = []
        for session in sessions {
            let start = candidate(session.start, kind: .start, text: exact.format(session.start), priority: 300)
            let end = session.end.flatMap { date -> Label? in
                guard date > session.start else { return nil }
                return candidate(date, kind: .end, text: exact.format(date), priority: 300)
            }
            if let start, let end, collides(start, end),
               let combined = candidate(start.date, kind: .range, end: end.date,
                                        text: interval.format(start.date..<end.date), priority: 400) {
                candidates.append(combined)
            } else {
                if let start { candidates.append(start) }
                if let end { candidates.append(end) }
            }
        }

        if showWindowBounds {
            for date in [domain.lowerBound, domain.upperBound] {
                let text = calendar.component(.minute, from: date) == 0 ? hour.format(date) : exact.format(date)
                if let label = candidate(date, kind: .hour, text: text, priority: 40) { candidates.append(label) }
            }
        }

        // Choose one calendar interval before placing labels, rather than deleting pieces
        // of a fixed two-hour sequence. This is the calendar ladder used by time-scale
        // engines such as D3/ECharts, with a conservative pixel budget for readable labels.
        let reference = calendar.startOfDay(for: Date(timeIntervalSinceReferenceDate: 0))
        let clockWidths = (0..<24).compactMap { value -> Double? in
            guard let date = calendar.date(byAdding: .hour, value: value, to: reference) else { return nil }
            let measured = measure(hour.format(date), false)
            return measured.isFinite && measured > 0 ? measured : nil
        }
        guard let widestClockLabel = clockWidths.max() else { return nil }
        let pitch = max(96, 2 * widestClockLabel + gap)
        let tickBudget = max(1, floor((width - 2 * contentInset) / pitch))
        let target = span / tickBudget
        let intervals: [TickInterval] = [
            .init(component: .minute, count: 1, approximateSeconds: 60),
            .init(component: .minute, count: 5, approximateSeconds: 300),
            .init(component: .minute, count: 15, approximateSeconds: 900),
            .init(component: .minute, count: 30, approximateSeconds: 1800),
            .init(component: .hour, count: 1, approximateSeconds: 3600),
            .init(component: .hour, count: 2, approximateSeconds: 7200),
            .init(component: .hour, count: 3, approximateSeconds: 10800),
            .init(component: .hour, count: 4, approximateSeconds: 14400),
            .init(component: .hour, count: 6, approximateSeconds: 21600),
            .init(component: .hour, count: 12, approximateSeconds: 43200),
            .init(component: .day, count: 1, approximateSeconds: 86400),
            .init(component: .day, count: 2, approximateSeconds: 172800),
            .init(component: .day, count: 7, approximateSeconds: 604800),
        ]
        let stride = intervals.first { $0.approximateSeconds >= target } ?? intervals.last!

        func isTick(_ date: Date) -> Bool {
            switch stride.component {
            case .minute: return calendar.component(.minute, from: date).isMultiple(of: stride.count)
            case .hour: return calendar.component(.hour, from: date).isMultiple(of: stride.count)
            default:
                let days = calendar.dateComponents([.day], from: reference, to: date).day ?? 0
                return days.isMultiple(of: stride.count)
            }
        }

        var date = calendar.dateInterval(of: stride.component, for: domain.lowerBound)?.start
        var visited = 0
        var occupied = Set(candidates.map(\.positionDate))
        while let current = date, current <= domain.upperBound, visited < 10_080 {
            if isTick(current), !occupied.contains(current) {
                let clockHour = calendar.component(.hour, from: current)
                let minute = calendar.component(.minute, from: current)
                let priority: Double = minute != 0 ? 0 : clockHour.isMultiple(of: 12) ? 30 : clockHour.isMultiple(of: 6) ? 20 : 10
                let text = stride.component == .day
                    ? current.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale,
                                                         calendar: calendar, timeZone: calendar.timeZone))
                    : minute == 0 ? hour.format(current) : exact.format(current)
                if let label = candidate(current, kind: .hour, text: text, priority: priority) {
                    candidates.append(label)
                    occupied.insert(current)
                }
            }
            guard let next = calendar.date(byAdding: stride.component, value: 1, to: current), next > current else { break }
            date = next
            visited += 1
        }
        // A continuous session can cross a desk-day boundary: the previous day's end
        // and the next day's arrival share an instant. Give the native axis one mark.
        var seen = Set<Date>()
        let unique = candidates.sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            if $0.kind != $1.kind { return $0.kind == .start }
            return $0.date < $1.date
        }.filter { seen.insert($0.positionDate).inserted }
        return Plan(labels: unique.sorted { $0.positionDate < $1.positionDate }, interval: stride)
    }
}
