import AppKit
import QuartzCore
import SwiftUI

/// A development stress test of the Dashboard's rendering: `DESKPILOT_DEV_PERF=/tmp/perf.json`
/// switches ranges, flicks every chart back and forth with trackpad-like scroll events and
/// steps through periods, timing every display refresh, then writes what it measured and quits.
///
/// Each phase reports its frames, the refresh period, the worst gap between frames, how many
/// gaps ran past one and a half refreshes (a visible hitch), and the hitch time ratio - the
/// milliseconds lost to late frames per second, as Instruments reports it (under 5 is good).
@MainActor
enum DevPerfDriver {
    nonisolated static let outputPath: String? = ProcessInfo.processInfo.environment["DESKPILOT_DEV_PERF"]

    /// `DESKPILOT_DEV_PERF_OMIT=chart,heatmap` leaves those parts of the dashboard out, to see
    /// what each costs. Read once: views ask on every redraw.
    private nonisolated static let omitted = Set((ProcessInfo.processInfo.environment["DESKPILOT_DEV_PERF_OMIT"] ?? "")
        .split(separator: ",").map(String.init))
    nonisolated static func omits(_ part: String) -> Bool { omitted.contains(part) }

    static func run(model: DashboardModel) async {
        guard let path = outputPath else { return }
        try? await Task.sleep(for: .seconds(2.5))
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let content = window.contentView else { return }
        let clock = FrameClock(view: content)
        var phases: [[String: Any]] = []
        var moved: [String: Bool] = [:]
        var switches: [String] = []
        let rounds = Int(ProcessInfo.processInfo.environment["DESKPILOT_DEV_PERF_ROUNDS"] ?? "") ?? 1

        // `DESKPILOT_DEV_PERF_ONLY=scroll-week` runs just the phases whose names contain it.
        let only = ProcessInfo.processInfo.environment["DESKPILOT_DEV_PERF_ONLY"]
        func phase(_ name: String, _ body: () async -> Void) async {
            if let only, !name.contains(only) { return }
            let start = CACurrentMediaTime()
            clock.mark()
            await body()
            phases.append(clock.report(name: name, since: start))
        }

        // `DESKPILOT_DEV_PERF_CHECK=/tmp/check` captures the window through a series of switches
        // and steps, to see that a chart kept hidden comes back on the right period.
        if let check = ProcessInfo.processInfo.environment["DESKPILOT_DEV_PERF_CHECK"] {
            func shot(_ name: String) async {
                await pause(0.9)
                let frame = window.frame
                let rect = CGRect(x: frame.minX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - frame.maxY, width: frame.width, height: frame.height)
                let pointers = [UnsafeRawPointer(bitPattern: UInt(window.windowNumber))]
                let list = pointers.withUnsafeBufferPointer { CFArrayCreate(nil, UnsafeMutablePointer(mutating: $0.baseAddress), $0.count, nil) }
                if let list, let image = CGImage(windowListFromArrayScreenBounds: rect, windowArray: list, imageOption: [.boundsIgnoreFraming]),
                   let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: "\(check)-\(name).png"))
                }
            }
            model.range = .day; await shot("1-day-today")
            model.range = .week; await shot("2-week-today")
            model.goToPreviousDay(); model.goToPreviousDay(); await shot("3-week-back2")
            model.range = .month; await shot("4-month")
            model.range = .week; await shot("5-week-again")
            model.range = .day; await shot("6-day")
            model.goToToday(); model.range = .month; await shot("7-month-today")
            NSApp.terminate(nil)
            return
        }
        await phase("idle") { await pause(1.5) }
        for _ in 0..<rounds {
            // Where the pointer is when someone switches tabs: on the tabs, not over a chart.
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            CGWarpMouseCursorPosition(CGPoint(x: window.frame.midX, y: top - window.frame.maxY + 26))
            await phase("switch-tabs") {
                for range in [HistoryRange.week, .month, .day, .month, .week, .day, .week, .day, .month, .day] {
                    let from = model.range
                    let mark = clock.stamps.count
                    let started = CACurrentMediaTime()
                    model.range = range
                    await pause(0.6)
                    switches.append("\(from.rawValue)>\(range.rawValue) \(clock.worstGap(from: mark))/\(clock.longestBusy(since: started))")
                }
            }
            for range in HistoryRange.allCases {
                model.range = range
                model.goToToday()
                await pause(0.8)
                await phase("scroll-\(range.rawValue)") {
                    // Fast flicks back in time, then forward again.
                    let before = model.restingDayWindow.lowerBound
                    let beforeDay = model.selectedDayStart
                    for _ in 0..<4 { await flick(in: window, by: 70, momentum: 0.85) }
                    moved["\(range.rawValue)"] = model.restingDayWindow.lowerBound != before || model.selectedDayStart != beforeDay
                    for _ in 0..<4 { await flick(in: window, by: -70, momentum: 0.85) }
                    // Slow drags with no momentum.
                    await flick(in: window, by: 12, momentum: 0)
                    await flick(in: window, by: -12, momentum: 0)
                    await pause(0.6)
                }
                await phase("step-\(range.rawValue)") {
                    for _ in 0..<5 {
                        model.goToPreviousDay()
                        await pause(0.35)
                    }
                    model.goToToday()
                    await pause(0.6)
                }
            }
            model.range = .day
            model.goToToday()
        }
        let report: [String: Any] = ["refreshHz": (1 / clock.period).rounded(), "phases": phases, "scrollMoved": moved, "switches": switches]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        NSApp.terminate(nil)
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// A two-finger flick sideways over the chart: the fingers moving `perEvent` points every
    /// 8 ms for a dozen events, lifting, and (if `momentum` is above zero) the system's
    /// momentum decaying by that factor each event.
    private static func flick(in window: NSWindow, by perEvent: Double, momentum: Double) async {
        guard let target = scrollTarget(in: window) else { return }
        func post(_ dx: Double, phase: Int64, momentumPhase: Int64) {
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                      wheel1: 0, wheel2: Int32(dx.rounded()), wheel3: 0) else { return }
            event.location = target
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumPhase)
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx.rounded()))
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: dx)
            // The window under the pointer, so the event is the window's.
            for field in [51, 91, 92] {
                if let field = CGEventField(rawValue: UInt32(field)) {
                    event.setIntegerValueField(field, value: Int64(window.windowNumber))
                }
            }
            if let ns = NSEvent(cgEvent: event) { NSApp.postEvent(ns, atStart: false) }
        }
        post(0, phase: 1, momentumPhase: 0)
        for _ in 0..<12 {
            await pause(0.008)
            post(perEvent, phase: 2, momentumPhase: 0)
        }
        await pause(0.008)
        post(0, phase: 4, momentumPhase: 0)
        if momentum > 0 {
            var dx = perEvent
            await pause(0.02)
            post(dx, phase: 0, momentumPhase: 1)
            while abs(dx) > 1 {
                await pause(0.008)
                dx *= momentum
                post(dx, phase: 0, momentumPhase: 2)
            }
            post(0, phase: 0, momentumPhase: 3)
        }
        await pause(0.45)
    }

    /// The middle of the chart on screen, in the global display coordinates events use.
    private static func scrollTarget(in window: NSWindow) -> CGPoint? {
        guard let content = window.contentView else { return nil }
        guard let monitor = monitors(in: content).first(where: { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor }) else { return nil }
        let inWindow = monitor.convert(NSPoint(x: monitor.bounds.midX, y: monitor.bounds.midY), to: nil)
        let onScreen = window.convertPoint(toScreen: inWindow)
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: onScreen.x, y: top - onScreen.y)
    }

    private static func monitors(in view: NSView) -> [ChartScrollMonitor.MonitorView] {
        if let monitor = view as? ChartScrollMonitor.MonitorView { return [monitor] }
        return view.subviews.flatMap(monitors(in:))
    }
}

