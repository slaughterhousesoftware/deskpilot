import OSLog
import Charts
import SwiftUI
import DeskpilotKit

/// The week and month charts' scrolling, step by step - what the trackpad sent and where each
/// glide was aimed. `log show --predicate 'category == "scroll"' --debug`.
private let scrollLog = Logger(subsystem: "com.kevinpatel.tempo", category: "scroll")

/// A compact graph with an always-visible yearly heatmap.
/// The window follows the content height without a second scrolling surface.
struct HistoryView: View {
    @Environment(DashboardModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.hasHistory {
                HistoryContent()
            } else {
                emptyState
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            VStack(spacing: 12) {
                DeskGlyphShape(.standing)
                    .fill(.secondary)
                    .frame(width: 48, height: 48)
                Text("No desk history yet")
                    .font(.title3.weight(.semibold))
            }
        } description: {
            Text("Once the Deskpilot menu bar app has connected to your desk, your standing, sitting and away time will show up here.")
        } actions: {
            Button("Open Deskpilot") { model.openMenuBarApp() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }
}

/// The dashboard's date navigation, activity summary and two chart panels.
struct HistoryContent: View {
    @Environment(DashboardModel.self) private var model

    var body: some View {
        if let grouping = ActivityGroupingStudy.current {
            ActivityDashboard(grouping: grouping)
        } else if NativeLayoutStudy.current == .orbit || NativeLayoutStudy.current == .editorial {
            ProportionStudyView(centered: NativeLayoutStudy.current == .orbit)
        } else if NativeLayoutStudy.current == .unified {
            UnifiedLayoutStudyView()
        } else if let study = NativeLayoutStudy.current {
            NativeLayoutStudyView(study: study)
        } else {
            CompactActivityDashboard()
        }
    }
}

/// Alternative card groupings for development previews. The app uses three cards.
private enum ActivityGroupingStudy: String {
    case usageAndYear, separate, unified

    static let current = ProcessInfo.processInfo.environment["DESKPILOT_DEV_GROUPING"]
        .flatMap(Self.init(rawValue:))
}

private struct CompactActivityDashboard: View {
    @Environment(DashboardModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @State private var heatmapWidth: CGFloat = 0
    private var figures: RingFigures { model.ringFigures }
    private var isInteracting: Bool {
        !model.summaryIsSettling && (model.summaryDayWindow != nil || model.summaryPeriodOffset != nil)
    }
    private func number(_ value: Double, _ format: SummaryNumberFormat, alignment: HorizontalAlignment = .leading) -> some View {
        SummaryNumber(value: value, format: format, isInteracting: isInteracting, alignment: alignment)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The figure's line leaves room below for descenders it has none of: pulled up into
            // it, the caption sits snug under the figure.
            VStack(alignment: .leading, spacing: -3) {
                number(figures.atDesk, .duration)
                    .font(.system(size: 28, weight: .medium)).monospacedDigit()
                Text(model.range == .day ? "Time at desk" : "Daily average at desk")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)

            VStack(alignment: .leading, spacing: 0) {
                if !DevPerfDriver.omits("controls") { ActivityDateControls(fillsWidth: true, regularSize: true) }
                if !DevPerfDriver.omits("chart") { RangeCharts() }
                if !DevPerfDriver.omits("balance") { balance.padding(.top, 24) }
            }
            .padding(16)
            .background(panel)

            // As wide as the card less its 16-point margins, like the card above: the squares
            // size themselves to it, and Mon, Wed and Fri start at the margin.
            if !DevPerfDriver.omits("heatmap") {
            DeskHeatmap(days: model.heatmap, selectedDays: model.highlightedHeatmapDays,
                        selectionFraction: model.heatmapPreviewFraction,
                        onSelect: model.select, fitWidth: heatmapWidth > 0 ? heatmapWidth : nil)
                .animation(.interactiveSpring(response: 0.24, dampingFraction: 0.9), value: model.heatmapSelectionPosition)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { heatmapWidth = $0 }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(panel)
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
    }

    private var panel: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(scheme == .dark ? Color(white: 0.15) : .white)
    }

    private var balance: some View {
        ActivityBalanceSummary(figures: figures, isInteracting: isInteracting)
    }
}

/// The standing and sitting split under the activity chart: percentages, the bar, durations.
private struct ActivityBalanceSummary: View {
    let figures: RingFigures
    let isInteracting: Bool
    @Environment(\.colorScheme) private var scheme

    private var standingPercent: Int {
        figures.atDesk > 0 ? Int((100 * min(1, max(0, figures.standing / figures.atDesk))).rounded()) : 0
    }
    private var sittingPercent: Int { figures.atDesk > 0 ? 100 - standingPercent : 0 }
    private var standingText: Color {
        scheme == .dark ? DeskpilotAppearance.standing : Color(red: 0, green: 0.46, blue: 0.42)
    }
    private var sittingText: Color {
        scheme == .dark ? DeskpilotAppearance.sitting : Color(red: 0, green: 0.37, blue: 0.73)
    }
    private func number(_ value: Double, _ format: SummaryNumberFormat, alignment: HorizontalAlignment = .leading) -> some View {
        SummaryNumber(value: value, format: format, isInteracting: isInteracting, alignment: alignment)
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                number(Double(standingPercent), .standingPercent).foregroundStyle(standingText)
                Spacer()
                number(Double(sittingPercent), .sittingPercent, alignment: .trailing).foregroundStyle(sittingText)
            }.font(.system(size: 12, weight: .semibold)).monospacedDigit()
            AnimatedBalanceBar(figures: figures, isInteracting: isInteracting)
            HStack {
                number(figures.standing, .duration).foregroundStyle(standingText)
                Spacer()
                number(figures.sitting, .duration, alignment: .trailing).foregroundStyle(sittingText)
            }.font(.system(size: 12, weight: .semibold)).monospacedDigit()
        }
    }
}

private struct BalanceBarValue: Hashable {
    let standingShare: Double
    let hasDeskTime: Bool

    init(_ figures: RingFigures) {
        hasDeskTime = figures.atDesk > 0
        standingShare = hasDeskTime ? min(1, max(0, figures.standing / figures.atDesk)) : 0
    }
}

private struct BalanceBarShape: View, Animatable {
    var share: Double
    var presence: Double
    init(value: BalanceBarValue) {
        share = value.standingShare
        presence = value.hasDeskTime ? 1 : 0
    }

    // Interpolate one split, then derive both sides from it on each display frame.
    // This keeps the divider and the three-point gap together during retargeting.
    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(share, presence) }
        set { share = newValue.first; presence = newValue.second }
    }

    var body: some View {
        GeometryReader { geometry in
            let split = min(1, max(0, share))
            let opacity = min(1, max(0, presence))
            let gap = min(3, max(0, geometry.size.width) * min(split, 1 - split))
            let width = max(0, geometry.size.width - gap)
            ZStack {
                Capsule().fill(Color.secondary.opacity(0.15)).opacity(1 - opacity)
                HStack(spacing: gap) {
                    Capsule().fill(DeskpilotAppearance.standing)
                        .frame(width: width * split)
                    Capsule().fill(DeskpilotAppearance.sitting)
                        .frame(width: width * (1 - split))
                }.opacity(opacity)
            }
        }
    }
}

