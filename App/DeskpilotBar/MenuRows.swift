import AppKit
import Combine
import SwiftUI
import DeskpilotKit

/// The custom rows of the status item's menu (see `StatusItemController`). Each is hosted in
/// an `NSMenuItem.view`, so it gets the system menu's Liquid Glass panel for free and keeps
/// updating live while the menu is open. Actions are ordinary menu items, not SwiftUI
/// buttons - those don't sit well inside a tracking menu.
enum MenuMetrics {
    /// Width of the custom rows' content; standard items pad out to match. Wider than any
    /// system menu (Control Center is 335, a Notification Center widget 344) so today's strip
    /// can label every second hour: at 344 its labels fit every third hour only, and the
    /// time-now capsule covered one of those.
    static let width: CGFloat = 460
    /// Matches the text inset of a standard menu item next to these rows.
    static let horizontalInset: CGFloat = 14
}

/// What the desk is doing or about to do, in one line, and the cruise control switch. The
/// height lives in Settings, next to the preset buttons that use it.
struct MenuHeaderRow: View {
    let model: DeskModel
    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        // What the desk is about to do, the way the stats below read: a small grey label over
        // the figure ("Sitting in" over "8:29"), the switch at the right, no icon (the menu bar
        // item is the icon). Anything more is in the tooltip.
        HStack(spacing: 10) {
            MenuHeadline(label: headline.label, value: headline.value)
                .help(tooltip ?? "")
            // Today's figures beside it, the way Health sets figures side by side: time at the
            // desk and stands, each a label over a figure like the headline. Only while the
            // headline is one too - a bare state ("Standing up…", "Out of reach") is the
            // whole message, and figures beside it would outweigh it.
            if headline.label != nil, let today = model.today {
                // In columns, not packed: a box is as wide as its label or its figure, whichever
                // is wider, so packed stats looked unevenly spaced ("Standing in" is wider than
                // "35:52", "6h 33m" wider than "At desk"). Fixed columns put each figure in the
                // same place all day, whatever it says.
                MenuHeadline(label: "At desk", value: Formatting.duration(today.atDeskSeconds))
                    .frame(width: MenuHeadline.statColumn, alignment: .leading)
                    .padding(.leading, MenuHeadline.statSpacing)
                MenuHeadline(label: "Stands", value: String(today.stands))
                    .frame(width: MenuHeadline.statColumn, alignment: .leading)
            }
            Spacer(minLength: 12)
            // Cruise control, where a VPN menu keeps its connect switch: blue when the desk
            // runs its rhythm, grey when paused. The same thing Command-P does. Out of reach
            // it stays in place, greyed, showing how the desk was left.
            Toggle("Cruise control", isOn: cruiseBinding)
                .toggleStyle(MenuSwitchStyle())
                .labelsHidden()
                .disabled(model.state.status != .connected || model.state.settings?.cruiseEnabled != true)
                .accessibilityLabel("Cruise control")
        }
        .padding(.horizontal, MenuMetrics.horizontalInset)
        .padding(.top, 2)
        .padding(.bottom, 4)
        .onReceive(timer) { now = $0 }
    }

    private var cruiseBinding: Binding<Bool> {
        Binding(
            get: { model.cruiseIsOn },
            set: { on in
                let model = model
                Task { _ = await model.setPaused(!on) }
            })
    }

    /// The header in every state: a label over a figure while there's something to count,
    /// otherwise just the state.
    private var headline: (label: String?, value: String) {
        switch model.state.status {
        case .connecting:
            guard let since = model.connectingSince else { return (nil, "Connecting…") }
            return ("Connecting", Self.seconds(now.timeIntervalSince(since)))
        case .disconnected: return (nil, "Out of reach")
        case .bluetoothOff: return (nil, "Turn on Bluetooth")
        case .unauthorized: return (nil, "Allow Bluetooth access")
        case .connected: break
        }
        let today = model.state.today
        if model.state.isMoving { return (nil, today?.nextMove?.toStanding == false ? "Sitting down…" : "Standing up…") }
        if today?.isPresent == false { return (nil, "Looking for you") }
        let posture = today?.isStanding.map { $0 ? "Standing" : "Sitting" } ?? "Connected"
        guard model.state.settings?.cruiseEnabled == true else { return (nil, posture) }
        if model.state.settings?.paused == true { return ("Cruise control", "Paused") }
        if let cancelled = today?.cancelledMove, cancelled.isShowing(now: now) {
            // "Stand" over "Cancelled": the move the desk announced, and what became of it.
            return (cancelled.toStanding ? "Stand" : "Sit", "Cancelled")
        }
        guard let next = today?.nextMove else { return (nil, posture) }
        // "Sitting in" over "8:29": when the desk will have you sitting (or standing).
        let then = next.toStanding ? "Standing" : "Sitting"
        if next.isAnnounced {
            // The desk is beeping: its own timing, to the second. Once that runs out, "Sitting"
            // over "Now" (not "Sitting in / now") for the moment before the motor starts - or,
            // if it never does, before the cancel is called.
            let countdown = Formatting.countdown(to: next.at, now: now)
            return countdown == "now" ? (then, "Now") : ("\(then) in", countdown)
        }
        if next.isAnnounced(now: now) || next.isOverdue(now: now) { return (then, "Soon") }
        return ("\(then) in", Formatting.countdown(to: next.announceAt, now: now))
    }

    /// What the header can't fit, on hover.
    private var tooltip: String? {
        switch model.state.status {
        case .connecting:
            return model.typicalConnectSeconds.map { "Usually connects in about \(Self.seconds($0))." }
        case .disconnected:
            if model.state.reconnectingInBackground { return "Checking for the desk every minute." }
            return model.lastSyncedAt.map { "Last synced " + $0.formatted(.relative(presentation: .named)) + "." }
        case .bluetoothOff: return "Turn Bluetooth on in Control Center."
        case .unauthorized: return "Allow Deskpilot to use Bluetooth in System Settings, Privacy & Security."
        case .connected: break
        }
        if model.state.today?.isPresent == false { return "Cruise control waits until the desk sees you again." }
        if let cancelled = model.state.today?.cancelledMove, cancelled.isShowing(now: now) {
            let move = cancelled.toStanding ? "stand" : "sit"
            let how = cancelled.reason == .reversed ? "You reversed the \(move) before it finished." : "You waved the \(move) off."
            if let next = model.state.today?.nextMove {
                return how + " The desk restarts its timer from there: \(move) in " + Formatting.countdownMinutes(to: next.announceAt, now: now) + "."
            }
            return how + " The desk restarts its timer from there."
        }
        guard let next = model.state.today?.nextMove else { return nil }
        if next.isAnnounced { return "The desk is beeping, and moves when it stops." }
        if next.isOverdue(now: now) {
            return "The estimate has passed. The desk picks the moment itself, and pauses whenever it doesn't see you."
        }
        if next.isAnnounced(now: now) { return "The desk beeps for 15 seconds, then moves." }
        return nil
    }

    /// "4 s", or "1:05" from a minute.
    private static func seconds(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval.rounded()))
        return s < 60 ? "\(s) s" : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The header's text: a small grey label over a figure, set tight so the pair is barely
