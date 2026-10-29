import SwiftUI
import DeskpilotKit

struct MenuBarLabel: View {
    let state: DeskState
    @State private var lastMovingAt: Date?

    var body: some View {
        // A `MenuBarExtra` label is flattened by the system into one image plus one string -
        // a second `Text` sibling in the `HStack` would simply be dropped - so `text`
        // always resolves to at most one `Text`, never two shown side by side.
        HStack(alignment: .center, spacing: 4) {
            icon
            if showMoving, state.status == .connected, let tenths = state.heightTenths {
                // The same ramping readout the menu uses, so the height glides between
                // samples instead of stepping once a second. (Live views work here now that
                // the label is a hosting view inside an NSStatusItem.) The real height, not
                // the backend's predicted stop: a prediction a tenth high reads as the number
                // ticking back when the desk settles, and the desk's own readings never do.
                InterpolatedInches(tenths: Double(tenths), isMoving: state.isMoving)
                    .font(.system(size: 13, weight: .regular))
            } else if case .cancelled(let cancelled) = tier, state.status == .connected {
                // The desk, struck through, and the word: the move it announced didn't
                // happen. The backend displays the finding briefly, then restores
                // the countdown while retaining the finding to avoid reporting it twice.
                CancelledPill()
                    .accessibilityLabel(cancelled.toStanding ? "Stand cancelled" : "Sit cancelled")
                    .help(cancelled.toStanding ? "The stand was cancelled; the countdown has restarted"
                                               : "The sit was cancelled; the countdown has restarted")
            } else if let text {
                text.font(.system(size: 13, weight: .regular))
            }
        }
        .frame(height: 22)
        .fixedSize() // natural width, not whatever an earlier/shorter render happened to have
        .onChange(of: state.isMoving) { _, isMoving in
            if !isMoving { lastMovingAt = state.updatedAt }
        }
    }

    /// The label's content while connected, in priority order - never just the glyph with
    /// nothing else to explain it.
    private enum Tier {
        /// Moving, or briefly after (see `showMoving`).
        case movingOrSettling
        /// The desk announced a move and the user stopped it, a moment ago.
        case cancelled(CancelledMove)
        /// Cruise control has a move scheduled.
        case countdown(NextMove)
        /// The desk is pausing its rhythm because it doesn't see anyone at the desk.
        case away
        /// The user paused cruise control.
        case paused
        /// Cruise control is off (the fallback once none of the above apply).
        case cruiseOff
    }

    private var tier: Tier {
        if showMoving { return .movingOrSettling }
        if let cancelled = state.today?.cancelledMove, cancelled.isShowing(now: state.updatedAt) {
            return .cancelled(cancelled)
        }
        if let next = state.today?.nextMove { return .countdown(next) }
        if state.today?.isPresent == false { return .away }
        if state.settings?.paused == true { return .paused }
        return .cruiseOff
    }

    @ViewBuilder private var icon: some View {
        switch state.status {
        case .connected:
            switch tier {
            case .movingOrSettling: Image(systemName: "arrow.up.and.down.circle.fill").font(.system(size: 14, weight: .medium))
            // Paused keeps the desk and its posture - the pause is a fact about cruise
            // control, not about the desk, and a bare pause symbol in the desk's place read
            // as the desk having gone somewhere.
            case .countdown, .cruiseOff, .paused: postureGlyph
            case .cancelled: SlashedGlyph(glyph: state.today?.isStanding == true ? .standing : .sitting)
            case .away: glyph(.looking)
            }
        case .connecting, .disconnected:
            if state.reconnectingInBackground {
                glyph(.unreachable)
                    .opacity(0.5)
                    .accessibilityLabel("Desk out of reach; reconnecting in the background")
                    .help("Desk out of reach — checking every minute")
            } else {
                ConnectingGlyph(isConnecting: state.status == .connecting)
                    .accessibilityLabel(state.status == .connecting ? "Connecting to the desk" : "Desk out of reach")
                    .help(state.status == .connecting ? "Connecting to the desk" : "Desk out of reach")
            }
        case .bluetoothOff, .unauthorized: glyph(.unavailable)
        }
    }

