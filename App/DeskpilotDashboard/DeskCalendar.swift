import SwiftUI
import DeskpilotKit

/// A month of days to pick from, set out the way Calendar sets out a month: the month and year
/// with arrows to step, the weekdays, and the days, with today in red. Days with no history or
/// still to come can't be picked.
///
/// Coloured as Calendar colours its month: the shown day in the accent colour, its week or month
/// on a plain grey band, a grey circle under the pointer. The circle glides from day to day,
/// and in Week and Month the band slides through the grid with it to the week or month that
/// day would show, so what a click will do is plain before it's made; the shown day's circle
/// glides over when it is.
struct DeskCalendar: View {
    @Environment(DashboardModel.self) private var model
    /// A calendar day (its midnight) picked.
    let onPick: (Date) -> Void
    @State private var month: Date
    /// The grid cell under the pointer, when it's a day that can be picked.
    @State private var hovered: Int?
    /// The glides, worked out frame by frame.
    @State private var motion = GlideMotion()
    /// Bumped when the glides come to rest, so the frame clock can stop.
    @State private var settled = 0

    private static let cell = CGSize(width: 34, height: 36)
    private static let dot: CGFloat = 30
    private static let fade = Animation.easeOut(duration: 0.12)

    init(showing day: Date, onPick: @escaping (Date) -> Void) {
        self.onPick = onPick
        _month = State(initialValue: Calendar.current.dateInterval(of: .month, for: day)?.start ?? day)
        // Captures can hold a day under a pretend pointer: `DESKPILOT_DEV_CALENDAR_HOVER=11`.
        if let dev = ProcessInfo.processInfo.environment["DESKPILOT_DEV_CALENDAR_HOVER"].flatMap(Int.init) {
            _hovered = State(initialValue: dev)
        }
    }

    private var days: CalendarDays { CalendarDays(model: model) }