/// Follows a scroll with a short, critically damped response, so the split keeps up with the
/// fingers without bouncing.
private struct AnimatedBalanceBar: View {
    let figures: RingFigures
    let isInteracting: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayed: BalanceBarValue

    init(figures: RingFigures, isInteracting: Bool) {
        self.figures = figures
        self.isInteracting = isInteracting
        _displayed = State(initialValue: BalanceBarValue(figures))
    }

    private struct Update: Equatable {
        let value: BalanceBarValue
        let reducedMotion: Bool
    }

    var body: some View {
        BalanceBarShape(value: displayed)
            .frame(height: 4)
            .onChange(of: Update(value: BalanceBarValue(figures), reducedMotion: reduceMotion), initial: true) { _, update in
                guard update.value != displayed else { return }
                if reduceMotion {
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { displayed = update.value }
                } else {
                    // Retargets from the current pose and velocity instead of restarting an
                    // ease for every trackpad event.
                    withTransaction(Transaction(animation: .interactiveSpring(response: 0.16, dampingFraction: 1, blendDuration: 0.08))) {
                        displayed = update.value
                    }
                }
            }
    }
}

private enum SummaryNumberFormat: Hashable {
    case duration, standingPercent, sittingPercent

    func string(_ value: Double) -> String {
        switch self {
        case .duration: return ActivityDuration.string(max(0, value))
        case .standingPercent: return "\(Int(min(100, max(0, value)).rounded()))% standing"
        case .sittingPercent: return "\(Int(min(100, max(0, value)).rounded()))% sitting"
        }
    }
}

/// Ordinary text, so a fade crossfades whole numbers rather than morphing their glyphs.
private struct InterpolatedSummaryNumber: View, Animatable {
    var value: Double
    let format: SummaryNumberFormat
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }
    var body: some View {
        Text(format.string(value)).contentTransition(.identity).lineLimit(1)
    }
}

/// A summary figure that changes directly while the chart is being scrolled, then softly
/// fades to its final value once it settles.
private struct SummaryNumber: View {
    let value: Double
    let format: SummaryNumberFormat
    let isInteracting: Bool
    let alignment: HorizontalAlignment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedValue: Double
    @State private var previousValue: Double
    @State private var blend = 1.0

    init(value: Double, format: SummaryNumberFormat, isInteracting: Bool, alignment: HorizontalAlignment) {
        self.value = value
        self.format = format
        self.isInteracting = isInteracting
        self.alignment = alignment
        _displayedValue = State(initialValue: value)
        _previousValue = State(initialValue: value)
    }

    private struct Update: Hashable {
        let value: Double
        let interacting: Bool
        let reducedMotion: Bool
    }

    var body: some View {
        Group {
            if !reduceMotion {
                ZStack(alignment: Alignment(horizontal: alignment, vertical: .center)) {
                    InterpolatedSummaryNumber(value: previousValue, format: format)
                        .opacity(1 - blend).accessibilityHidden(true)
                    InterpolatedSummaryNumber(value: displayedValue, format: format)
                        .opacity(blend)
                }
            } else {
                InterpolatedSummaryNumber(value: value, format: format)
            }
        }
        .task(id: Update(value: value, interacting: isInteracting, reducedMotion: reduceMotion)) {
            guard !reduceMotion, !isInteracting, displayedValue != value else {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { displayedValue = value; previousValue = value; blend = 1 }
                return
            }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { previousValue = displayedValue; displayedValue = value; blend = 0 }
            withAnimation(.easeInOut(duration: 0.18)) { blend = 1 }
        }
    }
}

private struct ActivityDashboard: View {
    @Environment(DashboardModel.self) private var model
    let grouping: ActivityGroupingStudy

    init(grouping: ActivityGroupingStudy = .separate) {
        self.grouping = grouping
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 12) {
            ActivityCardHeader("Activity") {
                if grouping == .separate {
                    ActivityDateControls().fixedSize()
                }
            }
            Group {
                switch model.range {
                case .day: DayScroller()
                case .week, .month: PeriodScroller(range: model.range).id(model.range)
                }
            }
        }
    }

    private var year: some View {
        VStack(alignment: .leading, spacing: 12) {
            ActivityCardHeader("Past year") {
                Text(model.todayStart.formatted(.dateTime.year()))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            DeskHeatmap(days: model.heatmap,
                        selectedDays: model.highlightedHeatmapDays,
                        selectionFraction: model.heatmapPreviewFraction,
                        onSelect: model.select)
                .animation(.interactiveSpring(response: 0.24, dampingFraction: 0.9), value: model.heatmapSelectionPosition)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch grouping {
            case .usageAndYear:
                InsightCard {
                    VStack(alignment: .leading, spacing: 16) {
                        ActivitySummary()
                        timeline
                    }
                }
                InsightCard { year }
            case .separate:
                InsightCard { ActivitySummary(showsDateControls: false) }
                InsightCard { timeline }
                InsightCard { year }
            case .unified:
                InsightCard {
                    VStack(alignment: .leading, spacing: 16) {
                        ActivitySummary()
                        timeline
                        Divider().padding(.vertical, 4)
                        year
                    }
                }
            }
        }
        .padding(.horizontal, 8)
    }
}

/// Matching title rows keep both chart cards aligned with their trailing controls.
private struct ActivityCardHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder let trailing: () -> Trailing

    init(_ title: String, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            trailing()
        }
        .frame(minHeight: 28, alignment: .center)
    }
}

/// Review-only compositions. The installed layout is unchanged unless this flag is set.
private enum CleanHeaderStudy: String {
    case quietRing, dateRing, trailingRing, thinBar, compactBar, compactRing

    static let current = ProcessInfo.processInfo.environment["DESKPILOT_DEV_HEADER"]
        .flatMap(Self.init(rawValue:))
}

