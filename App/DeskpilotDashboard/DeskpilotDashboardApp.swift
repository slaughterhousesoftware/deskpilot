import AppKit
import SwiftUI
import DeskpilotKit

@main
struct DeskpilotDashboardApp: App {
    @State private var model = DashboardModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Deskpilot Dashboard", id: "dashboard") {
            DashboardWindow()
                .preferredColorScheme(DashboardSnapshot.previewColorScheme ?? DeskpilotDisplayPreferences.shared.mode.colorScheme)
                .environment(model)
                .task { await DashboardSnapshot.runIfRequested(model: model) }
        }
        // Keep the chart at its designed width.
        .windowResizability(.contentSize)
        // Native macOS toolbar controls over the translucent window surface.
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 640, height: 640)
        .commands {
            // The Dashboard is a single window onto the desk; there is nothing to make.
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    model.showsSettings = true
                    openWindow(id: "dashboard")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("Activity") { model.showsSettings = false }
                    .keyboardShortcut("1", modifiers: .command)
                Divider()
                Menu("Appearance") {
                    Picker("Appearance", selection: Binding(
                        get: { DeskpilotDisplayPreferences.shared.mode },
                        set: { DeskpilotDisplayPreferences.shared.select($0) })) {
                        ForEach(DeskpilotDisplayMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                }
            }
            CommandGroup(replacing: .appInfo) {
                Button("About Deskpilot Dashboard") { AboutPanel.show() }
            }
            CommandGroup(replacing: .help) {
                ForEach(HelpLink.all, id: \.title) { link in
                    if link.title == "Contact Ergodriven" { Divider() }
                    Button(link.title) { NSWorkspace.shared.open(link.url) }
                }
            }
            CommandMenu("History") {
                Button("Previous period") { model.goToPreviousDay() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                    .disabled(model.showsSettings || !model.canGoBack)
                Button("Next period") { model.goToNextDay() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                    .disabled(model.showsSettings || !model.canGoForward)
                Button("Today") { model.goToToday() }
                    .keyboardShortcut("t", modifiers: .command)
                    .disabled(model.showsSettings)
            }
        }
    }
}

/// One native tab control switches between the time ranges and Settings.
struct DashboardWindow: View {
    @Environment(DashboardModel.self) private var model

    var body: some View {
        Group {
            if NativeLayoutStudy.usesSectionTabs {
                TabView(selection: Binding(get: { model.showsSettings }, set: { model.showsSettings = $0 })) {
                    HistoryView()
                        .tabItem { Text("Activity") }
                        .tag(false)
                    SettingsTab()
                        .tabItem { Text("Settings") }
                        .tag(true)
                }
                .tabViewStyle(.automatic)
            } else {
                Group {
                    if model.showsSettings {
                        SettingsTab()
                    } else {
                        HistoryView()
                    }
                }
            }
        }
        .padding(.top, 6)
        .frame(width: 640)
        .toolbar {
            if !NativeLayoutStudy.usesSectionTabs {
                ToolbarItem(placement: .principal) {
                    DashboardDestinationControl(selection: model.showsSettings ? 3 : HistoryRange.allCases.firstIndex(of: model.range) ?? 0) { index in
                        if HistoryRange.allCases.indices.contains(index) {
                            let range = HistoryRange.allCases[index]
                            if model.range != range { model.range = range }
                            model.showsSettings = false
                        } else {
                            model.showsSettings = true
                        }
                    }
                    .fixedSize()
                }
            }
        }
        .tint(DeskpilotAppearance.sitting)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .background {
            DashboardBackground()
                .ignoresSafeArea()
        }
        .background(DashboardWindowAppearance())
        .onAppear { model.windowAppeared() }
        .onDisappear { model.windowDisappeared() }
    }
}

/// Ergodriven's own help for the Tempo controller, in the Help menu.
private struct HelpLink {
    let title: String
    let url: URL

    static let all = [
        HelpLink(title: "Tempo User Manual", url: URL(string: "https://cdn.shopify.com/s/files/1/1117/2112/files/TempoUserManual.pdf")!),
        HelpLink(title: "Tempo Quick Start Guide", url: URL(string: "https://cdn.shopify.com/s/files/1/1117/2112/files/TempoQuickStartGuide.pdf")!),
        HelpLink(title: "Tempo Support", url: URL(string: "https://ergodriven.com/pages/tempo-controller-support")!),
        HelpLink(title: "Contact Ergodriven", url: URL(string: "mailto:info@ergodriven.com")!),
        HelpLink(title: "Ergodriven Website", url: URL(string: "https://ergodriven.com")!),
    ]
}

/// The standard About window, with the acknowledgements in its credits.
private enum AboutPanel {
    private static let libraries = [
        ("btleplug", "MIT, Apache-2.0 or BSD-3-Clause"), ("Tokio", "MIT"), ("Serde", "MIT or Apache-2.0"),
        ("Jiff", "MIT or Unlicense"), ("clap", "MIT or Apache-2.0"), ("tracing", "MIT"),
        ("uuid", "MIT or Apache-2.0"), ("futures", "MIT or Apache-2.0"), ("thiserror", "MIT or Apache-2.0"),
        ("async-trait", "MIT or Apache-2.0"), ("fs2", "MIT or Apache-2.0"),
    ]

    static func show() {
        let text = "Works with the Ergodriven Tempo controller. Ergodriven and Tempo are trademarks of Ergodriven.\n\n"
            + "The desk connection uses these open-source libraries:\n"
            + libraries.map { "\($0.0)  \($0.1)" }.joined(separator: "\n")
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let credits = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// All four destinations belong to one AppKit control, including its selection lens.
private struct DashboardDestinationControl: NSViewRepresentable {
    let selection: Int
    let onSelect: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: HistoryRange.allCases.map(\.title) + [""],
                                         trackingMode: .selectOne, target: context.coordinator,
                                         action: #selector(Coordinator.selectDestination(_:)))
        control.segmentStyle = .automatic
        if #available(macOS 26.0, *) {
            control.controlSize = .extraLarge
            control.borderShape = .capsule
        } else {
            control.controlSize = .large
        }
        if #available(macOS 27.0, *) { control.role = .tabs }
        control.font = .systemFont(ofSize: 13)
        control.segmentDistribution = .fit
        for index in HistoryRange.allCases.indices {
            control.setWidth(72, forSegment: index)
            control.setToolTip(HistoryRange.allCases[index].title, forSegment: index)
        }
        control.setImage(NSImage(systemSymbolName: "gear", accessibilityDescription: "Settings")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular, scale: .medium)), forSegment: 3)
        control.setImageScaling(.scaleProportionallyDown, forSegment: 3)
        // Keep the image-only Settings segment fitted to its symbol with native padding.
        control.setWidth(0, forSegment: 3)
        control.setAlignment(.center, forSegment: 3)
        control.setToolTip("Settings (⌘,)", forSegment: 3)
        control.setAccessibilityLabel("View")
        control.sizeToFit()
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.onSelect = onSelect
        if control.selectedSegment != selection { control.selectedSegment = selection }
    }

    final class Coordinator: NSObject {
        var onSelect: (Int) -> Void
        init(onSelect: @escaping (Int) -> Void) { self.onSelect = onSelect }

        @objc func selectDestination(_ sender: NSSegmentedControl) {
            guard (0..<4).contains(sender.selectedSegment) else { return }
            onSelect(sender.selectedSegment)
        }
    }
}