    var body: some View {
        VStack(spacing: 6) {
            header
            weekdays
            grid
        }
        .padding(12)
        .fixedSize()
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 2) {
            (Text(month.formatted(.dateTime.month(.wide))).fontWeight(.semibold)
                + Text(" " + month.formatted(.dateTime.year())).foregroundStyle(.secondary))
                .font(.system(size: 15))
                .padding(.leading, 6)
            Spacer(minLength: 12)
            Button { step(-1) } label: { Image(systemName: "chevron.left") }
                .disabled(!canStep(-1))
                .help("Previous month")
            Button { step(1) } label: { Image(systemName: "chevron.right") }
                .disabled(!canStep(1))
                .help("Next month")
        }
        .buttonStyle(MonthStepButtonStyle())
        .font(.system(size: 13, weight: .semibold))
    }

    private var weekdays: some View {
        HStack(spacing: 0) {
            ForEach(Array(days.weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: Self.cell.width)
            }
        }
    }

    // MARK: - Grid

    private var grid: some View {
        let days = self.days
        let dates = days.gridDays(for: month)
        let shownIndex = days.offset(of: days.shownDay, from: dates[0])
        let previewIndex = hovered.flatMap { $0 == shownIndex ? nil : $0 }
        let length = model.range.days
        // Where everything should be; the frame clock below glides it there.
        let bandEnd = previewIndex ?? shownIndex
        let atRest = motion.retarget(
            hover: hovered.map(Self.center),
            band: length > 1 ? (Double(bandEnd - length + 1), Double(bandEnd)) : nil,
            selection: (0..<42).contains(shownIndex) ? Self.center(shownIndex) : nil)
        _ = settled
        return ZStack(alignment: .topLeading) {
            TimelineView(.animation(paused: atRest)) { context in
                let rest = motion.advance(to: context.date)
                ZStack(alignment: .topLeading) {
                    if let band = motion.band {
                        BandShape(start: band.start, end: band.end, cell: Self.cell, dot: Self.dot)
                            .fill(.quinary)
                    }
                    // Head and tail of the hover circle: it stretches into a pill as it
                    // travels and draws back into a circle as it lands.
                    let (head, tail) = motion.hoverEnds
                    Capsule(style: .continuous)
                        .fill(.quaternary)
                        .frame(width: Self.dot + head.distance(to: tail), height: Self.dot)
                        .rotationEffect(.radians(tail.angle(to: head)))
                        .position(x: (head.x + tail.x) / 2, y: (head.y + tail.y) / 2)
                        .opacity(motion.hoverOpacity)
                    if let selection = motion.selection {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: Self.dot, height: Self.dot)
                            .position(selection)
                    }
                }
                .frame(width: Self.cell.width * 7, height: Self.cell.height * 6, alignment: .topLeading)
                .onChange(of: rest) { _, rest in if rest { settled &+= 1 } }
            }
            .allowsHitTesting(false)
            labels(dates, shownIndex: (0..<42).contains(shownIndex) ? shownIndex : nil)
        }
        .frame(width: Self.cell.width * 7, height: Self.cell.height * 6, alignment: .topLeading)
        // Each day takes the pointer as it arrives; only leaving the grid lets go, so passing
        // over a day that can't be picked doesn't snap the band back and out again.
        .onHover { inside in if !inside { hovered = nil } }
        .onReceive(NotificationCenter.default.publisher(for: .tempoDevCalendarHover)) { hovered = $0.object as? Int }
    }

    private func labels(_ dates: [Date], shownIndex: Int?) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<6, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { column in
                        let i = row * 7 + column
                        let selectable = days.isSelectable(dates[i])
                        dayLabel(dates[i], isShown: i == shownIndex)
                            .frame(width: Self.cell.width, height: Self.cell.height)
                            .contentShape(Rectangle())
                            .onHover { inside in if inside, selectable { hovered = i } }
                            .onTapGesture { if selectable { onPick(dates[i]) } }
                            .accessibilityAction { if selectable { onPick(dates[i]) } }
                    }
                }
            }
        }
    }

    private func dayLabel(_ date: Date, isShown: Bool) -> some View {
        let inMonth = Calendar.current.isDate(date, equalTo: month, toGranularity: .month)
        let isToday = date == days.today
        return Text("\(Calendar.current.component(.day, from: date))")
            .font(.system(size: 13, weight: isShown || isToday ? .semibold : .regular))
            .monospacedDigit()
            .foregroundStyle(isShown ? AnyShapeStyle(.white)
                             : !inMonth || !days.isSelectable(date) ? AnyShapeStyle(.tertiary)
                             : isToday ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
            .animation(Self.fade, value: isShown)
            .accessibilityLabel(date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
            .accessibilityAddTraits(days.isSelectable(date) ? (isShown ? [.isButton, .isSelected] : .isButton) : [])
    }

    // MARK: - Geometry

    private static func center(_ index: Int) -> CGPoint {
        CGPoint(x: (CGFloat(index % 7) + 0.5) * cell.width, y: (CGFloat(index / 7) + 0.5) * cell.height)
    }

    // MARK: - Stepping

    private func canStep(_ by: Int) -> Bool {
        days.adding(months: by, to: month).map(days.canShow(month:)) ?? false
    }

    private func step(_ by: Int) {
        guard canStep(by), let target = days.adding(months: by, to: month) else { return }
        // A new month's days arrive at once, and its band with them, rather than gliding
        // across from where the last month's were.
        motion.jump()
        hovered = nil
        month = target
    }
}

extension Notification.Name {
    /// Dev captures move the calendar's pretend pointer to a grid cell (an `Int`, or `nil`).
    static let tempoDevCalendarHover = Notification.Name("DeskpilotDevCalendarHover")
}

/// A run of days as one band that wraps from row to row, between two places in the grid
/// counted in days from its first cell (`end` inclusive). Fractional places draw a part of a
/// day, so the band can slide through the grid; a sliver too short for a capsule is a dot
/// growing into one.
private struct BandShape: Shape {
    var start: Double
    var end: Double
    let cell: CGSize
    let dot: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let inset = (cell.width - dot) / 2
        for row in 0..<6 {
            let first = Double(row * 7)
            let lo = max(start, first), hi = min(end + 1, first + 7)
            guard hi > lo else { continue }
            let x0 = CGFloat(lo - first) * cell.width + inset
            let x1 = CGFloat(hi - first) * cell.width - inset
            let width = max(x1 - x0, 0)
            let height = min(dot, max(width, 0.001))
            let midX = (x0 + x1) / 2, midY = (CGFloat(row) + 0.5) * cell.height
            let piece = CGRect(x: midX - max(width, height) / 2, y: midY - height / 2,
                               width: max(width, height), height: height)
            path.addRoundedRect(in: piece, cornerSize: CGSize(width: height / 2, height: height / 2), style: .continuous)
        }
        return path
    }
}