/// Native buttons and native chart marks, sharing the regular dashboard's data and actions.
private struct CleanHeaderView: View {
    @Environment(DashboardModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    let study: CleanHeaderStudy

    private var dates: String {
        let end = model.selectedDayStart
        if model.range == .day {
            return end.formatted(.dateTime.weekday(.wide).month(.wide).day())
        }
        let start = model.day(-(model.range.days - 1), from: end)
        return (start..<end).formatted(.interval.month(.abbreviated).day())
    }

    private var caption: String {
        model.range == .day ? "At desk" : "Daily average at desk"
    }

    private func step(_ forward: Bool) -> some View {
        Button {
            if forward { model.goToNextDay() } else { model.goToPreviousDay() }
        } label: {
            Image(systemName: forward ? "chevron.right" : "chevron.left")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .disabled(forward ? !model.canGoForward : !model.canGoBack)
        .opacity((forward ? model.canGoForward : model.canGoBack) ? 1 : 0.35)
        .accessibilityLabel(forward ? "Next period" : "Previous period")
        .help(forward ? "Next period (⌘→)" : "Previous period (⌘←)")
    }

    private var today: some View {
        Button("Today") { model.goToToday() }
            .buttonStyle(.borderless)
            .font(.subheadline)
            .foregroundStyle(.primary)
            .padding(.horizontal, 4)
            .help("Return to today (⌘T)")
    }

    @ViewBuilder private var navigation: some View {
        switch study {
        case .dateRing:
            HStack(spacing: 4) {
                step(false)
                Text(dates).font(.headline).fixedSize()
                step(true)
                Spacer()
                today
            }
            .padding(.leading, -8)
        case .trailingRing:
            HStack(spacing: 4) {
                today
                Spacer()
                step(false)
                Text(dates).font(.subheadline.weight(.medium)).fixedSize()
                step(true)
            }
            .padding(.horizontal, -4)
        case .compactRing:
            HStack(spacing: 4) {
                step(false)
                step(true)
                Text(dates).font(.headline).padding(.leading, 6)
                Spacer()
                today
            }
            .padding(.leading, -8)
        case .compactBar:
            HStack(spacing: 4) {
                Text(dates).font(.headline)
                Spacer()
                today
                step(false)
                step(true)
            }
            .padding(.trailing, -8)
        case .quietRing, .thinBar:
            HStack(spacing: 4) {
                Text(dates).font(.headline)
                Spacer()
                step(false)
                today
                step(true)
            }
            .padding(.trailing, -8)
        }
    }

    private func number(_ size: CGFloat = 34) -> some View {
        let text = Formatting.duration(model.ringFigures.atDesk)
            .split(separator: " ")
            .reduce(Text("")) { result, part in
                result + Text(String(part.dropLast()))
                    .font(.system(size: size, weight: .semibold, design: .rounded))
                + Text(String(part.suffix(1)))
                    .font(.system(size: size * 0.55, weight: .medium, design: .rounded))
                    .foregroundColor(.secondary)
        }
        return text
        .monospacedDigit()
        .fixedSize()
        .accessibilityLabel("\(Formatting.duration(model.ringFigures.atDesk)) at desk")
    }

    private var readout: some View {
        VStack(alignment: .leading, spacing: 2) {
            number()
            Text(caption).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var values: [TimeInterval] {
        let f = model.ringFigures
        return [max(0, f.standing), max(0, f.breaks), max(0, f.sitting)]
    }

    private var colours: [Color] {
        [DeskpilotAppearance.standing, PostureStyle.breakColor(scheme), DeskpilotAppearance.sitting]
    }

    private func ring(_ size: CGFloat = 48) -> some View {
        let total = values.reduce(0, +)
        return Chart {
            ForEach(0..<3, id: \.self) { index in
                SectorMark(angle: .value("Duration", values[index]),
                           innerRadius: .ratio(0.73), angularInset: 1.8)
                    .cornerRadius(2)
                    .foregroundStyle(colours[index])
            }
        }
        .chartLegend(.hidden)
        .rotationEffect(.degrees(total > 0 ? -360 * values[0] / total : 0))
        .frame(width: size, height: size)
        .accessibilityLabel("Standing, sitting and breaks distribution")
    }

    private var allocation: some View {
        let total = max(1, values.reduce(0, +))
        return GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach([0, 2, 1], id: \.self) { index in
                    Rectangle().fill(colours[index])
                        .frame(width: max(0, geometry.size.width - 4) * values[index] / total)
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 5)
        .accessibilityLabel("Standing, sitting and breaks distribution")
    }

    private func legendItem(_ title: String, _ value: TimeInterval, _ colour: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5).fill(colour).frame(width: 5, height: 5)
            Text(title).foregroundStyle(.secondary)
            Text(Formatting.duration(value)).foregroundStyle(.primary).monospacedDigit()
        }
        .font(.system(size: 12))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private var legend: some View {
        let f = model.ringFigures
        return HStack(spacing: 18) {
            legendItem("Standing", f.standing, DeskpilotAppearance.standing)
            legendItem("Sitting", f.sitting, DeskpilotAppearance.sitting)
            legendItem("Breaks", f.breaks, PostureStyle.breakColor(scheme))
        }
    }

    @ViewBuilder private var summary: some View {
        switch study {
        case .quietRing, .dateRing:
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) { ring(); readout }
                legend
            }
        case .trailingRing:
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    readout
                    Spacer()
                    ring()
                }
                legend
            }
        case .thinBar:
            VStack(alignment: .leading, spacing: 12) {
                readout
                allocation
                legend
            }
        case .compactBar:
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    number(32)
                    Text(caption).font(.subheadline).foregroundStyle(.secondary)
                }
                allocation
                legend
            }
        case .compactRing:
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    ring(40)
                    number(30)
                    Text(caption).font(.subheadline).foregroundStyle(.secondary)
                }
                legend
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            navigation
            summary
        }
        .padding(.top, 8)
        .padding(.bottom, 8)
    }
}

private struct ActivityDateControls: View {
    var fillsWidth = false
    var regularSize = false
    var centerReadout: String? = nil
    @Environment(DashboardModel.self) private var model
    @State private var choosingDate = false

    private func dateTitle(endingAt end: Date) -> String {
        if model.range == .day {
            let date = end.formatted(.dateTime.month(.wide).day())
            if end == model.todayStart { return "Today, \(date)" }
            if end == model.day(-1, from: model.todayStart) { return "Yesterday, \(date)" }
            return end.formatted(.dateTime.weekday(.wide).month(.wide).day())
        }
        return (model.day(-(model.range.days - 1), from: end)..<end)
            .formatted(.interval.month(.abbreviated).day().year())
    }

    /// The calendar's selection: the shown day, and picking one goes straight to it.
    private var calendarSelection: Binding<Date> {
        Binding(get: { model.selectedDayStart }, set: { date in
            // A calendar date means that desk day, including before the morning boundary:
            // normalise from noon rather than from midnight.
            let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
            let day = model.dayStart(containing: noon)
            // The day already shown just closes the calendar.
            guard day != model.selectedDayStart else {
                choosingDate = false
                return
            }
            model.select(day)
            // Long enough to see the day take the circle, then out of the way.
            Task {
                try? await Task.sleep(for: .milliseconds(180))
                choosingDate = false
            }
        })
    }

    /// The date is a control like the stepping ones beside it: the same grey bordered button,
    /// with a calendar at its head and a pull-down's chevron at its tail, so it plainly opens
    /// something. It opens a month calendar in a popover, as Calendar and
    /// Health do, and a day picked there is shown at once.
    var body: some View {
        HStack(spacing: 12) {
            Button { choosingDate.toggle() } label: {
                // A Mac pull-down button's parts: the icon close to its title, and the single
                // small chevron after it that says a click opens something.
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                        .foregroundStyle(.secondary)
                    Text(dateTitle(endingAt: model.selectedDayStart))
                        .foregroundStyle(.primary)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    // The pop-up button's own glyph, at the size macOS draws it beside a title.
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 2)
                }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 6))
            .controlSize(regularSize ? .regular : .large)
            .tint(.primary)
            .fixedSize()
            .accessibilityLabel("Displayed date, \(dateTitle(endingAt: model.selectedDayStart)). Choose a date")
            .help("Choose a date")
            .popover(isPresented: $choosingDate, arrowEdge: .bottom) {
                DeskCalendar(showing: model.selectedDayStart) { date in calendarSelection.wrappedValue = date }
                    .environment(model)
            }
            .task {
                // Captures open it once the dev snapshot has moved to the day it shows.
                guard ProcessInfo.processInfo.environment["DESKPILOT_DEV_DATE_PICKER"] == "1" else { return }
                try? await Task.sleep(for: .milliseconds(450))
                choosingDate = true
            }
            if let centerReadout {
                Spacer(minLength: 12)
                VStack(spacing: 2) {
                    Text(model.range == .day ? "At desk" : "Daily average").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(centerReadout).font(.system(size: 19, weight: .medium)).monospacedDigit().lineLimit(1)
                }.fixedSize()
                Spacer(minLength: 12)
            } else if fillsWidth { Spacer(minLength: 12) }
            HStack(spacing: 4) {
                step(forward: false)
                Button { model.goToToday() } label: {
                    Text("Today").foregroundStyle(.primary)
                }
                    .help("Return to today (⌘T)")
                step(forward: true)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 6))
            .controlSize(regularSize ? .regular : .large)
            .tint(.primary)
            .fixedSize()
        }
    }

    private func step(forward: Bool) -> some View {
        Button {
            if forward { model.goToNextDay() } else { model.goToPreviousDay() }
        } label: {
            Label(forward ? "Next \(model.range.title.lowercased())" : "Previous \(model.range.title.lowercased())",
                  systemImage: forward ? "chevron.right" : "chevron.left")
                .labelStyle(.iconOnly)
        }
        .disabled(forward ? !model.canGoForward : !model.canGoBack)
        .help(forward ? "Next \(model.range.title.lowercased()) (⌘→)"
                      : "Previous \(model.range.title.lowercased()) (⌘←)")
    }
}