/// taller than the switch beside it; or the figure alone, centred in the same height so the
/// menu doesn't jump between states.
struct MenuHeadline: View {
    let label: String?
    let value: String
    /// The header's columns: the headline's ("Standing in" over "35:52", or "Cruise control"
    /// over "Paused"), then two stats of a fixed width each, so the figures line up in the
    /// same places all day whatever they say. `statSpacing` is the air after the headline.
    static let headlineColumn: CGFloat = 104
    static let statColumn: CGFloat = 92
    static let statSpacing: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: -1) {
            if let label {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: label == nil ? 14 : 17, weight: label == nil ? .medium : .semibold))
                .monospacedDigit()
        }
        .lineLimit(1)
        .frame(height: 34)
        .accessibilityElement(children: .combine)
    }
}

/// A switch drawn by hand, because a system switch inside a menu takes the inactive-window
/// look and greys its tint: this one is blue when on and grey when off, whatever the window
/// state, like the switch in a VPN app's menu.
struct MenuSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let on = configuration.isOn
        // Proportions measured off Control Centre's Wi-Fi switch: a 52x22 track and a wide
        // 29x17 pill of a knob in a bluish white.
        return ZStack(alignment: on ? .trailing : .leading) {
            Capsule(style: .continuous)
                .fill(on ? DeskpilotAppearance.sitting : Color.primary.opacity(0.18))
            Capsule(style: .continuous)
                .fill(Color.white)
                .frame(width: 29, height: 17)
                .padding(2.5)
        }
        .frame(width: 52, height: 22)
        .opacity(isEnabled ? 1 : 0.45)
        .contentShape(Capsule())
        .onTapGesture { configuration.isOn.toggle() }
        .animation(.easeInOut(duration: 0.18), value: on)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(on ? "On" : "Off")
    }
}