/// Springs stepped frame by frame for the calendar's glides. A spring sent somewhere new
/// mid-flight keeps its speed rather than starting over, and the edge leading the way moves
/// quicker than the one behind, so the band stretches as it slides and the hover circle
/// trails into a pill.
@MainActor
final class GlideMotion {
    private struct Spring {
        var value: Double
        var velocity: Double = 0
        var target: Double
        /// Seconds to settle; critically damped, so it never overshoots.
        var response: Double

        init(_ value: Double, response: Double) {
            self.value = value
            self.target = value
            self.response = response
        }

        mutating func step(_ dt: Double) {
            let omega = 2 * Double.pi / response
            velocity += (-omega * omega * (value - target) - 2 * omega * velocity) * dt
            value += velocity * dt
        }

        mutating func snap(_ to: Double) {
            value = to
            target = to
            velocity = 0
        }

        var atRest: Bool { abs(value - target) < 0.001 && abs(velocity) < 0.01 }
    }

    private static let lead = 0.14
    private static let trail = 0.24

    private var headX = Spring(0, response: lead), headY = Spring(0, response: lead)
    private var tailX = Spring(0, response: trail), tailY = Spring(0, response: trail)
    private var hoverAlpha = Spring(0, response: 0.1)
    private var bandStart = Spring(0, response: lead), bandEnd = Spring(0, response: lead)
    private var selectionX = Spring(0, response: 0.2), selectionY = Spring(0, response: 0.2)
    private var hasBand = false
    private var hasSelection = false
    private var snapNext = true
    private var lastFrame: Date?

    var hoverEnds: (head: CGPoint, tail: CGPoint) {
        (CGPoint(x: headX.value, y: headY.value), CGPoint(x: tailX.value, y: tailY.value))
    }
    var hoverOpacity: Double { min(max(hoverAlpha.value, 0), 1) }
    var band: (start: Double, end: Double)? { hasBand ? (bandStart.value, bandEnd.value) : nil }
    var selection: CGPoint? { hasSelection ? CGPoint(x: selectionX.value, y: selectionY.value) : nil }

    /// The next targets are taken at once, without gliding (a new month).
    func jump() { snapNext = true }

    /// Sends everything where it should be, and says whether it's already there.
    func retarget(hover: CGPoint?, band: (start: Double, end: Double)?, selection: CGPoint?) -> Bool {
        let snap = snapNext
        snapNext = false
        // Setting off from rest, the clock starts now rather than from whenever it last ran.
        if atRest { lastFrame = nil }
        if let hover {
            // Arriving from outside the grid: straight to the day, then fade in.
            if snap || hoverAlpha.value < 0.05 {
                headX.snap(hover.x); headY.snap(hover.y); tailX.snap(hover.x); tailY.snap(hover.y)
            } else {
                headX.target = hover.x; headY.target = hover.y; tailX.target = hover.x; tailY.target = hover.y
            }
            hoverAlpha.target = 1
        } else {
            hoverAlpha.target = 0
            if snap { hoverAlpha.snap(0) }
        }

        if let band {
            if snap || !hasBand {
                bandStart.snap(band.start)
                bandEnd.snap(band.end)
            } else if band.end != bandEnd.target {
                // The end in the direction of travel leads.
                let forward = band.end > bandEnd.target
                bandEnd.response = forward ? Self.lead : Self.trail
                bandStart.response = forward ? Self.trail : Self.lead
                bandStart.target = band.start
                bandEnd.target = band.end
            }
        }
        hasBand = band != nil

        if let selection {
            if snap || !hasSelection {
                selectionX.snap(selection.x)
                selectionY.snap(selection.y)
            } else {
                selectionX.target = selection.x
                selectionY.target = selection.y
            }
        }
        hasSelection = selection != nil
        return atRest
    }