private struct ActivitySummary: View {
    @Environment(DashboardModel.self) private var model
    var showsDateControls = true

    var body: some View {
        let f = model.ringFigures
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .center, spacing: 16) {
                    Text(ActivityDuration.string(f.atDesk))
                        .font(.system(size: 38, weight: .regular))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                        .accessibilityLabel("\(model.range == .day ? "Time at desk" : "Daily average at desk"), \(ActivityDuration.string(f.atDesk))")
                        .help(model.range == .day ? "For the displayed day and time window" : "Across days with desk activity")
                    Spacer(minLength: 0)
                    if showsDateControls {
                        ActivityDateControls()
                            .fixedSize()
                    }
                }
                Text(model.range == .day ? "Time at desk" : "Daily average at desk")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityHidden(true)
            }
            .padding(.top, 8)

            ActivityBreakdown()
        }
        .padding(.vertical, 2)
    }
}

/// Screen Time uses full-size units and a regular system face in its usage readout.
private enum ActivityDuration {
    static func string(_ value: TimeInterval) -> String {
        let minutes = max(0, Int(value.rounded()) / 60)
        let hours = minutes / 60
        return hours > 0 ? "\(hours)h \(minutes % 60)min" : "\(minutes)min"
    }
}

/// Category labels and values stay together on one quiet line.
private struct ActivityBreakdown: View {
    @Environment(DashboardModel.self) private var model
    @Environment(\.colorScheme) private var scheme

    private func figure(_ title: String, value: TimeInterval, colour: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5).fill(colour).frame(width: 5, height: 5)
            Text(title).foregroundStyle(.secondary)
            Text(ActivityDuration.string(value)).monospacedDigit()
        }
        .font(.system(size: 12))
        .fixedSize()
        .accessibilityElement(children: .combine)
        .help(model.range == .day ? "\(title) time in the displayed day and time window"
                                  : "Daily average \(title.lowercased()) time across days with desk activity")
    }

    var body: some View {
        let f = model.ringFigures
        HStack(spacing: 18) {
            figure("Standing", value: f.standing, colour: DeskpilotAppearance.standing)
            figure("Sitting", value: f.sitting, colour: DeskpilotAppearance.sitting)
            figure("Breaks", value: f.breaks, colour: PostureStyle.breakColor(scheme))
            Spacer(minLength: 0)
        }
    }
}

/// Developer-only alternatives rendered with the actual macOS toolbar and controls.
enum NativeLayoutStudy: String {
    case focus, overview, details, unified, orbit, editorial
    static let current = ProcessInfo.processInfo.environment["DESKPILOT_DEV_LAYOUT"].flatMap(Self.init(rawValue:))
    static let usesSectionTabs = ProcessInfo.processInfo.environment["DESKPILOT_DEV_NAV"] == "sections"
}

/// Two working compositions for reviewing hierarchy before changing the installed app.
/// They share the real controls, figures and scrolling views with the regular dashboard.
private struct ProportionStudyView: View {
    @Environment(DashboardModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    let centered: Bool

    private var dates: String {
        let end = model.selectedDayStart
        if model.range == .day {
            return end.formatted(.dateTime.weekday(.wide).month(.wide).day())
        }
        let start = model.day(-(model.range.days - 1), from: end)
        return (start..<end).formatted(.interval.month(.abbreviated).day())
    }

    private var title: String {
        guard model.selectedDayStart == model.todayStart else { return dates }
        switch model.range {
        case .day: return "Today"
        case .week: return "This week"
        case .month: return "Past 30 days"
        }
    }

    private var context: String {
        model.range == .day ? "At desk" : "Daily average at desk"
    }

    private func stepButton(forward: Bool) -> some View {
        Button {
            if forward { model.goToNextDay() } else { model.goToPreviousDay() }
        } label: {
            Image(systemName: forward ? "chevron.right" : "chevron.left")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(forward ? !model.canGoForward : !model.canGoBack)
        .accessibilityLabel(forward ? "Next period" : "Previous period")
        .help(forward ? "Next period (⌘→)" : "Previous period (⌘←)")
    }

    private var dateNavigation: some View {
        HStack(spacing: 4) {
            stepButton(forward: false)
            if centered {
                Text(dates).font(.subheadline.weight(.medium))
                    .frame(minWidth: 180)
            }
            stepButton(forward: true)
        }
        .foregroundStyle(.secondary)
    }

    private var todayButton: some View {
        Button("Today") { model.goToToday() }
            .buttonStyle(.borderless)
            .font(.subheadline)
            .help("Return to today (⌘T)")
    }

    private var ring: some View {
        let f = model.ringFigures
        return DeskDurationRing(atDesk: f.atDesk, standing: f.standing,
                                sitting: f.sitting, breaks: f.breaks,
                                centerCaptionAtRest: centered ? nil : "Posture\nmix")
    }

    private func metric(_ title: String, value: TimeInterval, color: Color) -> some View {
        VStack(alignment: centered ? .center : .leading, spacing: 6) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 6, height: 6)
                Text(title).font(.subheadline).foregroundStyle(.secondary)
            }
            DurationText(value: value, size: centered ? 23 : 25)
        }
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
        .accessibilityElement(children: .combine)
    }

    private var metrics: some View {
        let f = model.ringFigures
        return HStack(spacing: 24) {
            metric("Standing", value: f.standing, color: DeskpilotAppearance.standing)
            metric("Sitting", value: f.sitting, color: DeskpilotAppearance.sitting)
            metric("Breaks", value: f.breaks, color: PostureStyle.breakColor(scheme))
        }
    }

    @ViewBuilder private var chart: some View {
        switch model.range {
        case .day: DayScroller()
        case .week, .month: PeriodScroller(range: model.range).id(model.range)
        }
    }

    private var year: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Year in review").font(.subheadline.weight(.semibold))
                Spacer()
                Text(model.todayStart.formatted(.dateTime.year()))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)
            DeskHeatmap(days: model.heatmap, selectedDays: model.highlightedHeatmapDays,
                        selectionFraction: model.heatmapPreviewFraction,
                        onSelect: model.select)
                .animation(.interactiveSpring(response: 0.24, dampingFraction: 0.9), value: model.heatmapSelectionPosition)
                .frame(maxWidth: .infinity)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if centered {
                dateNavigation
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .trailing) { todayButton }
                    .padding(.top, 8)
                VStack(spacing: 6) {
                    ring.scaleEffect(1.45).frame(width: 180, height: 180)
                    Text(context).font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 15)
                metrics.padding(.top, 25).padding(.bottom, 26)
            } else {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title).font(.title2.weight(.semibold))
                        if title != dates {
                            Text(dates).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    dateNavigation
                    todayButton.padding(.leading, 10)
                }
                .padding(.top, 14)
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(context).font(.subheadline).foregroundStyle(.secondary)
                        DurationText(value: model.ringFigures.atDesk, size: 60)
                    }
                    Spacer()
                    ring.scaleEffect(1.08).frame(width: 134, height: 134)
                }
                .padding(.top, 20)
                metrics.padding(.top, 12).padding(.bottom, 25)
            }
            Divider()
            HStack {
                Text("Activity").font(.subheadline.weight(.semibold))
                Spacer()
                Text(model.range == .day ? "Hourly timeline" : "\(model.range.days) days")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 18)
            chart.padding(.top, 0).padding(.bottom, 22)
            Divider()
            year.padding(.top, 18)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }
}

