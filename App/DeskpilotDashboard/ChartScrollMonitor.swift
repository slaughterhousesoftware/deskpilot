import AppKit
import SwiftUI

/// Two-finger horizontal scrolling over a chart, read straight off the trackpad: every delta
/// as the fingers move, then the system's momentum as the content coasts, then one call once
/// it has come to rest. This view only reads the trackpad; the chart decides what moves.
///
/// A plain scroll, not AppKit's page-swipe tracking, so it works whatever "Swipe between
/// pages" is set to. The transparent view never takes clicks; it watches scroll events over
/// its own bounds through a local monitor, and lets vertical scrolls through untouched.
struct ChartScrollMonitor: NSViewRepresentable {
    /// A sideways scroll has started over the chart.
    var onBegin: () -> Void
    /// Points the content should move by, signed as the content moves (positive is rightwards,
    /// towards the past), so it follows the user's scroll direction setting; whether it is
    /// momentum, which should stop at an end rather than rubber-band on past it; and the
    /// event's own timestamp (system uptime), for measuring the fingers' speed.
    var onScroll: (CGFloat, Bool, TimeInterval) -> Void
    /// Momentum that turned up after the end was already called, still carrying that scroll
    /// on. `nil` treats it as a new scroll (`onBegin`); a chart already gliding to rest on its
    /// own passes a handler so it isn't restarted.
    var onLateMomentum: (() -> Void)? = nil
    /// The fingers have just lifted off a sideways scroll - before any momentum, which may
    /// take a moment to start. A chart that glides to rest by itself starts from here rather
    /// than standing still while it waits for `onEnd`.
    var onLift: (() -> Void)? = nil
    /// The fingers have lifted and any momentum has run out.
    var onEnd: () -> Void

    func makeNSView(context: Context) -> MonitorView { MonitorView() }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onBegin = onBegin
        view.onScroll = onScroll
        view.onLateMomentum = onLateMomentum
        view.onLift = onLift
        view.onEnd = onEnd
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stopObserving() }

    final class MonitorView: NSView {
        var onBegin: () -> Void = {}
        var onScroll: (CGFloat, Bool, TimeInterval) -> Void = { _, _, _ in }
        var onLateMomentum: (() -> Void)?
        var onLift: (() -> Void)?
        var onEnd: () -> Void = {}
        private var monitor: Any?

        /// Where the gesture under the fingers stands. Undecided until it has moved far
        /// enough to tell a sideways scroll from a vertical one; coasting from lift-off until
        /// the momentum (if any) has run out.
        private enum Gesture { case none, undecided, horizontal, vertical, coasting }
        private var gesture = Gesture.none
        private var horizontalDistance: CGFloat = 0
        private var verticalDistance: CGFloat = 0
        /// Lift-off without a flick sends no momentum at all, so the end is called after a
        /// short wait unless momentum begins first.
        private var pendingEnd: DispatchWorkItem?
        /// When the last sideways gesture's fingers lifted, so momentum that turns up after
        /// the wait above still carries that scroll on rather than leaking to the window.
        private var liftedAt: TimeInterval?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
        }

        func stopObserving() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            pendingEnd?.cancel()
            pendingEnd = nil
            gesture = .none
        }

        private func end() {
            pendingEnd?.cancel()
            pendingEnd = nil
            gesture = .none
            onEnd()
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window, event.hasPreciseScrollingDeltas else { return event }

            if !event.momentumPhase.isEmpty {
                if gesture == .none, event.momentumPhase.contains(.began),
                   let liftedAt, event.timestamp - liftedAt < 0.15 {
                    gesture = .coasting
                    if let onLateMomentum { onLateMomentum() } else { onBegin() }
                }
                guard gesture == .coasting else { return event }
                if event.momentumPhase.contains(.began) {
                    pendingEnd?.cancel()
                    pendingEnd = nil
                }
                if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
                    end()
                } else {
                    onScroll(event.scrollingDeltaX, true, event.timestamp)
                }
                return nil
            }

            // Fingers back down while the content coasts: that scroll is over, and this
            // gesture is a new one.
            if gesture == .coasting, !event.phase.isEmpty { end() }

            if event.phase.contains(.began) {
                // Only a gesture that starts over the chart is the chart's. (The performance
                // test's synthetic flicks can't place themselves, so it waives this.)
                guard DevPerfDriver.outputPath != nil || bounds.contains(convert(event.locationInWindow, from: nil)) else {
                    gesture = .none
                    return event
                }
                gesture = .undecided
                liftedAt = nil
                horizontalDistance = 0
                verticalDistance = 0
            }

            switch gesture {
            case .none, .vertical, .coasting:
                return event
            case .undecided:
                guard event.phase.contains(.began) || event.phase.contains(.changed) else {
                    gesture = .none
                    return event
                }
                horizontalDistance += event.scrollingDeltaX
                verticalDistance += event.scrollingDeltaY
                let x = abs(horizontalDistance)
                let y = abs(verticalDistance)
                if y > 6, y > x * 1.5 {
                    gesture = .vertical
                    return event
                }
                guard x > 6, x > y * 1.5 else { return event }
                gesture = .horizontal
                onBegin()
                // The distance spent deciding is part of the scroll, so the content catches
                // up with the fingers rather than lagging them by it.
                onScroll(horizontalDistance, false, event.timestamp)
                return nil
            case .horizontal:
                if event.phase.contains(.cancelled) {
                    end()
                } else if event.phase.contains(.ended) {
                    gesture = .coasting
                    liftedAt = event.timestamp
                    onLift?()
                    let item = DispatchWorkItem { [weak self] in
                        guard let self, self.gesture == .coasting else { return }
                        self.end()
                    }
                    pendingEnd = item
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: item)
                } else {
                    onScroll(event.scrollingDeltaX, false, event.timestamp)
                }
                return nil
            }
        }
    }
}
