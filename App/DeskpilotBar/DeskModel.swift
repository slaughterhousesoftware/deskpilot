import AppKit
import Foundation
import Observation
import WidgetKit
import DeskpilotKit

@MainActor
@Observable
final class DeskModel {
    private(set) var state = DeskState()
    private(set) var lastActionError: String?
    private(set) var todaySegments: [PostureSegment] = []
    private(set) var savedToday: TodayStats?
    private(set) var savedSnapshot: DeskSnapshot?
    private(set) var lastSyncedAt: Date?
    /// When the current connection attempt began, while one is under way.
    private(set) var connectingSince: Date?
    /// The hour the person's desk day usually starts (see `TypicalDayStart`), for where the
    /// menu's strip begins; nil until there are a few days of history.
    private(set) var typicalDayStartHour: Int?
    /// The hours the person is normally asleep, from their history; until read, the desk's.
    private(set) var nightWindow: NightWindow?
    private var typicalDayStartCheckedAt = Date.distantPast
    private var backend: RustBackendProcess?
    private var replayClock: Timer?
    private var backendFailed = false
    private var lastWidgetReload = Date.distantPast
    private var lastSnapshot: DeskSnapshot?
    private let directory: URL
    private let commandQueue: CommandQueue

    nonisolated static var dataDirectory: URL? {
        if let path = ProcessInfo.processInfo.environment["DESKPILOT_DATA_DIR"] { return URL(fileURLWithPath: path) }
        guard ProcessInfo.processInfo.environment["DESKPILOT_SIMULATE"] != nil else { return nil }
        return FileManager.default.temporaryDirectory.appendingPathComponent("tempo-simulated")
    }

    init() {
        directory = Self.dataDirectory ?? SnapshotStore().fileURL.deletingLastPathComponent()
        commandQueue = CommandQueue(directory: directory)
        savedSnapshot = SnapshotStore(directory: directory).read()
        // Dev only: `DESKPILOT_DEV_SEGMENTS=s360-390,S390-405,b405-420` (minutes after 4 AM today;
        // s sitting, S standing, b away) fills today's strip, to see it on the real menu's glass
        // without a desk.
        if let spec = ProcessInfo.processInfo.environment["DESKPILOT_DEV_SEGMENTS"],
           let dayStart = Calendar.current.date(bySettingHour: 4, minute: 0, second: 0, of: Date()) {
            todaySegments = spec.split(separator: ",").compactMap { item in
                guard let kind = item.first, let dash = item.firstIndex(of: "-"),
                      let from = Int(item[item.index(after: item.startIndex)..<dash]),
                      let to = Int(item[item.index(after: dash)...]) else { return nil }
                let state: PostureState = kind == "S" ? .standing : kind == "s" ? .sitting : .away
                return PostureSegment(start: dayStart.addingTimeInterval(Double(from) * 60),
                                      end: dayStart.addingTimeInterval(Double(to) * 60), state: state)
            }
        }
    }

    var today: TodayStats? { state.today ?? savedToday }

    var cruiseIsOn: Bool {
        if let settings = state.settings { return settings.cruiseEnabled && !settings.paused }
        return savedSnapshot.map { $0.cruise != nil && !$0.paused } ?? false
    }