/// A developer-only layout comparison; the installed dashboard keeps its current layout.
private struct UnifiedLayoutStudyView: View {
    @Environment(DashboardModel.self) private var model
    @Environment(\.colorScheme) private var scheme

    private var dates: String {
        let end = model.selectedDayStart
        if model.range == .day {
            return end.formatted(.dateTime.weekday(.wide).month(.wide).day())
        }
        return (model.day(-(model.range.days - 1), from: end)..<end)
            .formatted(.interval.month(.abbreviated).day().year())
    }

    private func metric(_ title: String, value: TimeInterval, colour: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Circle().fill(colour).frame(width: 6, height: 6)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            DurationText(value: value, size: 22)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    var body: some View {
        let figures = model.ringFigures
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                Text(dates).font(.title2.weight(.semibold))
                Spacer(minLength: 8)
                ControlGroup {
                    Button { model.goToPreviousDay() } label: {
                        Label("Previous period", systemImage: "chevron.left")
                    }
                    .disabled(!model.canGoBack)
                    Button { model.goToNextDay() } label: {
                        Label("Next period", systemImage: "chevron.right")
                    }
                    .disabled(!model.canGoForward)
                }
                .labelStyle(.iconOnly)
                .fixedSize()
                Button("Today") { model.goToToday() }
                    .buttonStyle(.bordered)
            }
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.range == .day ? "At desk" : "Daily average at desk")
                        .font(.subheadline).foregroundStyle(.secondary)
                    DurationText(value: figures.atDesk, size: 38)
                }
                .frame(width: 190, alignment: .leading)
                Divider().frame(height: 48)
                metric("Standing", value: figures.standing, colour: DeskpilotAppearance.standing)
                metric("Sitting", value: figures.sitting, colour: DeskpilotAppearance.sitting)
                metric("Breaks", value: figures.breaks, colour: PostureStyle.breakColor(scheme))
            }
            .padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Activity").font(.headline)
                    Spacer()
                    if NativeLayoutStudy.usesSectionTabs {
                        Picker("Range", selection: Binding(get: { model.range }, set: { model.range = $0 })) {
                            ForEach(HistoryRange.allCases) { range in Text(range.title).tag(range) }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    } else {
                        Text("Scroll to explore").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Group {
                    switch model.range {
                    case .day: DayScroller()
                    case .week, .month: PeriodScroller(range: model.range).id(model.range)
                    }
                }
                .padding(.trailing, 8)
            }
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Past year").font(.headline)
                    Spacer()
                    Text("Select a date").font(.caption).foregroundStyle(.secondary)
                }
                DeskHeatmap(days: model.heatmap,
                            selectedDays: model.highlightedHeatmapDays,
                            selectionFraction: model.heatmapPreviewFraction,
                            onSelect: model.select)
                .animation(.interactiveSpring(response: 0.24, dampingFraction: 0.9), value: model.heatmapSelectionPosition)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
    }
}

private struct NativeLayoutStudyView: View {
    @Environment(DashboardModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    let study: NativeLayoutStudy

    private var dateLabel: String {
        let end = model.selectedDayStart
        if model.range == .day { return end.formatted(.dateTime.month(.wide).day().year()) }
        return (model.day(-(model.range.days - 1), from: end)..<end)
            .formatted(.interval.month(.abbreviated).day().year())
    }
    @ViewBuilder private var chart: some View {
        switch model.range {
        case .day: DayScroller()
        case .week, .month: PeriodScroller(range: model.range).id(model.range)
        }
    }
    private func figure(_ name: String, _ duration: TimeInterval, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label { Text(name).foregroundStyle(.secondary) } icon: {
                Circle().fill(color).frame(width: 7, height: 7)
            }.font(.caption)
            Text(Formatting.duration(duration)).font(.title3.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private var ring: some View {
        let f = model.ringFigures
        return DeskDurationRing(atDesk: f.atDesk, standing: f.standing, sitting: f.sitting, breaks: f.breaks)
    }
    private var year: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Past year").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            DeskHeatmap(days: model.heatmap, selectedDays: model.highlightedHeatmapDays, selectionFraction: model.heatmapPreviewFraction, onSelect: model.select)
                .animation(.interactiveSpring(response: 0.24, dampingFraction: 0.9), value: model.heatmapSelectionPosition)
                .frame(maxWidth: .infinity)
        }
    }
    var body: some View {
        let f = model.ringFigures
        VStack(alignment: .leading, spacing: 20) {
            Text(dateLabel).font(.headline).frame(maxWidth: .infinity,
                                                       alignment: study == .focus ? .center : .leading)
                .padding(.top, 12)
            switch study {
            case .unified, .orbit, .editorial:
                EmptyView()
            case .focus:
                VStack(spacing: 5) {
                    ring
                    Text(model.range == .day ? "Time at desk" : "Daily average")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity)
                chart
                HStack(spacing: 24) {
                    figure("Standing", f.standing, DeskpilotAppearance.standing)
                    figure("Sitting", f.sitting, DeskpilotAppearance.sitting)
                    figure("Breaks", f.breaks, PostureStyle.breakColor(scheme))
                }.padding(.horizontal, 8)
            case .overview:
                HStack(spacing: 26) {
                    ring
                    VStack(alignment: .leading, spacing: 18) {
                        Text(model.range == .day ? "Time at desk" : "Daily average")
                            .font(.subheadline).foregroundStyle(.secondary)
                        HStack(spacing: 16) {
                            figure("Standing", f.standing, DeskpilotAppearance.standing)
                            figure("Sitting", f.sitting, DeskpilotAppearance.sitting)
                        }
                    }
                }.padding(.vertical, 4)
                GroupBox { chart.padding(.top, 6) }
            case .details:
                HStack(alignment: .top, spacing: 18) {
                    chart.frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 20) {
                        ring.frame(maxWidth: .infinity)
                        figure("Standing", f.standing, DeskpilotAppearance.standing)
                        figure("Sitting", f.sitting, DeskpilotAppearance.sitting)
                        figure("Breaks", f.breaks, PostureStyle.breakColor(scheme))
                    }
                    .padding(.leading, 16)
                    .frame(width: 146)
                    .overlay(alignment: .leading) { Divider() }
                }
            }
            Divider()
            year
        }
        .padding(.horizontal, 4)
    }
}