    /// `nil` (nothing shown after the glyph) for `.away` - the icon alone already says why
    /// there's no countdown. `.monospacedDigit()` on the numeric cases so the item's width
    /// doesn't wobble as the digits change.
    private var text: Text? {
        guard state.status == .connected else { return nil }
        switch tier {
        case .movingOrSettling:
            // Normally drawn by `InterpolatedInches` above; this is the fallback with no height.
            return Text(Formatting.height(tenths: state.heightTenths)).monospacedDigit()
        case .countdown(let next):
            // "↓20m" = sit in about 20 minutes, "↑20m" = stand - an estimate, counting down
            // to when the desk should start beeping. Once the desk has actually announced
            // the move (its COUNTDOWN entry was read) the figure is the desk's own: "↓0:12"
            // in seconds to the motor. Between the estimate running out and the desk's
            // announcement it reads "↓soon", and "↓…" once that has gone on long enough to
            // look wrong (`isOverdue`) - the desk decides the exact moment. The clock here
            // is the desk state's own timestamp, refreshed every second by the actor.
            let now = state.updatedAt
            let countdown: String
            if next.isAnnounced {
                countdown = Formatting.countdown(to: next.at, now: now)
            } else if next.isOverdue(now: now) {
                countdown = "…"
            } else if next.isAnnounced(now: now) {
                countdown = "soon"
            } else {
                countdown = Formatting.countdownMinutes(to: next.announceAt, now: now)
            }
            // An inline SF Symbol does not survive MenuBarExtra's image+string flattening, so
            // the arrow is a text glyph in a rounded semibold face that matches the digits.
            // Thin space between the arrow and the digits so they don't touch.
            return (Text(next.toStanding ? "↑" : "↓").font(.system(size: 13, weight: .semibold, design: .rounded))
                    + Text("\u{2009}") + Text(countdown))
                .monospacedDigit()
        case .cancelled:
            return nil // the pill is drawn by `body`
        case .away:
            return nil
        case .paused:
            return Text("paused")
        case .cruiseOff:
            return Text("off")
        }
    }

    private var postureGlyph: some View {
        glyph(state.today?.isStanding == true ? .standing : .sitting)
    }

    /// 20 pt: about 18 pt of ink, a touch larger than the neighbouring menu bar symbols (16 pt,
    /// measured at 32 px at 2x), which is as big as the 24 pt bar comfortably takes.
    private func glyph(_ glyph: DeskGlyph) -> some View {
        Image(nsImage: glyph.templateImage(pointSize: 20))
    }

    /// True while actually moving, or for 2 s after a move ends (`state.updatedAt` is the
    /// desk state's own clock, refreshed every poll - not wall-clock time, so this holds
    /// even if the popover/menu isn't being watched live) - long enough for the final
    /// settled height to actually be seen before the countdown reclaims that space.
    private var showMoving: Bool {
        state.isMoving || (lastMovingAt.map { state.updatedAt.timeIntervalSince($0) < 2 } ?? false)
    }

}

/// The posture glyph with the system's slash through it, drawn the way `bell.slash` strikes
/// its bell: one stroke from lower left to upper right, and a gap cut out of the glyph on
/// either side so the stroke never touches what it crosses. The slash takes the desk, not
/// the person: the desk's move was cancelled, they are still there. The desk has the mass a
/// slash needs; the countdown's arrow (all stroke) did not, so the word is in the pill.
struct SlashedGlyph: View {
    let glyph: DeskGlyph
    /// Where the stroke runs: from the desk's left foot up through its column and surface,
    /// stopping short of the monitor, which it only clips. The person is left alone: it's
    /// the desk's move that was cancelled, not them.
    private let left: CGFloat = 0.5
    private let top: CGFloat = 7
    private let gap: CGFloat = 1.2
    var body: some View {
        Canvas { context, size in
            let image = glyph.templateImage(pointSize: 20)
            context.draw(context.resolve(Image(nsImage: image)), at: CGPoint(x: size.width / 2, y: size.height / 2), anchor: .center)
            var slash = Path()
            slash.move(to: CGPoint(x: size.width * left, y: size.height - 1))
            slash.addLine(to: CGPoint(x: size.width - 1.5, y: top))
            var knockout = context
            knockout.blendMode = .destinationOut
            knockout.stroke(slash, with: .color(.black), style: StrokeStyle(lineWidth: 1.6 + 2 * gap, lineCap: .round))
            context.stroke(slash, with: .foreground, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        }
        .frame(width: 22, height: 20)
    }
}

/// "CANCELLED" in a solid capsule, small caps-sized so it sits inside the 22 pt item. The
/// capsule is the label colour and the word the bar's: white with dark text on the dark bar,
/// the reverse on the light one, so it reads as a badge rather than a tinted smudge.
struct CancelledPill: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        // The text face at 10 pt, semibold, a touch of tracking: the rounded bold at 9 pt
        // smeared on the bar's glass and was hard to read.
        Text("CANCELLED")
            .font(.system(size: 10, weight: .semibold)).tracking(0.3)
            .foregroundStyle(scheme == .dark ? Color(white: 0.1) : Color.white)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(Capsule().fill(scheme == .dark ? Color.white : Color(white: 0.15)))
    }
}