/// Today's strip, each lane's total at its right end; a quiet line until there's a spell.
struct MenuStatsRow: View {
    let model: DeskModel
    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            // Only once there's something to draw: an empty strip is just a tall blank gap.
            if model.todaySegments.contains(where: { $0.state != .away }) {
                NonVibrant(content: MenuTimelineStrip(segments: model.todaySegments, now: now,
                                                      dayStartHour: model.typicalDayStartHour))
            } else {
                Text("No time at the desk yet today")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, MenuMetrics.horizontalInset)
        .padding(.vertical, 8)
        .onReceive(timer) { now = $0 }
    }
}

/// A line of secondary text: a connection error, or the outcome of a failed action.
struct MenuMessageRow: View {
    let text: String
    var isError = false

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MenuMetrics.horizontalInset)
            .padding(.vertical, 6)
    }
}

enum DashboardLauncher {
    /// Opens the Dashboard app: the settled install path first, then a bundle-id lookup as a
    /// fallback (e.g. it hasn't been installed to `/Applications` yet, or was moved).
    static func open() {
        let installedPath = "/Applications/Deskpilot Dashboard.app"
        if FileManager.default.fileExists(atPath: installedPath) {
            NSWorkspace.shared.open(URL(fileURLWithPath: installedPath))
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.kevinpatel.tempo.dashboard") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Interpolates the desk height readout toward each new sample, monotonically: it can only
/// move *toward* the latest value and never overshoots past it.
///
/// SwiftUI's built-in `.animation(value:)` retargeting is additive - a lower sample
/// arriving mid-ramp toward a higher one first keeps easing toward that now-stale higher
/// target before turning around, which reads as the number going up too much and then
/// lowering once the desk actually stops. This instead tracks its own `from`/`target`/
/// `duration` and computes the displayed value directly from wherever the ramp currently
/// is, so a new sample simply redirects it rather than compounding with the old one.
struct InterpolatedInches: View {
    var tenths: Double
    var isMoving: Bool

    @State private var from: Double = 0
    @State private var fromTime: Date = .distantPast
    @State private var target: Double = 0
    @State private var duration: TimeInterval = 0.3
    @State private var previousSampleTime: Date?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isMoving)) { context in
            // Paused (not moving), just show the target - no reason to keep computing a
            // ramp toward a value it has already reached.
            let value = isMoving ? displayed(at: context.date) : target
            Text(String(format: "%.1f\"", value / 10))
                .monospacedDigit()
        }
        .onAppear { retarget(to: tenths, at: Date()) }
        .onChange(of: tenths) { _, newValue in retarget(to: newValue, at: Date()) }
    }

    private func displayed(at date: Date) -> Double {
        let t = min(1, max(0, date.timeIntervalSince(fromTime) / duration))
        return from + (target - from) * t
    }

    private func retarget(to newTenths: Double, at now: Date) {
        if let previousSampleTime {
            from = displayed(at: now)
            duration = min(1.0, max(0.15, now.timeIntervalSince(previousSampleTime)))
        } else {
            // No prior sample to ramp from - `displayed(at:)` against the zeroed defaults
            // would compute 0, and the readout would visibly ramp up from 0.0" if the view
            // first appears while the desk is already moving. Show the first reading as-is.
            from = newTenths
        }
        fromTime = now
        previousSampleTime = now
        target = newTenths
    }
}