    /// Steps everything on to `date`, and says whether it has all come to rest.
    @discardableResult
    func advance(to date: Date) -> Bool {
        let elapsed = lastFrame.map { min(date.timeIntervalSince($0), 1.0 / 20) } ?? 0
        lastFrame = date
        // Small fixed steps keep the springs steady whatever the frame rate.
        var remaining = max(elapsed, 0)
        while remaining > 0 {
            let dt = min(remaining, 1.0 / 480)
            for i in 0..<9 { step(i, dt) }
            remaining -= dt
        }
        return atRest
    }

    private func step(_ i: Int, _ dt: Double) {
        switch i {
        case 0: headX.step(dt)
        case 1: headY.step(dt)
        case 2: tailX.step(dt)
        case 3: tailY.step(dt)
        case 4: hoverAlpha.step(dt)
        case 5: bandStart.step(dt)
        case 6: bandEnd.step(dt)
        case 7: selectionX.step(dt)
        default: selectionY.step(dt)
        }
    }

    private var atRest: Bool {
        [headX, headY, tailX, tailY, hoverAlpha, bandStart, bandEnd, selectionX, selectionY].allSatisfy(\.atRest)
    }
}

private extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat { hypot(other.x - x, other.y - y) }
    func angle(to other: CGPoint) -> Double { distance(to: other) < 0.01 ? 0 : atan2(other.y - y, other.x - x) }
}

/// What the calendar needs to know about its days: which can be picked and which is shown.
/// Calendar days are their midnights.
@MainActor
struct CalendarDays {
    let model: DashboardModel
    var calendar: Calendar { Calendar.current }

    var today: Date { calendar.startOfDay(for: model.todayStart) }
    var shownDay: Date { calendar.startOfDay(for: model.selectedDayStart) }
    var firstDay: Date { model.firstDayStart.map { calendar.startOfDay(for: $0) } ?? today }

    func isSelectable(_ date: Date) -> Bool { date >= firstDay && date <= today }

    /// Whole days from `origin` to `date`, either way.
    func offset(of date: Date, from origin: Date) -> Int {
        calendar.dateComponents([.day], from: origin, to: date).day ?? 0
    }

    func month(of date: Date) -> Date { calendar.dateInterval(of: .month, for: date)?.start ?? date }

    /// Six weeks from the week the month starts in, so the grid never changes height.
    func gridDays(for month: Date) -> [Date] {
        let start = calendar.dateInterval(of: .weekOfMonth, for: month)?.start ?? month
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return (0..<7).map { symbols[($0 + calendar.firstWeekday - 1) % 7] }
    }

    func canShow(month target: Date) -> Bool {
        target >= month(of: firstDay) && target <= month(of: today)
    }

    func adding(months: Int, to month: Date) -> Date? {
        calendar.date(byAdding: .month, value: months, to: month)
    }
}

/// The month arrows as Calendar draws them: a grey chevron, and on hover a soft grey rounded
/// square behind it, a shade deeper while pressed. No accent colour: it's navigation, not a
/// choice.
private struct MonthStepButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Label(configuration: configuration)
    }

    private struct Label: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(isEnabled ? .secondary : .quaternary)
                .frame(width: 24, height: 22)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(.primary.opacity(configuration.isPressed ? 0.14 : hovering ? 0.08 : 0))
                }
                .contentShape(Rectangle())
                .onHover { hovering = isEnabled && $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}