/// The searching glyph: the desk and three dots. While Deskpilot is connecting each dot lifts and
/// drops in turn, left to right, like a typing indicator; out of reach the dots rest and the
/// whole icon dims. Between the two nothing jumps: the wave grows out of the resting dots and
/// dies back down into them, and the dimming eases. The desk is the same template image as
/// every other state; the dots are drawn over the spots where `DeskGlyph.searching` puts them
/// (radius 1 at x 2.4 / 4.9 / 7.4, y 11.2 on the 20 x 18 canvas, scaled to the 22 x 20 pt image).
private struct ConnectingGlyph: View {
    let isConnecting: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// When connecting last started (the wave is timed from it) and last stopped (the wave
    /// dies down over the moment after it).
    @State private var startedAt = Date.distantPast
    @State private var stoppedAt = Date.distantPast
    /// Kept on for a moment after connecting stops, while the wave settles.
    @State private var settling = false
    @State private var waving = false

    /// The image's scale from the design canvas, and the dots in image points.
    private static let unit: CGFloat = 1.1
    private static let centres: [CGFloat] = [2.4, 4.9, 7.4].map { $0 * unit }
    private static let baseline: CGFloat = 11.2 * unit + 0.1
    private static let radius: CGFloat = 1 * unit
    /// How high a dot lifts, how long one wave takes, and how far behind each dot follows.
    private static let lift: CGFloat = 3
    private static let period: Double = 0.95
    private static let stagger: Double = 0.14
    /// How long the wave takes to die down once connecting stops.
    private static let settle: Double = 0.45

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(nsImage: DeskGlyph.outOfReach.templateImage(pointSize: 20))
            if reduceMotion {
                dots { _ in 0 }
            } else {
                TimelineView(.animation(paused: !(waving || settling))) { context in
                    let elapsed = context.date.timeIntervalSince(startedAt)
                    // Full height while connecting; easing to nothing once it stops.
                    let amplitude = waving ? 1 : max(0, 1 - context.date.timeIntervalSince(stoppedAt) / Self.settle)
                    dots { index in
                        Self.height(at: elapsed - Double(index) * Self.stagger) * CGFloat(amplitude * amplitude)
                    }
                }
            }
        }
        .opacity(isConnecting ? 1 : 0.5)
        .animation(.easeInOut(duration: 0.4), value: isConnecting)
        .task(id: isConnecting) {
            if isConnecting && !reduceMotion {
                startedAt = Date()
                waving = true
                do {
                    // Three waves are enough to acknowledge the attempt. A long Bluetooth
                    // timeout should not keep drawing attention to the menu bar.
                    try await Task.sleep(for: .seconds(Self.period * 3 + Self.stagger * 2))
                } catch { return }
            }
            stoppedAt = Date()
            waving = false
            settling = !reduceMotion
            do {
                try await Task.sleep(for: .seconds(Self.settle + 0.1))
            } catch { return }
            settling = false
        }
    }

    private func dots(_ height: @escaping (Int) -> CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(.primary)
                    .frame(width: 2 * Self.radius, height: 2 * Self.radius)
                    .offset(x: Self.centres[index] - Self.radius,
                            y: Self.baseline - Self.radius - height(index))
            }
        }
    }

    /// A quick rise and a softer fall over the first 55% of each wave, then a rest; nothing
    /// before the first wave starts, so a dot waits its turn at rest.
    private static func height(at time: Double) -> CGFloat {
        guard time > 0 else { return 0 }
        let p = (time / period).truncatingRemainder(dividingBy: 1)
        guard p < 0.55 else { return 0 }
        let x = p / 0.55
        let up = 0.38
        let curve = x < up
            ? 1 - pow(1 - x / up, 3)                 // ease out on the way up
            : 1 - pow((x - up) / (1 - up), 2)       // ease in on the way down
        return lift * CGFloat(curve)
    }
}