private struct ActivityHeader: View {
    @Environment(DashboardModel.self) private var model

    private var dates: String {
        let end = model.selectedDayStart
        guard model.range != .day else {
            return end.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
        }
        let start = model.day(-(model.range.days - 1), from: end)
        return (start..<end).formatted(.interval.month(.abbreviated).day().year())
    }

    private func navigate(_ action: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, action)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Desk Activity").font(.title2.weight(.bold))
                Text(dates).font(.subheadline).foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            HStack(spacing: 0) {
                if DashboardSnapshot.isRendering {
                    Image(systemName: "chevron.left").frame(width: 28, height: 24)
                } else {
                    Button { navigate { model.goToPreviousDay() } } label: {
                        Image(systemName: "chevron.left").frame(width: 28, height: 24)
                    }
                    .disabled(!model.canGoBack)
                    .help("Previous \(model.range.title.lowercased()) (⌘←)")
                    .accessibilityLabel("Previous period")
                }
                Divider().frame(height: 12)
                if DashboardSnapshot.isRendering {
                    Image(systemName: "chevron.right").frame(width: 28, height: 24)
                        .opacity(model.canGoForward ? 1 : 0.3)
                } else {
                    Button { navigate { model.goToNextDay() } } label: {
                        Image(systemName: "chevron.right").frame(width: 28, height: 24)
                    }
                    .disabled(!model.canGoForward)
                    .help("Next \(model.range.title.lowercased()) (⌘→)")
                    .accessibilityLabel("Next period")
                }
            }
            .buttonStyle(.borderless)
            .padding(2)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5) }
            Button("Today") { navigate { model.goToToday() } }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .help("Return to today (⌘T)")
        }
        .padding(.horizontal, 4)
        .padding(.top, 6)
    }
}

