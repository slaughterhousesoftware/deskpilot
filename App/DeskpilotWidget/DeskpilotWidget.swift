import WidgetKit
import SwiftUI
import DeskpilotKit

struct DeskpilotEntry: TimelineEntry {
    let date: Date
    let snapshot: DeskSnapshot?

    var isStale: Bool {
        guard let snapshot else { return true }
        // 5x margin (10 min) because timeline entries are rendered ahead of time (the app
        // schedules entries up to 15 min out) and WidgetKit may delay reloads well past the
        // snapshot's own staleness window, so a tight threshold here would flicker to
        // "disconnected" on perfectly live data.
        return !snapshot.connected || date.timeIntervalSince(snapshot.updatedAt) > DeskSnapshot.staleAfter * 5
    }
}

struct DeskpilotProvider: TimelineProvider {
    func placeholder(in context: Context) -> DeskpilotEntry {
        DeskpilotEntry(date: Date(), snapshot: DeskSnapshot(
            updatedAt: Date(), connected: true, heightTenths: 411, isMoving: false, isPresent: true,
            isStanding: true, atDeskSeconds: 3 * 3600 + 20 * 60, standsToday: 6,
            nextMove: NextMove(at: Date().addingTimeInterval(11 * 60), toStanding: false),
            paused: false, cruise: nil, sittingHeightTenths: 266, standingHeightTenths: 411))
    }

    func getSnapshot(in context: Context, completion: @escaping (DeskpilotEntry) -> Void) {
        completion(DeskpilotEntry(date: Date(), snapshot: SnapshotStore().read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DeskpilotEntry>) -> Void) {
        let snapshot = SnapshotStore().read()
        let now = Date()
        var entries = [DeskpilotEntry(date: now, snapshot: snapshot)]
        if let next = snapshot?.nextMove?.announceAt, next > now {
            // One entry per minute so the countdown and at-desk time keep moving.
            var t = now.addingTimeInterval(60)
            while t < next && entries.count < 90 {
                entries.append(DeskpilotEntry(date: t, snapshot: snapshot))
                t = t.addingTimeInterval(60)
            }
            entries.append(DeskpilotEntry(date: next, snapshot: snapshot))
            // Without these, the timeline stops exactly at `next` and would show "now" until
            // WidgetKit's next reload (up to 15 min later, per the policy below) instead of
            // ever flipping to "soon" once it's actually overdue (`NextMove.isOverdue`, 90 s).
            entries.append(DeskpilotEntry(date: next.addingTimeInterval(91), snapshot: snapshot))
            entries.append(DeskpilotEntry(date: next.addingTimeInterval(151), snapshot: snapshot))
        } else {
            for i in 1...15 { entries.append(DeskpilotEntry(date: now.addingTimeInterval(Double(i) * 60), snapshot: snapshot)) }
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(15 * 60))))
    }
}

struct DeskpilotWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: DeskpilotEntry

    var body: some View {
        Group {
            if entry.isStale { stale } else if family == .systemSmall { small } else { medium }
        }
        .containerBackground(.background, for: .widget)
    }

    private var snap: DeskSnapshot { entry.snapshot! }

    /// At-desk time grows while present between app refreshes.
    private var atDesk: TimeInterval {
        guard snap.isPresent else { return snap.atDeskSeconds }
        return snap.atDeskSeconds + max(0, entry.date.timeIntervalSince(snap.updatedAt))
    }

    private var stale: some View {
        VStack(spacing: 6) {
            DeskGlyphShape(.outOfReach).fill(.secondary).frame(width: 28 * DeskGlyph.outOfReach.aspectRatio, height: 28)
            Text("Deskpilot not connected").font(.caption).multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            postureLabel
            Spacer(minLength: 0)
            countdownBlock
            Spacer(minLength: 0)
            HStack {
                statBlock("Stands", "\(snap.standsToday)")
                Spacer()
                statBlock("At desk", Formatting.duration(atDesk))
            }
        }
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                postureLabel
                Spacer(minLength: 0)
                countdownBlock
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 10) {
                statBlock("Height", Formatting.height(tenths: snap.heightTenths), trailing: true)
                statBlock("Stands today", "\(snap.standsToday)", trailing: true)
                statBlock("At desk", Formatting.duration(atDesk), trailing: true)
            }
        }
    }

    private var postureLabel: some View {
        HStack(spacing: 4) {
            DeskGlyphShape(!snap.isPresent ? .looking : (snap.isStanding == true ? .standing : .sitting))
                .fill(.secondary)
                .frame(width: 16, height: 16)
            Text(snap.isStanding == true ? "Standing" : "Sitting")
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private var countdownBlock: some View {
        if let next = snap.nextMove {
            VStack(alignment: .leading, spacing: 2) {
                Text(next.toStanding ? "Stand in" : "Sit in").font(.caption).foregroundStyle(.secondary)
                if next.announceAt > entry.date {
                    Text(next.announceAt, style: .timer)
                        .font(.system(.title, design: .rounded).monospacedDigit().weight(.semibold))
                } else if next.isOverdue(now: entry.date) {
                    // The desk decides the exact moment, and a countdown frozen at "now" for
                    // a while reads as broken.
                    Text("soon").font(.system(.title, design: .rounded).weight(.semibold))
                } else {
                    Text("now").font(.system(.title, design: .rounded).weight(.semibold))
                }
            }
        } else {
            Text(snap.paused ? "Paused" : snap.isPresent ? "Cruise off" : "Away")
                .font(.system(.title3, design: .rounded)).foregroundStyle(.secondary)
        }
    }

    private func statBlock(_ title: String, _ value: String, trailing: Bool = false) -> some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.callout, design: .rounded).weight(.medium))
        }
    }
}

@main
struct DeskpilotWidgetBundle: WidgetBundle {
    var body: some Widget {
        DeskpilotWidget()
        if #available(macOS 26, *) {
            CruiseControlControl()
            ReconnectControl()
        }
    }
}

struct DeskpilotWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.kevinpatel.tempo.widget", provider: DeskpilotProvider()) { entry in
            DeskpilotWidgetView(entry: entry)
        }
        .configurationDisplayName("Deskpilot")
        .description("Your desk at a glance: posture, countdown, stands and time at desk.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