/// A solid charcoal surface keeps the chart contrast independent of the desktop.
private struct DashboardBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        DashboardSurface.background(scheme)
    }
}

private struct DashboardWindowAppearance: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowProbe() }
    func updateNSView(_ view: NSView, context: Context) {}

    private class WindowProbe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.hasShadow = true
            window.titlebarSeparatorStyle = .none
        }
    }
}

/// Developer mode, like the menu bar app's `DevSnapshot`: with `DESKPILOT_DEV_SNAPSHOT=<prefix>`
/// in the environment, the History view is rendered offscreen at 2x to `<prefix>-history.png`
/// once the model has loaded, and the app quits - so the dashboard can be checked without a
/// window on anyone's screen.
enum DashboardSnapshot {
    static let previewColorScheme: ColorScheme? = {
        switch ProcessInfo.processInfo.environment["DESKPILOT_DEV_APPEARANCE"] {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }()

    /// `DESKPILOT_DEV_SCROLL=2.4` draws the range card's chart scrolled back 2.4 days (Week,
    /// Month) or hours (Day), to check what slides under the frame is clipped and labelled.
    static let devScroll = ProcessInfo.processInfo.environment["DESKPILOT_DEV_SCROLL"]
        .flatMap(Double.init) ?? 0
    /// ImageRenderer can't draw AppKit views, so the charts leave out their scroll monitor.
    static let isRendering = ProcessInfo.processInfo.environment["DESKPILOT_DEV_SNAPSHOT"] != nil
    static let capturesNativeWindow = ProcessInfo.processInfo.environment["DESKPILOT_DEV_NATIVE_SNAPSHOT"] != nil
    /// `DESKPILOT_DEV_HOVER=0.4,0.3` puts a pretend pointer 40% across and 30% down each chart's
    /// plot (and 40% through the heatmap's days), since a native capture ignores the real one.
    static let devHover: CGPoint? = {
        guard capturesNativeWindow,
              let parts = ProcessInfo.processInfo.environment["DESKPILOT_DEV_HOVER"]?.split(separator: ",")
                  .compactMap({ Double($0) }), parts.count == 2 else { return nil }
        return CGPoint(x: parts[0], y: parts[1])
    }()
    /// Checks the actual UI model's navigation/preview transitions without issuing desk commands.
    @MainActor
    private static func verifyHeatmapSelection(_ model: DashboardModel) {
        let originalDay = model.selectedDayStart
        let originalRange = model.range
        let gridDays = model.heatmap.map(\.day)
        let today = model.todayStart
        model.select(today)
        for range in [HistoryRange.day, .week, .month] {
            model.range = range
            precondition(model.days(from: model.highlightedHeatmapDays.lowerBound,
                                    to: model.highlightedHeatmapDays.upperBound) == range.days - 1)
            precondition(model.highlightedHeatmapDays.upperBound == today)
        }
        model.previewHeatmap(endingAt: model.day(-8, from: today))
        precondition(model.highlightedHeatmapDays.upperBound == model.day(-8, from: today))
        precondition(model.selectedDayStart == today)
        model.range = .week
        precondition(model.heatmapPreviewEnd == nil)
        model.previewHeatmap(endingAt: model.day(-20, from: today))
        model.select(model.day(-3, from: today))
        precondition(model.heatmapPreviewEnd == nil)
        precondition(model.highlightedHeatmapDays.upperBound == model.day(-3, from: today))
        model.goToPreviousDay()
        precondition(model.highlightedHeatmapDays.upperBound == model.day(-10, from: today))
        model.range = .day
        model.previewHeatmap(endingAt: model.day(100, from: today))
        precondition(model.highlightedHeatmapDays.upperBound == today)
        model.goToToday()
        let beforeReselect = model.navigationRevision
        model.select(today)
        precondition(model.navigationRevision > beforeReselect)
        precondition(model.heatmapPreviewEnd == nil)
        precondition(model.heatmap.map(\.day) == gridDays)
        precondition(model.heatmap.last?.day == today)
        model.range = originalRange
        model.select(originalDay)
    }

    @MainActor
    private static func verifyScrollSummary(_ model: DashboardModel) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto")!
        for (month, day, hours) in [(10, 22, 24), (3, 7, 23), (10, 31, 25)] {
            let start = calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 4))!
            let end = calendar.date(byAdding: .day, value: 1, to: start)!
            for isToday in [false, true] {
                let domain = DashboardCharts.timelineDomain(bounds: nil, dayStart: start, dayFullEnd: end,
                                                            now: end.addingTimeInterval(-1800), isToday: isToday,
                                                            calendar: calendar)
                precondition(domain == start...end, "The full desk day must remain visible, even late at night")
                precondition(domain.upperBound.timeIntervalSince(domain.lowerBound) == Double(hours) * 3600)
            }
        }
        let originalDay = model.selectedDayStart
        let originalRange = model.range
        defer { model.range = originalRange; model.select(originalDay) }
        let anchor = model.heatmap.last(where: { $0.atDesk > 0 })?.day ?? model.todayStart
        model.range = .day
        model.select(anchor)
        let settled = model.ringFigures
        let base = model.restingDayWindow
        for shift in [0.0, 900, 3600, 86400] {
            let window = base.lowerBound.addingTimeInterval(-shift)...base.upperBound.addingTimeInterval(-shift)
            model.previewSummary(dayWindow: window)
            precondition(model.selectedDayStart == anchor && model.restingDayWindow == base)
            let preview = model.ringFigures
            precondition(preview.atDesk.isFinite && preview.atDesk >= 0)
            precondition(abs(preview.atDesk - preview.standing - preview.sitting) < 0.001)
            model.rest(dayWindowAt: window)
            precondition(model.ringFigures == preview, "Settling must preserve the live summary")
            model.select(anchor)
        }
        model.clearHeatmapPreview()
        precondition(model.ringFigures == settled)
        // A window entirely inside one segment exercises both 0% and 100% endpoints.
        let samples = model.heatmap.suffix(30).flatMap { model.track(for: $0.day).drawn }
        for state in [PostureState.standing, .sitting, .away] {
            guard let segment = samples.first(where: { $0.state == state && $0.end.timeIntervalSince($0.start) > 2 }) else { continue }
            let end = min(segment.end, segment.start.addingTimeInterval(60))
            model.previewSummary(dayWindow: segment.start...end)
            let result = model.ringFigures
            let duration = end.timeIntervalSince(segment.start)
            switch segment.state {
            case .standing: precondition(abs(result.standing - duration) < 0.001 && result.sitting == 0)
            case .sitting: precondition(abs(result.sitting - duration) < 0.001 && result.standing == 0)
            case .away: precondition(result.atDesk == 0)
            }
        }
        for range in [HistoryRange.week, .month] {
            model.range = range
            model.select(anchor)
            let used = model.columns(endingAt: anchor, count: range.days).filter(\.used)
            let average = used.isEmpty ? 0 : used.reduce(0) { $0 + $1.atDesk } / Double(used.count)
            precondition(abs(model.ringFigures.atDesk - average) < 0.001)
            for offset in [0.0, 0.001, 0.25, 0.5, 0.999999, 1] {
                model.previewSummary(periodOffset: offset)
                let result = model.ringFigures
                precondition(result.atDesk.isFinite && result.atDesk >= 0)
                precondition(abs(result.atDesk - result.standing - result.sitting) < 0.001)
                precondition(model.selectedDayStart == anchor)
            }
            let preview = model.ringFigures
            model.select(model.day(-1, from: anchor))
            precondition(model.summaryPeriodOffset == nil && model.ringFigures == preview)
        }
        model.previewSummary(periodOffset: 0.5)
        model.range = .day
        precondition(model.summaryPeriodOffset == nil && model.summaryDayWindow == nil)
        model.previewSummary(dayWindow: base)
        model.goToToday()
        precondition(model.summaryDayWindow == nil)
    }

    @MainActor
    static func runIfRequested(model: DashboardModel) async {
        if DevPerfDriver.outputPath != nil {
            await DevPerfDriver.run(model: model)
            return
        }
        let nativePrefix = ProcessInfo.processInfo.environment["DESKPILOT_DEV_NATIVE_SNAPSHOT"]
        guard let prefix = nativePrefix ?? ProcessInfo.processInfo.environment["DESKPILOT_DEV_SNAPSHOT"] else { return }
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        if ProcessInfo.processInfo.environment["DESKPILOT_DEV_PROFILE_SELECTION"] == "1" {
            let originalDay = model.selectedDayStart
            let originalRange = model.range
            var timings: [String: Double] = [:]
            for range in HistoryRange.allCases {
                model.range = range
                var samples: [Double] = []
                for offset in 0..<60 {
                    let start = ContinuousClock.now
                    model.select(model.day(-offset, from: model.todayStart))
                    _ = model.ringFigures
                    _ = model.highlightedHeatmapDays
                    _ = model.columns(endingAt: model.selectedDayStart, count: range.days + 4)
                    let elapsed = start.duration(to: .now).components
                    samples.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
                }
                timings[range.rawValue + "SelectionP95Milliseconds"] = samples.sorted()[56]
            }
            model.range = originalRange
            model.select(originalDay)
            if let data = try? JSONSerialization.data(withJSONObject: timings, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: prefix + "-selection-profile.json"), options: .atomic)
            }
        }
        if ProcessInfo.processInfo.environment["DESKPILOT_DEV_VERIFY_HEATMAP"] == "1" {
            verifyHeatmapSelection(model)
            verifyScrollSummary(model)
            let report = ["success": true, "rangeLengths": true, "scrollPreview": true,
                          "rangeSwitchClearsPreview": true, "clickClearsPreview": true,
                          "futureLimit": true, "fixedGrid": true, "sameDayCancelsOldScroll": true,
                          "liveSummary": true, "fractionalPeriodAverage": true,
                          "settlingPreservesSummary": true, "zeroAndFullShare": true,
                          "fullDeskDay": true, "daylightSavingDayLengths": true]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: prefix + "-verification.json"), options: .atomic)
            }
        }
        if ProcessInfo.processInfo.environment["DESKPILOT_DEV_RING_COMPARE"] == "1" {
            for variant in ["score", "duration", "hover", "break"] {
              let ring = DeskDurationRing(atDesk: 6 * 3600, standing: 3 * 3600,
                                          sitting: 5 * 3600, breaks: 2 * 3600,
                                          comparisonScore: variant == "score" ? 98 : nil,
                                          initialHover: variant == "hover" ? 2 : variant == "break" ? 1 : nil)
              for light in [true, false] {
                let renderer = ImageRenderer(content: ring
                    .padding(16)
                    .background(light ? Color(red: 0.97, green: 0.97, blue: 1) : Color(white: 0.20))
                    .environment(\.colorScheme, light ? .light : .dark))
                renderer.scale = 3
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: prefix + "-ring-" + variant + (light ? "-light.png" : "-dark.png")))
                }
            }
            }
            NSApplication.shared.terminate(nil)
            return
        }
        // `DESKPILOT_DEV_DAYS_AGO=1` renders yesterday, and so on; `DESKPILOT_DEV_RANGE=week` or
        // `month` renders that range instead of the day.
        if let daysAgo = ProcessInfo.processInfo.environment["DESKPILOT_DEV_DAYS_AGO"].flatMap(Int.init), daysAgo > 0 {
            for _ in 0..<daysAgo { model.goToPreviousDay() }
        }
        let light = ProcessInfo.processInfo.environment["DESKPILOT_DEV_LIGHT"] == "1"
        // A comma-separated list ("month,day") visits each range in turn, a moment apart, so
        // a capture can show the layout after switching tabs, which a fresh start can't.
        let ranges = (ProcessInfo.processInfo.environment["DESKPILOT_DEV_RANGE"] ?? "")
            .split(separator: ",").compactMap { name -> HistoryRange? in
                switch name { case "day": .day; case "week": .week; case "month": .month; default: nil }
            }
        for (step, range) in ranges.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6 * Double(step)) { model.range = range }
        }
        if ProcessInfo.processInfo.environment["DESKPILOT_DEV_PAGE"] == "settings" {
            model.showsSettings = true
        }
        if nativePrefix != nil {
            // Date navigation resets the scroller's temporary offset. Apply a requested
            // Day preview to its resting window after navigation so native screenshots
            // can actually exercise fractional positions and midnight crossings.
            if model.range == .day, devScroll != 0 {
                let base = model.restingDayWindow
                let span = base.upperBound.timeIntervalSince(base.lowerBound)
                let latest = model.track(for: model.todayStart).domain.upperBound
                let upper = min(latest, base.upperBound.addingTimeInterval(-devScroll * 3600))
                model.rest(dayWindowAt: upper.addingTimeInterval(-span)...upper)
            }
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first(where: { $0.title == "Deskpilot Dashboard" }) {
                window.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .milliseconds(700))
                // Native window studies should capture the focused control appearance.
                // A real click may be needed when macOS refuses a background activation.
                if ProcessInfo.processInfo.environment["DESKPILOT_DEV_NATIVE_WAIT_FOR_FOCUS"] == "1" {
                    for _ in 0..<150 {
                        if NSApp.isActive { break }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    try? await Task.sleep(for: .milliseconds(1000))
                }
                func capture(_ suffix: String) {
                    // The window and anything it has open over it, such as a hover popover.
                    // Front to back: what is open over the window first.
                    let over = NSApp.windows
                        .filter { $0 !== window && $0.isVisible && $0.windowNumber > 0 && $0.frame.intersects(window.frame) }
                    let ids = over.map(\.windowNumber) + [window.windowNumber]
                    let pointers = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
                    let list = pointers.withUnsafeBufferPointer { CFArrayCreate(nil, UnsafeMutablePointer(mutating: $0.baseAddress), $0.count, nil) }
                    // The window, grown to take in anything open over it that runs past its edge.
                    let frame = over.reduce(window.frame) { $0.union($1.frame) }
                    let windowRect = CGRect(x: frame.minX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - frame.maxY,
                                            width: frame.width, height: frame.height)
                    if let list, let image = CGImage(windowListFromArrayScreenBounds: windowRect, windowArray: list,
                                                     imageOption: [.boundsIgnoreFraming, .bestResolution]) {
                        let bitmap = NSBitmapImageRep(cgImage: image)
                        if let data = bitmap.representation(using: .png, properties: [:]) {
                            try? data.write(to: URL(fileURLWithPath: prefix + suffix + ".png"))
                        }
                    }
                }
                // Record the actual chart and summary while moving its visible time window.
                // The developer driver uses synthetic history in an isolated data directory.
                if ProcessInfo.processInfo.environment["DESKPILOT_DEV_SCROLL_MOTION"] == "1" {
                    let base = model.restingDayWindow
                    for frame in 0..<80 {
                        let phase = Double(frame) / 79 * .pi * 2
                        let shift = (1 - cos(phase)) / 2 * 6 * 3600
                        model.rest(dayWindowAt: base.lowerBound.addingTimeInterval(-shift)...base.upperBound.addingTimeInterval(-shift))
                        try? await Task.sleep(for: .milliseconds(50))
                        capture(String(format: "-scroll-%04d", frame))
                    }
                }
                // `DESKPILOT_DEV_CALENDAR_MOTION=30` moves the open calendar's pretend pointer to
                // that cell and captures the glide frame by frame.
                if let target = ProcessInfo.processInfo.environment["DESKPILOT_DEV_CALENDAR_MOTION"].flatMap(Int.init) {
                    try? await Task.sleep(for: .milliseconds(300))
                    capture("-glide-0")
                    NotificationCenter.default.post(name: .tempoDevCalendarHover, object: target)
                    for frame in 1...10 {
                        try? await Task.sleep(for: .milliseconds(30))
                        capture("-glide-\(frame)")
                    }
                }
                if ProcessInfo.processInfo.environment["DESKPILOT_DEV_SUMMARY_MOTION"] == "1" {
                    capture("-motion-0")
                    if model.range == .day {
                        let base = model.restingDayWindow
                        let shift: TimeInterval = 7200
                        model.previewSummary(dayWindow: base.lowerBound.addingTimeInterval(-shift)...base.upperBound.addingTimeInterval(-shift), settling: true)
                    } else {
                        model.previewSummary(periodOffset: 1.5, settling: true)
                    }
                    for frame in 1...12 {
                        try? await Task.sleep(for: .milliseconds(40))
                        capture("-motion-\(frame)")
                    }
                    model.clearHeatmapPreview()
                    try? await Task.sleep(for: .milliseconds(350))
                }
                capture("-window")
            }
            NSApp.terminate(nil)
            return
        }
        // The History tab's content, not its ScrollView - ImageRenderer draws a ScrollView
        // blank. Dark, like the user's Mac; `DESKPILOT_DEV_LIGHT=1` for light.
        let renderer = ImageRenderer(content: HistoryContent()
            .environment(model)
            .padding(16)
            .frame(width: 640)
            .background(light ? Color(white: 0.96) : Color(red: 32 / 255, green: 33 / 255, blue: 36 / 255))
            .environment(\.colorScheme, light ? .light : .dark))
        renderer.scale = 2
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: prefix + "-history.png"))
        }
        NSApplication.shared.terminate(nil)
    }
}