/// Summary figures update in the same step as the chart's settled selection.
struct RangeCard: View {
    @Environment(DashboardModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    private var chartTitle: String {
        switch model.range {
        case .day: return "Daily activity"
        case .week: return "Weekly activity"
        case .month: return "Monthly activity"
        }
    }

    private func metric(_ title: String, value: TimeInterval, colour: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(colour).frame(width: 8, height: 8)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Text(Formatting.duration(value))
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    var body: some View {
        let figures = model.ringFigures
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 24) {
                DeskDurationRing(atDesk: figures.atDesk, standing: figures.standing,
                                 sitting: figures.sitting, breaks: figures.breaks)
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.range == .day ? "Time at desk" : "Daily average at desk")
                            .font(.subheadline.weight(.semibold))
                        Text(model.range == .day ? "For the visible timeline" : "Across days with desk activity")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        metric("Standing", value: figures.standing, colour: PostureStyle.color(.standing))
                        metric("Sitting", value: figures.sitting, colour: PostureStyle.color(.sitting))
                        metric("Breaks", value: figures.breaks, colour: PostureStyle.breakColor(colorScheme))
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            InsightCard(trailingPadding: 12) {
                HStack {
                    Text(chartTitle).font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "arrow.left.and.right")
                        .font(.caption2)
                    Text("Scroll to explore").font(.caption)
                }
                .foregroundStyle(.secondary)
                .padding(.bottom, 10)
                switch model.range {
                case .day: DayScroller()
                case .week, .month: PeriodScroller(range: model.range).id(model.range)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Rubber-banding past either end, the way a scroll view resists at its edges: `value`
/// beyond `limits` is drawn closer and closer to them, never more than `dimension` past.
private func rubberBand(_ value: Double, in limits: ClosedRange<Double>, dimension: Double) -> Double {
    guard dimension > 0 else { return min(max(value, limits.lowerBound), limits.upperBound) }
    func resist(_ pull: Double) -> Double { (1 - 1 / (pull * 0.55 / dimension + 1)) * dimension }
    if value < limits.lowerBound { return limits.lowerBound - resist(limits.lowerBound - value) }
    if value > limits.upperBound { return limits.upperBound + resist(value - limits.upperBound) }
    return value
}

/// The week or month chart, scrolled a day at a time or anywhere between: the fingers move
/// the columns point for point, and on lift-off they glide on - as far as the flick would
/// have carried them, to the next whole day in the direction of travel - and ease to a stop
/// there in one motion, the way a snapping scroll view does. The clock stays put the whole
/// time: one span for all of the history, so nothing moves up or down under a sideways
/// scroll. The window that comes to rest becomes the selected period.
/// The day, week and month charts, each kept once it has been shown and only hidden when
/// another range is picked: building a chart afresh on every switch cost a few frames, enough
/// to hitch the tabs' own animation. A hidden chart takes no scrolls, hovers or clicks.
private struct RangeCharts: View {
    @Environment(DashboardModel.self) private var model
    @State private var shown: Set<HistoryRange> = []
    /// Each chart's own height, measured as it is laid out, so the stack is as tall as the
    /// chart that is showing and not the tallest it has ever held: the day chart is shorter
    /// than the week and month ones, and a hidden month chart under it was opening a gap
    /// between the day's axis and the balance bar once Month had been visited.
    @State private var heights: [HistoryRange: CGFloat] = [:]

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(HistoryRange.allCases, id: \.self) { range in
                if (shown.contains(range) && !DevPerfDriver.omits("retain")) || range == model.range {
                    let active = range == model.range
                    Group {
                        if range == .day {
                            DayScroller(isActive: active)
                        } else {
                            PeriodScroller(range: range, isActive: active)
                        }
                    }
                    .opacity(active ? 1 : 0)
                    .allowsHitTesting(active)
                    .accessibilityHidden(!active)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights[range] = $0 }
                }
            }
        }
        .frame(height: heights[model.range], alignment: .top)
        .clipped()
        .onChange(of: model.range, initial: true) { _, range in shown.insert(range) }
    }
}

private struct PeriodScroller: View {
    @Environment(DashboardModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let range: HistoryRange
    /// Whether this is the range on show: a hidden chart doesn't watch the trackpad, and stays
    /// on the period it last showed (`hiddenAt`) rather than following steps made elsewhere.
    var isActive = true
    @State private var hiddenAt: Date?
    /// The period's last day: the selection, or while hidden, where it was when hidden - read
    /// that way, a hidden chart doesn't depend on the selection and isn't redrawn by steps.
    private var selected: Date { (isActive ? nil : hiddenAt) ?? model.selectedDayStart }
    /// How far the window has been scrolled from the selected period, in days; positive is
    /// back in time. Folded into the selection once it comes to rest.
    @State private var scroll: Double = DashboardSnapshot.devScroll
    @State private var plotWidth: CGFloat = 0
    @State private var isScrolling = false
    /// Bumped by every new scroll, so a settle the fingers interrupted doesn't fold in.
    @State private var generation = 0
    /// The fingers' speed, in days a second (positive is back in time), and the trackpad's
    /// timestamp of their last move - what the glide on lift-off starts from.
    @State private var velocity: Double = 0
    @State private var lastFingerScroll: TimeInterval?
    /// Set once the glide to a day has begun: the system's own momentum, which would coast
    /// on and then need a second snap to line up, is ignored from then on.
    @State private var gliding = false

    /// The landing spring's stiffness; its natural speed (sqrt of it, per second) caps the
    /// speed it starts at, past which a critically damped spring overshoots and comes back.
    private static let stiffness: Double = 170

    private var count: Int { range.days }

    /// From today's window (negative: forward) to the one starting on the history's first day.
    private var limits: ClosedRange<Double> {
        let forward = -Double(max(0, model.days(from: selected, to: model.todayStart)))
        let back = model.firstDayStart.map {
            Double(max(0, model.days(from: $0, to: selected) - (count - 1)))
        } ?? 0
        return forward ... max(forward, back)
    }

    /// The clock for every week and month: the span of all the history (and now), so it's
    /// the same wherever the chart is scrolled to.
    private var clock: ClosedRange<Double> {
        let first = model.firstDayStart ?? model.todayStart
        let days = model.columns(endingAt: model.todayStart, count: model.days(from: first, to: model.todayStart) + 1)
        return PeriodColumnsChart.hourDomain(for: days, nowMarker: model.now)
    }

    var body: some View {
        ScrollingColumns(offset: scroll,
                         minimumOffset: limits.lowerBound,
                         hours: clock,
                         range: range,
                         selected: selected,
                         isScrolling: isScrolling,
                         plotWidth: plotWidth,
                         onPlotWidth: { plotWidth = $0 })
            .background {
                if !DashboardSnapshot.isRendering && isActive {
                    ChartScrollMonitor(onBegin: {
                                           generation += 1
                                           isScrolling = true
                                           gliding = false
                                           velocity = 0
                                           lastFingerScroll = nil
                                           scrollLog.notice("begin scroll=\(scroll, privacy: .public)")
                                       },
                                       onScroll: { delta, isMomentum, timestamp in
                                           guard plotWidth > 0 else { return }
                                           // Momentum means the fingers have lifted: glide from here.
                                           if isMomentum {
                                               if !gliding { settle() }
                                               return
                                           }
                                           let step = Double(delta / plotWidth) * Double(count)
                                           if let lastFingerScroll {
                                               let elapsed = max(timestamp - lastFingerScroll, 1.0 / 240)
                                               velocity = 0.5 * velocity + 0.5 * step / elapsed
                                           }
                                           lastFingerScroll = timestamp
                                           // A hard stop at either end: stretching past it only to
                                           // spring back read as a snap.
                                           scroll = min(max(scroll + step, limits.lowerBound), limits.upperBound)
                                           model.previewSummary(periodOffset: scroll)
                                           scrollLog.debug("move delta=\(delta, privacy: .public) t=\(timestamp, privacy: .public) scroll=\(scroll, privacy: .public) v=\(velocity, privacy: .public)")
                                       },
                                       // Momentum arriving after the glide began is part of the same
                                       // flick: the glide already has it in hand.
                                       onLateMomentum: { scrollLog.notice("late momentum ignored") },
                                       // The glide starts the moment the fingers lift: waiting to see
                                       // whether momentum follows left the columns standing still first.
                                       onLift: { if !gliding { settle() } },
                                       onEnd: { if !gliding { settle() } })
                }
            }
            .onChange(of: model.navigationRevision) { _, _ in cancelScroll() }
            .onChange(of: isActive, initial: true) { _, active in hiddenAt = active ? nil : model.selectedDayStart }
            .onDisappear { cancelScroll() }
    }

    /// Only what a scroll left behind is reset: a chart at rest (and every hidden one) has
    /// nothing to redraw when the range or period changes under it.
    private func cancelScroll() {
        generation += 1
        if isScrolling { isScrolling = false }
        if gliding { gliding = false }
        velocity = 0
        lastFingerScroll = nil
        guard isActive || scroll != 0 else { return }
        model.clearHeatmapPreview()
        guard scroll != 0 else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { scroll = 0 }
    }

    /// Glides the window on from the fingers' speed to the whole day the flick was heading
    /// for (inside the limits), easing to a stop there; then makes it the selected period in
    /// one untimed step - the columns are already where that period draws them, so the swap
    /// is invisible, and the ring turns to it.
    private func settle() {
        gliding = true
        // Fingers that stopped before lifting carry no speed into the glide.
        let sinceMove = lastFingerScroll.map { ProcessInfo.processInfo.systemUptime - $0 } ?? .infinity
        let speed = sinceMove < 0.05 ? velocity : 0
        // About as far as a scroll view would coast on that speed before stopping; a real
        // flick lands on the next whole day ahead, never one behind where it was heading.
        let projected = scroll + speed * 0.3
        var target = projected.rounded()
        if speed > 1 { target = max(target, scroll.rounded(.up)) }
        if speed < -1 { target = min(target, scroll.rounded(.down)) }
        target = min(max(target, limits.lowerBound), limits.upperBound)
        let started = generation
        let anchor = model.selectedDayStart
        let revision = model.navigationRevision
        model.previewSummary(periodOffset: target, settling: true)
        // Still scrolling until the glide has come to rest: no hover card while it moves.
        let fold = {
            guard started == generation, model.navigationRevision == revision, model.range == range, model.selectedDayStart == anchor else { return }
            isScrolling = false
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                let days = Int(target)
                if days != 0 { model.select(model.day(-days, from: anchor)) }
                model.clearHeatmapPreview()
                scroll = 0
            }
            scrollLog.notice("fold days=\(Int(target), privacy: .public)")
        }
        // Critically damped, starting at the fingers' speed but never faster than the spring's
        // own, so it eases in without overshooting and coming back.
        let distance = target - scroll
        let limit = Self.stiffness.squareRoot()
        let initialVelocity = abs(distance) > 0.001 ? min(max(speed / distance, 0), limit) : 0
        scrollLog.notice("settle speed=\(speed, privacy: .public) sinceMove=\(sinceMove, privacy: .public) scroll=\(scroll, privacy: .public) target=\(target, privacy: .public) v0=\(initialVelocity, privacy: .public)")
        guard !reduceMotion, abs(distance) > 0.001 else { fold(); return }
        withAnimation(.interpolatingSpring(mass: 1, stiffness: Self.stiffness, damping: 2 * limit,
                                           initialVelocity: initialVelocity),
                      completionCriteria: .removed) {
            // Folded once the spring has actually come to rest: on "logically complete" it was
            // still a few points short, and the fold jumped them.
            scroll = target
        } completion: {
            fold()
        }
    }
}

/// The week or month chart at a scroll offset, animatable so a settle glides rather than
/// jumps.
private struct ScrollingColumns: View, Animatable {
    @Environment(DashboardModel.self) private var model
    var offset: Double
    let minimumOffset: Double
    var hours: ClosedRange<Double>
    let range: HistoryRange
    /// The period's last day (see `PeriodScroller.selected`).
    let selected: Date
    let isScrolling: Bool
    let plotWidth: CGFloat
    let onPlotWidth: (CGFloat) -> Void

    var animatableData: Double {
        get { offset }
        set { offset = newValue }
    }

    /// Days between a month's date labels: the fewest that leave room for a label like
    /// "Oct 28", so the axis carries as many dates as fit, evenly spaced.
    private static func labelEvery(dayWidth: CGFloat) -> Int {
        guard dayWidth > 0 else { return 5 }
        return [2, 3, 4, 5, 7, 10].first { CGFloat($0) * dayWidth >= 46 } ?? 14
    }