/// Every display refresh's time, from the window's own display link.
@MainActor
private final class FrameClock: NSObject {
    private var link: CADisplayLink?
    private(set) var stamps: [CFTimeInterval] = []
    private(set) var period: CFTimeInterval = 1.0 / 60
    private var startIndex = 0

    /// Each pass of the main run loop's work, from waking to going back to sleep, as (end, length).
    private(set) var busy: [(end: CFTimeInterval, length: CFTimeInterval)] = []
    private var wokeAt: CFTimeInterval?
    private var observer: CFRunLoopObserver?

    init(view: NSView) {
        super.init()
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
                                                          true, 0) { [weak self] _, activity in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = CACurrentMediaTime()
                if activity == .afterWaiting { self.wokeAt = now } else if let woke = self.wokeAt {
                    self.busy.append((now, now - woke))
                    self.wokeAt = nil
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        stamps.append(CACurrentMediaTime())
        if link.duration > 0 { period = link.duration }
    }

    func mark() { startIndex = stamps.count }

    /// The longest the main thread worked without sleeping since `time`, in milliseconds.
    func longestBusy(since time: CFTimeInterval) -> Double {
        let worst = busy.filter { $0.end >= time }.map(\.length).max() ?? 0
        return (worst * 10_000).rounded() / 10
    }

    /// The longest gap between frames since frame `index`, in milliseconds.
    func worstGap(from index: Int) -> Double {
        let slice = stamps[max(0, index - 1)...]
        let worst = zip(slice.dropFirst(), slice).map { $0 - $1 }.max() ?? 0
        return (worst * 10_000).rounded() / 10
    }

    func report(name: String, since start: CFTimeInterval) -> [String: Any] {
        let slice = Array(stamps[startIndex...])
        let gaps = zip(slice.dropFirst(), slice).map { $0 - $1 }
        let elapsed = max(CACurrentMediaTime() - start, 0.001)
        let lost = gaps.reduce(0) { $0 + max(0, $1 - period * 1.05) }
        let sorted = gaps.sorted()
        func ms(_ value: Double) -> Double { (value * 10_000).rounded() / 10 }
        return [
            "phase": name,
            "seconds": ms(elapsed) / 1000,
            "frames": slice.count,
            "worstGapMs": ms(sorted.last ?? 0),
            "p95GapMs": ms(sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * 0.95)]),
            "hitches": gaps.filter { $0 > period * 1.5 }.count,
            "hitchMsPerSecond": ms(lost / elapsed),
            "worstGaps": sorted.suffix(5).reversed().map(ms),
        ]
    }
}