    func start() {
        guard backend == nil else { return }
        // Read-only media capture from an explicitly supplied service frame. Never
        // start Bluetooth or a simulated writer against this copied history.
        if let path = ProcessInfo.processInfo.environment["DESKPILOT_DEV_FRAME"] {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               let frame = try? RustServiceFrame.decode(data) {
                receive(frame)
                state.updatedAt = Date()
                let clock = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.state.updatedAt = Date() }
                }
                RunLoop.main.add(clock, forMode: .common)
                replayClock = clock
                if let document = HistoryStore(directory: directory).read() {
                    let now = Date()
                    let start = DayRollup.dayStart(now: now, middleOfNightHour: document.middleOfNightHour)
                    todaySegments = PostureTimeline.segments(events: document.events, from: start, to: now,
                                                            standingThresholdInches: document.standingThresholdInches)
                }
            }
            return
        }
        backend = RustBackendProcess(directory: directory, receive: { [weak self] frame in
            self?.receive(frame)
        }, failed: { [weak self] message in
            guard let self else { return }
            self.backendFailed = true
            self.state.status = .disconnected
            self.state.isMoving = false
            self.state.today?.nextMove = nil
            self.state.lastError = message
            self.lastActionError = message
        })
        backend?.start()
    }

    func stop() { replayClock?.invalidate(); backend?.stop() }

    /// Re-reads the history for the usual start of the day, at most once an hour and off the
    /// main thread (the file holds months of events).
    private func refreshTypicalDayStart() {
        let now = Date()
        guard now.timeIntervalSince(typicalDayStartCheckedAt) > 3600 else { return }
        typicalDayStartCheckedAt = now
        let store = HistoryStore(directory: directory)
        Task.detached(priority: .utility) {
            let document = store.read()
            let hour = document.flatMap { TypicalDayStart.hour(document: $0, now: now) }
            let night = document.map { NightWindow.usual(document: $0, now: now) }
            await MainActor.run { [weak self] in
                self?.typicalDayStartHour = hour
                self?.nightWindow = night
            }
        }
    }

    private func receive(_ frame: RustServiceFrame) {
        state = frame.state.deskState
        timeConnection()
        if state.status == .connected, backendFailed { lastActionError = nil; backendFailed = false }
        // Stray visits before the day's first real stretch aren't the start of the day.
        let night = nightWindow ?? .around(middleOfNightHour: state.settings?.middleOfNightHour ?? 4)
        todaySegments = DeskDay.withoutStrays(frame.todaySegments, openEnded: true, night: night)
        refreshTypicalDayStart()
        savedToday = frame.savedToday
        savedSnapshot = frame.snapshot
        lastSyncedAt = frame.lastSyncedAt
        let snapshot = frame.snapshot
        let significant = lastSnapshot.map {
            $0.connected != snapshot.connected || $0.isPresent != snapshot.isPresent
                || $0.standsToday != snapshot.standsToday || $0.nextMove != snapshot.nextMove
                || $0.isStanding != snapshot.isStanding || $0.paused != snapshot.paused
        } ?? true
        lastSnapshot = snapshot
        if significant || Date().timeIntervalSince(lastWidgetReload) > 30 {
            lastWidgetReload = Date()
            WidgetCenter.shared.reloadAllTimelines()
            if #available(macOS 26, *) { ControlCenter.shared.reloadAllControls() }
        }
    }

    // MARK: - Connection timing

    private static let connectTimesKey = "connectSeconds"

    /// How long the desk usually takes to connect: the median of the last ten connections,
    /// once there have been three.
    var typicalConnectSeconds: TimeInterval? {
        let times = (UserDefaults.standard.array(forKey: Self.connectTimesKey) as? [Double] ?? []).sorted()
        guard times.count >= 3 else { return nil }
        return times[times.count / 2]
    }

    /// Starts the clock when an attempt begins and, when it connects, keeps how long it took.
    private func timeConnection() {
        switch state.status {
        case .connecting:
            if connectingSince == nil { connectingSince = Date() }
        case .connected:
            if let since = connectingSince {
                let seconds = Date().timeIntervalSince(since)
                // A connection left hanging (the desk out of reach) says nothing about how long
                // one takes.
                if seconds < 120 {
                    var times = UserDefaults.standard.array(forKey: Self.connectTimesKey) as? [Double] ?? []
                    times.append(seconds)
                    UserDefaults.standard.set(Array(times.suffix(10)), forKey: Self.connectTimesKey)
                }
            }
            connectingSince = nil
        default:
            connectingSince = nil
        }
    }

    func reconnect() { Task { _ = await send(.reconnect) } }
    func captureSittingPreset() async -> Bool { await send(.captureSittingPreset) }
    func captureStandingPreset() async -> Bool { await send(.captureStandingPreset) }
    func setCruise(_ slot: CruiseSlot?) async -> Bool { await send(.setCruise(slot)) }
    func setPaused(_ paused: Bool) async -> Bool { await send(.setPaused(paused)) }

    private func send(_ command: DeskCommand) async -> Bool {
        guard let result = await commandQueue.send(command, pollEvery: 0.1) else {
            lastActionError = "The Deskpilot backend did not answer. Please reconnect."
            return false
        }
        lastActionError = result.success ? nil : (result.message ?? "The desk could not apply this change.")
        return result.success
    }
}