    var body: some View {
        let calendar = Calendar.current
        let isWeek = range == .week
        let count = range.days
        // The window's first day, in days from the selected period's last; and the days to
        // draw - the window and one either side, for the columns sliding in.
        // Clamp the animated presentation too: a spring must never draw future days.
        let windowStart = -Double(count - 1) - max(offset, minimumOffset)
        let first = Int(windowStart.rounded(.down)) - 1
        let last = Int((windowStart + Double(count)).rounded(.up)) + 1
        let end = model.day(last, from: selected)
        let days = model.columns(endingAt: end, count: last - first + 1)
        let firstDay = days.first.map { model.days(from: selected, to: $0.dayStart) } ?? first
        let today = model.todayStart
        let every = Self.labelEvery(dayWidth: plotWidth / CGFloat(count))
        PeriodColumnsChart(
            days: days,
            visibleStart: windowStart - Double(firstDay),
            visibleCount: count,
            hourDomain: hours,
            label: { day in
                if isWeek { return day.dayStart.formatted(.dateTime.weekday(.abbreviated)) }
                // Every few days counted back from today, so the dates are evenly spaced,
                // today is always one of them, and each rides with its column as the chart
                // scrolls. Each with its month, so none reads as a bare number.
                let beforeToday = model.days(from: day.dayStart, to: today)
                guard beforeToday >= 0, beforeToday % every == 0 else { return nil }
                return day.dayStart.formatted(.dateTime.month(.abbreviated).day())
            },
            divider: { day in
                let weekStart = calendar.component(.weekday, from: day.dayStart) == calendar.firstWeekday
                if isWeek { return weekStart ? .solid : .dashed }
                if calendar.component(.day, from: day.dayStart) == 1 { return .solid }
                // A dashed line at each dated day, so every label has its line.
                let beforeToday = model.days(from: day.dayStart, to: today)
                return beforeToday >= 0 && beforeToday % every == 0 ? .dashed : nil
            },
            closesLastColumn: isWeek,
            barRatio: 0.65,
            dayStartHour: model.middleOfNightHour,
            nowMarker: model.now,
            isScrolling: isScrolling,
            labelKey: "\(range.rawValue) \(every) \(today.timeIntervalSince1970)",
            onPlotWidth: onPlotWidth,
            onSelect: { day in
                model.select(day)
                model.range = .day
            })
            .equatable()
    }
}

/// The day chart, scrolled freely through time: a window the selected day's span wide that
/// the fingers move point for point and momentum carries on, coming to rest wherever it
/// stops. The latest view is a hard stop; only the oldest edge rubber-bands back.
private struct DayScroller: View {
    @Environment(DashboardModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Whether this is the range on show: a hidden chart doesn't watch the trackpad, and stays
    /// where it last rested (`hiddenAt`) rather than following steps made elsewhere.
    var isActive = true
    @State private var hiddenAt: ClosedRange<Date>?
    /// Where the chart rests: the model's, or while hidden, where it was when hidden.
    private var resting: ClosedRange<Date> { (isActive ? nil : hiddenAt) ?? model.restingDayWindow }
    /// How far the window has moved back in time from where it last came to rest, in seconds.
    @State private var offset: TimeInterval = DashboardSnapshot.devScroll * 3600
    @State private var plotWidth: CGFloat = 0
    @State private var isScrolling = false
    @State private var generation = 0

    private func limits(for base: ClosedRange<Date>) -> ClosedRange<Double> {
        let latest = model.track(for: model.todayStart).domain.upperBound
        let forward = min(0, base.upperBound.timeIntervalSince(latest))
        let back = model.firstDayStart.map { max(0, base.lowerBound.timeIntervalSince($0)) } ?? 0
        return forward ... max(forward, back)
    }

    var body: some View {
        let base = resting
        let span = base.upperBound.timeIntervalSince(base.lowerBound)
        ScrollingDay(offset: rubberBand(max(offset, limits(for: base).lowerBound), in: limits(for: base), dimension: span),
                     minimumOffset: limits(for: base).lowerBound,
                     base: base,
                     isScrolling: isScrolling,
                     onPlotWidth: { plotWidth = $0 })
            .background {
                if !DashboardSnapshot.isRendering && isActive {
                    ChartScrollMonitor(onBegin: {
                                           generation += 1
                                           isScrolling = true
                                       },
                                       onScroll: { delta, isMomentum, _ in
                                           guard plotWidth > 0, !isMomentum || limits(for: base).contains(offset) else { return }
                                           offset = max(offset + Double(delta / plotWidth) * span, limits(for: base).lowerBound)
                                           let shift = rubberBand(offset, in: limits(for: base), dimension: span)
                                           model.previewSummary(dayWindow: base.lowerBound.addingTimeInterval(-shift)...base.upperBound.addingTimeInterval(-shift))
                                       },
                                       onEnd: settle)
                }
            }
            .onChange(of: model.navigationRevision) { _, _ in cancelScroll() }
            .onChange(of: isActive, initial: true) { _, active in hiddenAt = active ? nil : model.restingDayWindow }
            .onDisappear { cancelScroll() }
    }

    /// Only what a scroll left behind is reset (see `PeriodScroller.cancelScroll`).
    private func cancelScroll() {
        generation += 1
        if isScrolling { isScrolling = false }
        guard isActive || offset != 0 else { return }
        model.clearHeatmapPreview()
        guard offset != 0 else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { offset = 0 }
    }

    /// Springs back inside the limits if the scroll overshot them, then hands the model the
    /// window at rest - in one untimed step, so nothing on screen moves but the ring.
    private func settle() {
        isScrolling = false
        let base = model.restingDayWindow
        let target = min(max(offset, limits(for: base).lowerBound), limits(for: base).upperBound)
        model.previewSummary(dayWindow: base.lowerBound.addingTimeInterval(-target)...base.upperBound.addingTimeInterval(-target), settling: true)
        let started = generation
        let anchor = model.selectedDayStart
        let revision = model.navigationRevision
        let fold = {
            guard started == generation, model.navigationRevision == revision, model.range == .day, model.selectedDayStart == anchor else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                let shift = -target
                model.rest(dayWindowAt: base.lowerBound.addingTimeInterval(shift) ... base.upperBound.addingTimeInterval(shift))
                offset = 0
            }
        }
        guard target != offset, !reduceMotion else { fold(); return }
        withAnimation(.spring(duration: 0.3, bounce: 0), completionCriteria: .logicallyComplete) {
            offset = target
        } completion: {
            fold()
        }
    }
}

/// The day chart at a scroll offset, animatable so springing back from an edge glides.
private struct ScrollingDay: View, Animatable {
    @Environment(DashboardModel.self) private var model
    var offset: TimeInterval
    let minimumOffset: TimeInterval
    let base: ClosedRange<Date>
    let isScrolling: Bool
    let onPlotWidth: (CGFloat) -> Void

    var animatableData: Double {
        get { offset }
        set { offset = newValue }
    }

    var body: some View {
        let displayedOffset = max(offset, minimumOffset)
        let window = base.lowerBound.addingTimeInterval(-displayedOffset) ... base.upperBound.addingTimeInterval(-displayedOffset)
        DayTimelineChart(tracks: model.tracks(overlapping: window),
                         domain: window,
                         nowMarker: model.now,
                         isScrolling: isScrolling,
                         onPlotWidth: onPlotWidth,
                         neighbours: model.tracks(overlapping: window.lowerBound.addingTimeInterval(-3 * 86_400)
                                                    ... window.upperBound.addingTimeInterval(3 * 86_400)))
            .equatable()
    }
}
