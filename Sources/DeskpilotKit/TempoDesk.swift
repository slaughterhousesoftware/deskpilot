import Foundation
import os

private let log = Logger(subsystem: "com.kevinpatel.tempo", category: "desk")

public enum ConnectionStatus: Equatable, Sendable, Codable {
    case disconnected, connecting, connected, bluetoothOff, unauthorized
}

public struct DeskSettings: Equatable, Sendable, Codable {
    public var firmware: String
    public var userIndex: Int
    public var flags: UInt32
    public var activeCruiseSlot: Int
    public var cruise: CruiseSlot?
    public var middleOfNightHour: Int
    public var standingHeightTenths: Int
    public var sittingHeightTenths: Int
    public var customHeightOneTenths: Int
    public var customHeightTwoTenths: Int
    /// The 20-byte name fields of the user block, read once per connection by the backend.
    public var userName: String?
    public var presetNameOne: String?
    public var presetNameTwo: String?

    public var paused: Bool { UserFlags(rawValue: flags).contains(.paused) }
    public var pulseOnly: Bool { UserFlags(rawValue: flags).contains(.pulseOnly) }
    public var cruiseEnabled: Bool { activeCruiseSlot != 0 && cruise != nil }
}

public struct DeskState: Equatable, Sendable {
    public var status: ConnectionStatus = .disconnected
    /// Visible attempts exhausted; keep checking without animating the menu bar.
    public var reconnectingInBackground = false
    public var heightTenths: Int?
    public var isMoving = false
    /// Where the desk is going to stop, while it moves or coasts (the backend's coast model).
    public var predictedHeightTenths: Int?
    public var settings: DeskSettings?
    public var today: TodayStats?
    public var lastError: String?
    public var updatedAt = Date.distantPast
    /// Bumped by `recomputeToday()` whenever the merged history event count changes - a cheap
    /// signal the app uses to decide whether `historyDocument()` is worth re-fetching and
    /// writing to the App Group, without diffing the (potentially large) event list itself.
    public var historyRevision = 0

    public init() {}
}

/// Owns one transport, keeps the desk model current, and publishes `DeskState`.
public actor TempoDesk {
    public static let burstChunksPerRequest = 5
    /// Seconds from reading the desk's COUNTDOWN entry to the motor starting. With the log
    /// read every second: 13.2, ~14, ~14.5, ~14.5 and ~14.7 over five cycles on 2026-09-08/09,
    /// and 14.3 on 2026-09-11 21:56 (the motor had already moved 1.1 in by the first moving
    /// sample) - the desk's 15 s countdown less the read latency. The user's eye says the
    /// motor starts a few tenths before the status word shows it, and at 14.5 the timer still
    /// read 0:01 as the desk moved; the last minute is now read every 0.3 s, so the entry is
    /// caught within ~0.15 s of being written, and 14.1 puts the zero on the motor. The
    /// "countdown to motor" notice line measures every cycle for tuning.
    public static let countdownEntryToMotorSeconds: TimeInterval = 14.1
    /// How long past the announced motor time the announcement is still shown (as "now")
    /// before it is treated as waved off and the interval estimate takes back over.
    public static let announcementGraceSeconds: TimeInterval = 15
    private static let isoFormatter = ISO8601DateFormatter()

    private let transport: DeskTransport
    private let now: @Sendable () -> Date
    private let pollInterval: TimeInterval
    /// Status poll cadence while the desk is actually moving - faster than `pollInterval` so
    /// the live height readout and the moving indicator update smoothly instead of in
    /// ~1 s jumps. History polling cadence is unaffected.
    private let movingPollInterval: TimeInterval
    private let historyPollInterval: TimeInterval
    /// Cadence for `pollDiagnostics()` - extra reads (flags, active cruise slot, the raw
    /// countdown-and-pulse register) kept off the hot per-second path since they exist only
    /// to learn the desk's own timer rule from logs and to catch the desk's own flags
    /// changing underneath the app.
    private let flagsPollInterval: TimeInterval
    /// How long a status sample's height must go unchanged (`lastHeightChangeAt`) before it's
    /// trusted as final, both for polling cadence (`pollUntilDisconnect`) and for refusing a
    /// preset capture (`capturePreset`). Injectable so tests don't have to real-sleep a full
    /// second to exercise either.
    private let settleGrace: TimeInterval
    private let initialBackoff: TimeInterval
    private let backgroundRetryInterval: TimeInterval
    private let foregroundAttemptLimit = 3

    private var state = DeskState()
    private var continuations: [UUID: AsyncStream<DeskState>.Continuation] = [:]
    private var runTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var connected = false

    // History model.
    // The desk timestamps history entries as "minutes since power-on mod 256", so turning
    // them into dates needs one anchor pairing a reading of register 32 with the wall
    // clock. The anchor is deliberately *not* refreshed on every poll: re-anchoring with
    // the same minute value but a later `Date` slides every event date forward, which made
    // the popover's countdown freeze for a minute and then jump. It is set on connect, on
    // a resync/power cycle, and when new history bytes arrive - the only moments where the
    // derived dates should legitimately move.
    private var rawEntries: [RawHistoryEntry] = []
    private var historyBytesRead = 0
    private var anchorMinutes = 0
    private var anchorDate = Date.distantPast
    /// The most recently read `minutesSincePowerOn`, refreshed on every `pollHistory` call
    /// (whether or not new bytes arrived). `dateEntries` assumes every entry is at or before
    /// its `minutesSincePowerOn` reference, walking backward from there - so dating against
    /// the *pinned* `anchorMinutes` misdates by a full 256-minute wrap any entry stamped after
    /// the anchor was taken (e.g. a countdown flushed a few minutes into the connection).
    /// `recomputeToday` instead dates against this live counter, projected through the fixed
    /// anchor so already-dated entries don't jitter as it advances.
    private var latestMinutes = 0
    /// The previous `pollHistory` reading of register 32 and when it was taken, so the first
    /// time the counter ticks over between two polls the anchor can be phase-locked: the
    /// tick happened between those two reads (polls are `historyPollInterval` apart, so
    /// within a few seconds), which pins where the desk's minute boundaries fall. Entries
    /// are then dated to the middle of their minute (error within 30 s) instead of to
    /// wherever in the minute the connection-time read happened to land (error up to 60 s,
    /// and different on every restart). Locked once per anchor: re-locking every minute
    /// would jitter every derived date by the poll spacing each time.
    private var lastMinuteRead: (minutes: Int, at: Date)?
    private var phaseLocked = false

    // Live move detection.
    // The desk writes the history log *late*: an automatic stand at 15:46 was still not
    // readable through the write pointer at 15:54 (docs/protocol.md, "Write latency"). The
    // status register is live, though, so posture changes are detected from it and fed into
    // the rollup as synthetic `.move` events with `byteOffset == -1`, which keeps the
    // countdown and the stands counter honest until the log catches up. When the log finally
    // arrives, `mergeObservedMoves` drops the observed duplicate.
    private var observedMoves: [HistoryEvent] = []
    /// Where observed moves survive a restart of the app (see `restoreObservedMoves`).
    private let moveStore: ObservedMoveStore?
    private var lastStatus: StatusWord?
    private var lastKnownPosture: Bool?
    /// Wall clock (not `now()` - see `pollUntilDisconnect`) of the most recent status sample
    /// whose `heightTenths` differed from the sample before it. Keeps `pollUntilDisconnect`
    /// polling at `movingPollInterval` for a beat after the motion bit clears: the desk can
    /// clear it while still travelling (observed live: last moving sample 40.5 in, settled at
    /// 41.1 in about a second later), so "not moving" alone isn't proof the height is final.
    private var lastHeightChangeAt = Date.distantPast
    /// When the current stretch of motion began (the motion bit rising from rest): the desk
    /// times its rhythm from when the motor starts, not from when it settles ~8 s later, so
    /// an observed move is dated here (see `recordObservedMove`).
    private var motionStartedAt: Date?
    /// The desk's most recent COUNTDOWN entry, dated by when it was *read* - the desk writes
    /// it when it starts beeping and the log is read every second around a predicted move,
    /// so this is the beep's start to within a second or two. Cleared by the move it announces.
    private var lastCountdownSeen: (at: Date, toStanding: Bool)?
    /// Last status word logged for having something in its upper bits (see `pollStatus`).
    private var lastRawStatusFlagged: UInt32 = 0
    /// Last values seen by `pollProbe()`, so it logs changes only.
    private var probeValues: [UInt32: UInt32] = [:]
    /// The merged, dated event list `recomputeToday()` last computed - the same list
    /// `historyDocument()` hands to the dashboard app. Kept so `historyDocument()` doesn't
    /// have to recompute the merge (and so `recomputeToday()` can cheaply detect a count
    /// change to bump `DeskState.historyRevision`).
    private var mergedEvents: [HistoryEvent] = []
    /// A settle or jump was just detected but not yet trusted: the height it implies the
    /// desk ended up at hasn't been confirmed by a second, matching sample yet. See
    /// `noteStatus`.
    private struct PendingSettle {
        var height: Int
        let settled: Bool
        let jumped: Bool
        let previousHeight: Int
    }
    private var pendingSettle: PendingSettle?

    /// The log's minute stamps are coarse (whole minutes) and late, so a logged move counts
    /// as "the same move" as an observed one if it lands anywhere in this window around it.
    static let observedMoveDedupeWindow: TimeInterval = 180

    public init(transport: DeskTransport,
                now: @escaping @Sendable () -> Date = { Date() },
                pollInterval: TimeInterval = 1,
                movingPollInterval: TimeInterval = 0.25,
                historyPollInterval: TimeInterval = 5,
                flagsPollInterval: TimeInterval = 30,
                settleGrace: TimeInterval = 1.0,
                initialBackoff: TimeInterval = 2,
                backgroundRetryInterval: TimeInterval = 60,
                moveStore: ObservedMoveStore? = nil) {
        self.transport = transport
        self.moveStore = moveStore
        self.now = now
        self.pollInterval = pollInterval
        self.movingPollInterval = movingPollInterval
        self.historyPollInterval = historyPollInterval
        self.flagsPollInterval = flagsPollInterval
        self.settleGrace = settleGrace
        self.initialBackoff = initialBackoff
        self.backgroundRetryInterval = backgroundRetryInterval
    }

    // MARK: State publishing

    public var currentState: DeskState { state }

    /// Number of history entries decoded so far, including NOPs. Internal: tests use it to
    /// wait for the log to be ingested, which no published state reflects directly.
    var decodedHistoryEntryCount: Int { rawEntries.count }

    public func states() -> AsyncStream<DeskState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<DeskState>.makeStream(bufferingPolicy: .bufferingNewest(8))
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        continuation.yield(state)
        return stream
    }

    private func removeContinuation(_ id: UUID) { continuations[id] = nil }

    private func publish(_ mutate: (inout DeskState) -> Void) {
        mutate(&state)
        state.updatedAt = now()
        for c in continuations.values { c.yield(state) }
    }

    // MARK: Lifecycle

    public func start() {
        guard runTask == nil else { return }
        eventTask = Task { [transport] in
            for await event in transport.events { self.handle(event) }
        }
        runTask = Task { await self.runLoop() }
    }

    public func stop() async {
        // Cancellation is cooperative: cancel both loop tasks, then actually wait for them
        // to finish before tearing anything else down. Otherwise a caller doing
        // `await stop(); await start()` could briefly run the old loop and the new one
        // together, interleaving mutations of `historyBytesRead`/`rawEntries`/`state`.
        let tasksToAwait = [runTask, eventTask].compactMap { $0 }
        runTask?.cancel()
        eventTask?.cancel()
        for task in tasksToAwait { await task.value }
        runTask = nil
        eventTask = nil
        await transport.disconnect()
        connected = false
        publish { $0.status = .disconnected; $0.reconnectingInBackground = false }
    }

    private func handle(_ event: ConnectionEvent) {
        log.info("event=\(String(describing: event), privacy: .public)")
        switch event {
        case .connecting:
            if !state.reconnectingInBackground { publish { $0.status = .connecting } }
        case .connected: connected = true; publish { $0.status = .connected; $0.lastError = nil }
        case .disconnected(let reason):
            connected = false
            publish { $0.status = .disconnected; $0.lastError = reason; $0.isMoving = false }
        case .bluetoothOff: connected = false; publish { $0.status = .bluetoothOff }
        case .unauthorized: connected = false; publish { $0.status = .unauthorized }
        }
    }

    private func runLoop() async {
        var backoff = initialBackoff
        var failedAttempts = 0
        publish { $0.reconnectingInBackground = false }
        while !Task.isCancelled {
            var syncedThisAttempt = false
            do {
                if !state.reconnectingInBackground { publish { $0.status = .connecting } }
                try await transport.connect()
                if Task.isCancelled { return }
                connected = true
                publish { $0.status = .connected; $0.lastError = nil }
                try await afterConnect()
                syncedThisAttempt = true
                failedAttempts = 0
                backoff = initialBackoff
                publish { $0.reconnectingInBackground = false }
                if Task.isCancelled { return }
                try await pollUntilDisconnect()
            } catch is CancellationError {
                return
            } catch let error as DeskError where error == .bluetoothOff {
                log.info("run loop error=\(String(describing: error), privacy: .public)")
                connected = false
                publish { $0.status = .bluetoothOff; $0.lastError = "Bluetooth is turned off" }
            } catch let error as DeskError where error == .unauthorized {
                log.info("run loop error=\(String(describing: error), privacy: .public)")
                connected = false
                publish { $0.status = .unauthorized; $0.lastError = "Bluetooth access was denied" }
            } catch {
                log.info("run loop error=\(String(describing: error), privacy: .public)")
                connected = false
                // Written out for the menu (`DeskError.errorDescription`), never the enum's
                // debug text.
                publish { $0.status = .disconnected; $0.lastError = error.localizedDescription }
            }
            if Task.isCancelled { return }
            // Losing an established connection is not itself a failed reconnect attempt.
            if !syncedThisAttempt { failedAttempts += 1 }
            let quiet = failedAttempts >= foregroundAttemptLimit
            publish { $0.reconnectingInBackground = quiet }
            let delay = quiet ? backgroundRetryInterval : backoff
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            backoff = min(backoff * 2, backgroundRetryInterval)
        }
    }

    private func afterConnect() async throws {
        log.info("connected; syncing")
        try await refreshSettings()
        try await refreshMinutes()
        try await resyncHistory()
        restoreObservedMoves()
        try await pollStatus()
        recomputeToday()
    }

    /// Brings back the moves observed live before the last restart, so the countdown keeps
    /// its second-accurate anchor instead of falling back to the log's minute stamps. Runs
    /// after `resyncHistory` (whose `forgetHistory` clears the in-memory list). Only the last
    /// day is kept, matching `recordObservedMove`.
    private func restoreObservedMoves() {
        guard let moveStore else { return }
        let cutoff = now().addingTimeInterval(-86_400)
        let restored = moveStore.load().filter { $0.date >= cutoff }
        guard !restored.isEmpty else { return }
        observedMoves = restored
        log.info("restored observed moves count=\(restored.count, privacy: .public)")
    }

    private func pollUntilDisconnect() async throws {
        // Poll cadence is throttled against the real wall clock, not the injected `now()`.
        // `now()` drives business timestamps (day rollup, "today" math) and may be a fixed
        // clock in tests, so it must never gate how often we actually poll the transport.
        var lastHistoryPoll = Date.distantPast
        var lastFlagsPoll = Date.distantPast
        while connected && !Task.isCancelled {
            try await pollStatus()
            let wallClock = Date()
            let armed = currentHistoryPollInterval() < historyPollInterval
            if wallClock.timeIntervalSince(lastHistoryPoll) >= currentHistoryPollInterval() {
                lastHistoryPoll = wallClock
                try await pollHistory()
                if armed { try? await pollProbe() }
            }
            if wallClock.timeIntervalSince(lastFlagsPoll) >= flagsPollInterval {
                lastFlagsPoll = wallClock
                // Purely diagnostic - a read failure here (even after retryOnce) must not
                // tear down an otherwise-healthy connection the way it would for
                // pollStatus()/pollHistory().
                try? await pollDiagnostics()
            }
            // Unconditional, every iteration (not just when pollHistory() above just ran) -
            // so a freshly-ingested COUNTDOWN entry (see DayRollup.compute's countdown
            // anchoring) is reflected in `nextMove` the moment it's decoded, within the same
            // iteration that ingested it, not up to a whole `historyPollInterval` (<= 5 s)
            // later.
            recomputeToday()
            // Stay fast until the height has actually stopped changing, not just until the
            // motion bit clears - see `lastHeightChangeAt`.
            let stillSettling = Date().timeIntervalSince(lastHeightChangeAt) < settleGrace
            let interval = (lastStatus?.isMoving ?? false) || stillSettling ? movingPollInterval : pollInterval
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        if !connected { throw DeskError.notConnected }
    }

    /// The desk writes its COUNTDOWN entry when it starts beeping, ~15 s before it moves
    /// (docs/protocol.md, "Countdown accuracy"), so around the predicted move the log is
    /// read every second instead of every `historyPollInterval` - that entry is the one
    /// live signal of the real countdown, and a 5 s read cadence would eat a third of it.
    private func currentHistoryPollInterval() -> TimeInterval {
        guard let next = state.today?.nextMove, !state.isMoving else { return historyPollInterval }
        let untilMove = next.at.timeIntervalSince(now())
        // From ten minutes ahead of the estimate until the move actually happens: the
        // desk holds its timer for absences it never logs, so an overdue estimate stays
        // overdue for as long as it likes, while dating holds `absenceLogLagSeconds` before
        // the logged absence can put the estimate up to ~8 min after the desk's beep (the
        // 2026-09-08..25 fit) - and the COUNTDOWN entry has to be read within a
        // second of being written for the timer to be right (2026-09-11: read 3 s late at
        // the slow interval, and the timer ran 3 s behind the desk).
        // Inside the last minute (and for as long as it runs overdue) the read is every
        // 0.3 s: a 1 s cadence put the timer up to a second behind the beep (2026-09-11
        // 21:56, "about 1 second behind").
        if untilMove < 60 { return min(0.3, historyPollInterval) }
        return untilMove < 10 * 60 ? min(1, historyPollInterval) : historyPollInterval
    }

    // MARK: Reads

    /// Retries once after 250 ms on the transient GATT failures (spec: "GATT errors on a
    /// read/write: retried once after 250 ms, then surfaced"). Errors that describe a
    /// steady state - not connected, Bluetooth off/denied, a refused write - are surfaced
    /// immediately, because retrying them just delays the same failure.
    private func retryOnce<T>(_ op: () async throws -> T) async throws -> T {
        do {
            return try await op()
        } catch let error as DeskError where Self.isTransient(error) {
            try await Task.sleep(nanoseconds: 250_000_000)
            return try await op()
        }
    }

    private static func isTransient(_ error: DeskError) -> Bool {
        switch error {
        case .timeout, .gatt, .burstIncomplete: return true
        case .notConnected, .forbiddenAddress, .invalidValue, .bluetoothOff, .unauthorized,
             .bluetoothUnavailable: return false
        }
    }

    private func read(_ address: UInt32) async throws -> UInt32 {
        try await retryOnce { try await transport.readRegister(address) }
    }

    private func pollStatus() async throws {
        let raw = try await read(Register.status)
        let word = StatusWord(raw: raw)
        // Bits 16..30 have only ever been seen as zero while idle; if the desk flags its
        // countdown or pulse anywhere in this register, this is where it would show.
        if raw & 0x7FFF_0000 != 0, raw != lastRawStatusFlagged {
            lastRawStatusFlagged = raw
            log.notice("status raw=0x\(String(raw, radix: 16), privacy: .public)")
        }
        // Raw samples around a move (including the settling one right after motion stops,
        // via the pre-update `lastStatus`), regardless of plausibility - captured before
        // `noteStatus` overwrites `lastStatus` - so a real move can be replayed from the
        // logs: `log stream --level info --predicate 'subsystem == "com.kevinpatel.tempo"'`.
        // Every sample where anything changed, persisted (notice level survives in the log
        // store; info does not) - the desk's pre-move pulse is a height blip of a few tenths
        // with the desk otherwise at rest, and learning its timing needs samples at rest too.
        if word.isMoving || lastStatus?.isMoving == true || word.heightTenths != lastStatus?.heightTenths {
            log.notice("status sample height=\(word.heightTenths, privacy: .public) moving=\(word.isMoving, privacy: .public)")
        }
        // An implausible reading is dropped before it can reach anything downstream - the
        // published `heightTenths`, the live-height `isStanding` override in
        // `recomputeToday`, and the widget snapshot all keep the last plausible reading.
        guard noteStatus(word) else { return }
        publish { $0.heightTenths = word.heightTenths; $0.isMoving = word.isMoving }
    }

    /// Turns status-register transitions into live `.move` events. Called once per status
    /// poll, before the state is published. Returns `false` for an implausible reading, which
    /// the caller must not publish.
    ///
    /// A move is "done" when the motion bit falls from 1 to 0. As a defence against a move
    /// that starts and finishes between two polls (the motion bit never seen), a height jump
    /// of at least 2 inches between consecutive stationary readings counts too. Neither is
    /// trusted immediately, though: the desk can clear the motion bit before it has actually
    /// stopped travelling, so a detected settle/jump only becomes a recorded move once a
    /// *second* sample confirms the same height (`pendingSettle`) - and posture is classified
    /// from that confirmed, settled height, not the one that triggered the detection. Only a
    /// *change* of posture is recorded - the desk nudging itself within one posture is not a
    /// move.
    @discardableResult
    private func noteStatus(_ word: StatusWord) -> Bool {
        guard let settings = state.settings,
              settings.sittingHeightTenths > 0,
              settings.standingHeightTenths > settings.sittingHeightTenths else {
            lastStatus = word
            return true
        }
        // A garbled read (a dropped/corrupted GATT notification decodes to whatever bytes
        // happened to be in the packet) can land far outside the desk's actual travel. Letting
        // it through would corrupt `lastStatus` and make the *next* real reading look like a
        // sudden settle/jump, recording a move nothing in the log will ever dedupe. It is
        // dropped before `lastStatus` is touched, so the next real reading is compared against
        // the last real one, and the caller must not publish it either - see `pollStatus`.
        guard word.heightTenths >= settings.sittingHeightTenths - 100,
              word.heightTenths <= settings.standingHeightTenths + 100 else {
            log.info("ignoring implausible height \(word.heightTenths, privacy: .public)")
            return false
        }
        defer { lastStatus = word }
        let midpoint = (settings.sittingHeightTenths + settings.standingHeightTenths) / 2
        let posture = word.heightTenths >= midpoint
        // The first reading of a connection only establishes where the desk is; it is not a
        // move. The live height also wins over whatever the (late) log last said.
        guard let previous = lastStatus else { lastKnownPosture = posture; return true }
        if word.heightTenths != previous.heightTenths { lastHeightChangeAt = Date() }
        // The motion bit, not the height: the desk's pre-move pulse is a one-tenth height
        // blip with the motion bit clear, about 7 s after the beep starts (2026-09-08,
        // 17:32:39.6 after a 17:32:32.9 COUNTDOWN read), and dating the move there would
        // put the anchor ~6 s ahead of the motor.
        if pendingSettle == nil, motionStartedAt == nil, word.isMoving, !previous.isMoving {
            motionStartedAt = now()
            // How the desk's countdown actually ran, for tuning `countdownEntryToMotorSeconds`:
            // the motor started before this sample by however far the height has already
            // moved (the desk travels ~1.5 in/s, 15 tenths per second). Only for an entry
            // read this cycle - a dismissed one lingers until the next observed move, and
            // measured against it this line read "1206 s" on 2026-09-12.
            if let seen = lastCountdownSeen, now().timeIntervalSince(seen.at) < 60 {
                let travelled = abs(Int(word.heightTenths) - Int(previous.heightTenths))
                let started = now().addingTimeInterval(-Double(travelled) / 15)
                log.notice("countdown to motor \(started.timeIntervalSince(seen.at), format: .fixed(precision: 2)) s after the entry was read (sample \(self.now().timeIntervalSince(seen.at), format: .fixed(precision: 2)) s, travelled \(travelled) tenths)")
            }
        }
        guard let known = lastKnownPosture else { lastKnownPosture = posture; return true }

        if var pending = pendingSettle {
            // Confirmed: two consecutive samples at the same height (the motion bit is not
            // trusted either way here - the desk clearing it early, mid-travel, is exactly
            // the bug this is guarding against, but a stray moving=true blip on an otherwise
            // matching sample shouldn't discard a real confirmation). Classify posture from
            // *this* height, not the one that triggered the detection.
            if word.heightTenths == pending.height {
                let settledPosture = pending.height >= midpoint
                if lastKnownPosture != settledPosture {
                    recordObservedMove(toStanding: settledPosture, settledHeight: pending.height,
                                       previousHeight: pending.previousHeight,
                                       settled: pending.settled, jumped: pending.jumped)
                }
                pendingSettle = nil
                motionStartedAt = nil
            } else {
                // Still changing - keep waiting, now against this newer height.
                pending.height = word.heightTenths
                pendingSettle = pending
            }
            return true
        }

        let settled = previous.isMoving && !word.isMoving
        let jumped = !previous.isMoving && !word.isMoving
            && abs(word.heightTenths - previous.heightTenths) >= 20
        guard settled || jumped, known != posture else { return true }
        pendingSettle = PendingSettle(height: word.heightTenths, settled: settled, jumped: jumped,
                                      previousHeight: previous.heightTenths)
        return true
    }

    private func recordObservedMove(toStanding: Bool, settledHeight: Int, previousHeight: Int,
                                    settled: Bool, jumped: Bool) {
        // Dated at the motor start when one was seen recently - that is what the desk's
        // own timer counts from - else at the settle.
        let settledAt = now()
        let at = motionStartedAt.flatMap { settledAt.timeIntervalSince($0) < 60 ? $0 : nil } ?? settledAt
        lastCountdownSeen = nil
        observedMoves.removeAll { $0.date < at.addingTimeInterval(-86_400) }
        observedMoves.append(HistoryEvent(byteOffset: -1, date: at, kind: .move(toStanding: toStanding)))
        moveStore?.save(observedMoves)
        log.notice("""
            observed move to=\(toStanding ? "standing" : "sitting", privacy: .public) \
            height=\(settledHeight, privacy: .public) prev=\(previousHeight, privacy: .public) \
            settled=\(settled, privacy: .public) jumped=\(jumped, privacy: .public)
            """)
        lastKnownPosture = toStanding
    }

    /// Merges the log's events with the live-detected moves. When an observed move dedupes
    /// against a logged move (same direction, within the window), the *logged* event
    /// survives - keeping its `byteOffset` (there's nothing else to reconcile the log
    /// against) and its `kind` - but its `date` is replaced with the observed move's, which
    /// is precise to the second; the log only stamps whole minutes, coarse enough on its own
    /// to throw the countdown off by up to a minute (observed live: predicted stand
    /// 19:33:31 vs. actual 19:34:50 - the desk's own ~21 min interval measured from the
    /// logged move's minute-rounded timestamp instead of the true, second-precise one).
    /// Pure so it can be tested on its own.
    static func mergeObservedMoves(logged: [HistoryEvent], observed: [HistoryEvent]) -> [HistoryEvent] {
        guard !observed.isEmpty else { return logged }
        var merged = logged
        var claimed = Set<Int>()
        var kept: [HistoryEvent] = []
        for candidate in observed {
            guard case .move(let toStanding) = candidate.kind else {
                kept.append(candidate)
                continue
            }
            let match = merged.indices.first { index in
                guard !claimed.contains(index), case .move(let loggedToStanding) = merged[index].kind else { return false }
                return loggedToStanding == toStanding
                    && abs(merged[index].date.timeIntervalSince(candidate.date)) <= observedMoveDedupeWindow
            }
            if let match {
                claimed.insert(match)
                let loggedMove = merged[match]
                merged[match] = HistoryEvent(byteOffset: loggedMove.byteOffset, date: candidate.date, kind: loggedMove.kind)
            } else {
                kept.append(candidate)
            }
        }
        // Sort stably (Swift's sort is not): events sharing a timestamp - the log stamps a
        // whole minute of entries identically - must keep the order they were decoded in,
        // and an observed move that wasn't matched to a logged one must land after the
        // logged events of the same instant.
        return (merged + kept).enumerated()
            .sorted { a, b in
                a.element.date == b.element.date ? a.offset < b.offset : a.element.date < b.element.date
            }
            .map(\.element)
    }

    /// Re-anchors the history clock to the wall clock. See `anchorMinutes`.
    private func refreshMinutes() async throws {
        let minutes = Int(try await read(Register.minutesSincePowerOn))
        anchorMinutes = minutes
        latestMinutes = minutes
        anchorDate = now()
        lastMinuteRead = (minutes, anchorDate)
        phaseLocked = false
        log.info("anchor minutes=\(self.anchorMinutes, privacy: .public) date=\(Self.isoFormatter.string(from: self.anchorDate), privacy: .public)")
    }

    public func refreshSettings() async throws {
        let userIndex = Int(try await read(Register.currentUser)) == 0 ? 0 : 1
        let base = Register.userBase(userIndex)
        func user(_ off: UInt32) async throws -> UInt32 { try await read(base + off) }
        let flags = try await user(Register.UserOffset.flags)
        let slot = Int(try await user(Register.UserOffset.activeCruiseSlot))
        var cruise: CruiseSlot?
        if slot > 0 {
            cruise = CruiseSlot(raw: try await read(Register.cruiseSlotAddress(user: userIndex, slot: slot)))
        }
        let settings = DeskSettings(
            firmware: FirmwareVersion(raw: try await read(Register.firmwareApplication)).description,
            userIndex: userIndex,
            flags: flags,
            activeCruiseSlot: slot,
            cruise: cruise,
            middleOfNightHour: Int(try await user(Register.UserOffset.middleOfNightHour)),
            standingHeightTenths: Int(try await user(Register.UserOffset.standingHeight)),
            sittingHeightTenths: Int(try await user(Register.UserOffset.sittingHeight)),
            customHeightOneTenths: Int(try await user(Register.UserOffset.customHeightOne)),
            customHeightTwoTenths: Int(try await user(Register.UserOffset.customHeightTwo))
        )
        publish { $0.settings = settings }
    }

    /// Extra reads beyond the hot per-second path, at `flagsPollInterval`: flags, the active
    /// cruise slot, and the raw countdown-and-pulse register, logged so a real desk's timing
    /// rule can eventually be reverse-engineered from `log stream --level info --predicate
    /// 'subsystem == "com.kevinpatel.tempo"'`. Also catches flags or the active cruise slot
    /// changing underneath the app - e.g. pause toggled, or a preset cruise slot selected,
    /// from the physical handset - so `refreshSettings()` picks it up and the UI reflects it
    /// without the user having to touch the app first. Purely diagnostic: the caller
    /// (`pollUntilDisconnect`) swallows any error from this rather than tearing down the
    /// connection over it.
    private func pollDiagnostics() async throws {
        guard let settings = state.settings else { return }
        let base = Register.userBase(settings.userIndex)
        let flags = try await read(base + Register.UserOffset.flags)
        let slot = try await read(base + Register.UserOffset.activeCruiseSlot)
        let cdp = try await read(base + Register.UserOffset.countdownAndPulse)
        log.info("""
            desk regs flags=0x\(String(flags, radix: 16), privacy: .public) \
            slot=\(slot, privacy: .public) cdp=0x\(String(cdp, radix: 16), privacy: .public)
            """)
        if flags != settings.flags || Int(slot) != settings.activeCruiseSlot {
            try await refreshSettings()
        }
    }

    /// Experiment, run once a second in the window around a predicted move: reads the
    /// registers whose meaning is still unknown and logs any that change, looking for a
    /// live countdown the desk might keep somewhere readable. Purely diagnostic.
    private func pollProbe() async throws {
        guard let settings = state.settings else { return }
        let base = Register.userBase(settings.userIndex)
        let addresses: [UInt32] = [48, 72, 76, 228, base + 32, base + 36, base + 40]
        var changes: [String] = []
        for address in addresses {
            let value = try await read(address)
            if probeValues[address] != value {
                changes.append("\(address)=0x\(String(value, radix: 16))")
                probeValues[address] = value
            }
        }
        if !changes.isEmpty {
            log.notice("probe \(changes.joined(separator: " "), privacy: .public)")
        }
    }

    private func resyncHistory() async throws {
        forgetHistory()
        try await pollHistory()
    }

    /// Drops everything derived from the current boot session's log, including the live-move
    /// bookkeeping: after a reconnect or a power cycle we no longer know what the desk did
    /// while we were away, and the next status poll re-establishes the posture.
    private func forgetHistory() {
        rawEntries = []
        historyBytesRead = 0
        observedMoves = []
        lastStatus = nil
        lastKnownPosture = nil
        pendingSettle = nil
        motionStartedAt = nil
        lastCountdownSeen = nil
    }

    /// Renders a decoded entry as `t<minuteByte>:<kind>` for diagnostics, e.g. `t33:countdown(down)`.
    private static func describe(_ entry: RawHistoryEntry) -> String {
        "t\(entry.minuteByte):\(describe(entry.kind))"
    }

    private static func describe(_ kind: HistoryEventKind) -> String {
        switch kind {
        case .presence(let present): return "presence(\(present ? "present" : "absent"))"
        case .countdown(let toStanding): return "countdown(\(toStanding ? "up" : "down"))"
        case .move(let toStanding): return "move(\(toStanding ? "up" : "down"))"
        case .heightChange(let inches): return "height(\(inches))"
        case .userChange(let user): return "user(\(user))"
        case .nop(let raw): return "nop(\(raw))"
        }
    }

    /// Number of `.move` events in a timeline, for diagnostics.
    private static func moveCount(_ events: [HistoryEvent]) -> Int {
        events.reduce(0) { count, event in
            if case .move = event.kind { return count + 1 }
            return count
        }
    }

    /// `nil` prints as "nil"; otherwise the wrapped value's own description.
    private static func desc<T>(_ value: T?) -> String { value.map { "\($0)" } ?? "nil" }

    private func pollHistory() async throws {
        let writePointer = Int(try await read(Register.historyWritePointer))
        // Read the minute counter without re-anchoring: this runs every few seconds and
        // moving the anchor here is exactly what made the countdown jitter (see
        // `anchorMinutes`). Detect a desk power cycle two ways: the ring-buffer write
        // pointer regressed (a literal wraparound), or minutes-since-boot regressed (the
        // desk rebooted, even if its write pointer happens to still read higher than what
        // we'd already consumed under the old boot's larger minute counter). Either signal
        // means the old history is from a different boot session and must be discarded.
        let minutes = Int(try await read(Register.minutesSincePowerOn))
        // Recorded on every call, even when there is nothing new to ingest below, so
        // `recomputeToday` always has an up-to-date counter to project entry dates against.
        latestMinutes = minutes
        var resynced = false
        if writePointer < historyBytesRead || minutes < anchorMinutes {
            let reason = writePointer < historyBytesRead ? "pointer" : "minutes"
            log.info("""
                history resync reason=\(reason, privacy: .public) ptr=\(writePointer, privacy: .public) \
                read=\(self.historyBytesRead, privacy: .public) minutes=\(minutes, privacy: .public) \
                anchor=\(self.anchorMinutes, privacy: .public)
                """)
            forgetHistory()
            // The desk rebooted: its timer restarted with it, so moves from before the
            // reboot must not anchor the countdown after a restart of the app either.
            moveStore?.save([])
            resynced = true
            // A fresh boot can have an empty log (`writePointer == 0`), in which case the
            // guard below returns before any ingestion runs. Re-anchor regardless of that -
            // otherwise `anchorMinutes` stays stale, this same "minutes regressed" check
            // re-fires on every poll, and `forgetHistory()` wipes `observedMoves` every
            // `historyPollInterval` even though nothing is actually still wrong.
            try await refreshMinutes()
        }
        let readAt = now()
        if !resynced, !phaseLocked, let last = lastMinuteRead, minutes == last.minutes + 1,
           readAt.timeIntervalSince(last.at) < 15 {
            // The counter ticked between the last two reads: see `lastMinuteRead`.
            let rollover = last.at.addingTimeInterval(readAt.timeIntervalSince(last.at) / 2)
            anchorMinutes = minutes
            anchorDate = rollover.addingTimeInterval(30)
            phaseLocked = true
            log.info("""
                phase lock minutes=\(minutes, privacy: .public) \
                rollover=\(Self.isoFormatter.string(from: rollover), privacy: .public) \
                window=\(readAt.timeIntervalSince(last.at), privacy: .public)s
                """)
        }
        if !resynced { lastMinuteRead = (minutes, readAt) }
        guard writePointer > historyBytesRead else { return }
        // Entries arriving on the very first read of a session are the whole log, not news:
        // a countdown the desk wrote an hour ago must not start a seconds timer now.
        let initialIngest = historyBytesRead == 0
        var start = historyBytesRead
        var collected = Data()
        while start < writePointer {
            // The desk ignores the low two bits of the burst address: it always starts a
            // read at the address rounded down to a multiple of 4 (docs/protocol.md,
            // "Register access"). Request from that aligned address and drop the leading
            // bytes we didn't actually want, so `collected` (and therefore
            // `historyBytesRead`/`rawEntries`' byte offsets) still starts exactly at `start`.
            let alignedStart = start & ~3
            let lead = start - alignedStart
            let remaining = writePointer - start
            let chunks = min(Self.burstChunksPerRequest, (remaining + lead + 19) / 20)
            let data = try await retryOnce { () -> Data in
                let data = try await transport.burstRead(byteAddress: Register.historyBase + UInt32(alignedStart),
                                                         chunks: chunks)
                guard data.count >= chunks * 20 else {
                    throw DeskError.burstIncomplete(expected: chunks * 20, got: data.count)
                }
                return data
            }
            let usable = min(remaining, data.count - lead)
            collected.append(data.dropFirst(lead).prefix(usable))
            start += usable
        }
        let decoded = HistoryDecoder.decodeEntries(collected, firstByteOffset: historyBytesRead)
        rawEntries.append(contentsOf: decoded)
        historyBytesRead = writePointer
        // A countdown is "live" only when it arrived as new bytes and carries the desk's
        // current minute (or the one just ended, for a write straddling the tick).
        let currentMinute = UInt8(truncatingIfNeeded: minutes)
        let lastMinute = UInt8(truncatingIfNeeded: minutes - 1)
        for entry in decoded where !initialIngest && (entry.minuteByte == currentMinute || entry.minuteByte == lastMinute) {
            if case .countdown(let toStanding) = entry.kind { lastCountdownSeen = (now(), toStanding) }
        }
        let entryDescriptions = decoded.map(Self.describe).joined(separator: ",")
        log.notice("""
            history ingest ptr=\(writePointer, privacy: .public) read=\(self.historyBytesRead, privacy: .public) \
            bytes=\(collected.count, privacy: .public) entries=\(entryDescriptions, privacy: .public)
            """)
        // New entries changed what "now" means for the decoded timeline, so re-anchoring here
        // would normally be correct - except re-anchoring shifts every event by the
        // seconds-of-minute jitter, and the anchor is valid for 256 minutes, so keep it until
        // it is nearly stale (or the resync branch above already discarded it).
        if resynced || now().timeIntervalSince(anchorDate) > 200 * 60 {
            try await refreshMinutes()
        }
    }

    private func recomputeToday() {
        guard let settings = state.settings else { return }
        let t = now()
        // Event dates come from the fixed anchor, so they (and `nextMove`) stay put between
        // polls; only the rollup's notion of "now" advances, which is what makes the
        // at-desk total tick up and the countdown run down smoothly. `dateEntries` walks
        // backward assuming every entry is at or before its reference minute, so dating
        // against the *pinned* anchor would misdate by a 256-minute wrap any entry stamped
        // after the anchor was taken. Projecting the anchor forward by however far
        // `latestMinutes` has ticked past `anchorMinutes` fixes that while leaving
        // already-dated entries untouched: `latestMinutes` and the walk's first `diff`
        // advance together, so the same absolute dates fall out for them either way.
        let projectedNow = anchorDate.addingTimeInterval(Double(latestMinutes - anchorMinutes) * 60)
        let dated = HistoryDecoder.dateEntries(rawEntries, minutesSincePowerOn: latestMinutes, now: projectedNow)
        // The log runs minutes behind the desk, so live-detected moves are merged in and the
        // duplicates dropped once the log catches up. `DayRollup` stays a pure function of
        // whatever timeline it is handed.
        let events = Self.mergeObservedMoves(logged: dated, observed: observedMoves)
        // A logged move only gets to set the posture live readings are compared against once
        // it has taken its place in the merged, date-sorted timeline - otherwise a log entry
        // that is *older* than a move we already observed live (the log runs minutes behind,
        // see `observedMoves`) would overwrite `lastKnownPosture` with a stale value and the
        // next genuine live move would be skipped (`known != posture` false). No move at all
        // leaves whatever `noteStatus` set on the first reading of the connection untouched.
        if let lastMove = events.last(where: { if case .move = $0.kind { return true } else { return false } }),
           case .move(let toStanding) = lastMove.kind {
            lastKnownPosture = toStanding
        }
        let dayStart = DayRollup.dayStart(now: t, middleOfNightHour: settings.middleOfNightHour)
        // Whole-inch midpoint of the presets, rounded, so `DayRollup.compute` can tell a real
        // stand from a paddle nudge that never crossed it. `nil` when the presets aren't sane
        // yet - `compute` then falls back to the raise bit. Shared with `historyDocument()` so
        // the dashboard's threshold always matches what today's rollup itself used.
        let standingThresholdInches = Self.standingThresholdInches(settings)
        // The desk announced a move and the motor never started: `lastCountdownSeen` is only
        // cleared by an observed move, so one still standing past the announcement grace
        // (with no motion under way) is a countdown the user waved off. The log won't say so
        // for another five minutes; telling the rollup now stops it announcing a move that
        // isn't coming (2026-09-12, 13:40-13:44: "sit coming up" after a dismissed sit).
        let dismissedCountdownAt: Date? = lastCountdownSeen.flatMap { seen in
            motionStartedAt == nil && !state.isMoving
                && t.timeIntervalSince(seen.at) >= Self.countdownEntryToMotorSeconds + Self.announcementGraceSeconds
                ? seen.at : nil
        }
        var today = DayRollup.compute(events: events, now: t, dayStart: dayStart,
                                      cruise: settings.cruiseEnabled ? settings.cruise : nil,
                                      paused: settings.paused,
                                      standingThresholdInches: standingThresholdInches,
                                      dismissedCountdownAt: dismissedCountdownAt)
        // The event timeline says what the desk last *did*; the status register says where
        // the desk actually *is*. When they disagree - the user lowered the desk by hand
        // after an automatic stand - trust the live height. `nextMove` stays timeline-based,
        // since the desk's own rhythm is driven by moves, not by the current height.
        if let height = state.heightTenths,
           settings.sittingHeightTenths > 0,
           settings.standingHeightTenths > settings.sittingHeightTenths {
            let midpoint = (settings.sittingHeightTenths + settings.standingHeightTenths) / 2
            today.isStanding = height >= midpoint
        }
        // The desk has announced the move: its own timing takes over from the estimate.
        // Only while it is still the move the rollup expects (same direction) and recent -
        // a countdown the user waved off leaves the interval rule in charge again.
        // It expires `announcementGraceSeconds` after the motor was due: a countdown the user
        // waved off (or that the desk abandoned) must not leave "now" on screen.
        if let seen = lastCountdownSeen, let next = today.nextMove, next.toStanding == seen.toStanding,
           !state.isMoving,
           t.timeIntervalSince(seen.at) < Self.countdownEntryToMotorSeconds + Self.announcementGraceSeconds {
            today.nextMove = NextMove(at: seen.at.addingTimeInterval(Self.countdownEntryToMotorSeconds),
                                      toStanding: seen.toStanding, announcedAt: seen.at)
        }
        let previous = state.today
        if previous?.stands != today.stands || previous?.nextMove != today.nextMove {
            let next = today.nextMove.map { Self.isoFormatter.string(from: $0.at) } ?? "nil"
            log.notice("""
                today stands=\(today.stands, privacy: .public) \
                standing=\(Self.desc(today.isStanding), privacy: .public) \
                next=\(next, privacy: .public) \
                toStanding=\(Self.desc(today.nextMove?.toStanding), privacy: .public) \
                logged=\(Self.moveCount(dated), privacy: .public) \
                observed=\(self.observedMoves.count, privacy: .public) \
                merged=\(Self.moveCount(events), privacy: .public)
                """)
        }
        // Cheap change detector for the app's history-export throttle: only bump the counter
        // when the merged event *count* changed, not on every recompute (which runs on every
        // poll). This can under-count a same-size edit (e.g. a resync that replaces the log
        // with a different one of equal length), but that's an acceptable miss against a
        // once-a-minute exporter, not a correctness requirement - DeskModel.writeHistoryIfNeeded
        // also rewrites unconditionally every 60 s regardless of `historyRevision`, which is
        // what actually bounds how stale a missed same-size edit can get on disk.
        let historyChanged = events.count != mergedEvents.count
        mergedEvents = events
        publish {
            $0.today = today
            if historyChanged { $0.historyRevision += 1 }
        }
    }

    /// Whole-inch midpoint of the sitting/standing presets - `nil` when they aren't sane yet.
    /// Shared by `recomputeToday()` (feeds `DayRollup.compute`) and `historyDocument()` (feeds
    /// the dashboard's `HistoryDocument`), so both always agree on the threshold.
    private static func standingThresholdInches(_ settings: DeskSettings) -> Int? {
        guard settings.sittingHeightTenths > 0,
              settings.standingHeightTenths > settings.sittingHeightTenths else { return nil }
        return ((settings.sittingHeightTenths + settings.standingHeightTenths) / 2 + 5) / 10
    }

    /// The merged, dated history for the dashboard app: the same event list `recomputeToday()`
    /// builds (logged entries plus not-yet-logged live moves, deduplicated), the standing
    /// threshold in whole inches, and the middle-of-night hour. `nil` until settings have been
    /// read at least once (there's nothing meaningful to export yet).
    public func historyDocument() -> HistoryDocument? {
        guard let settings = state.settings else { return nil }
        return HistoryDocument(writtenAt: now(), standingThresholdInches: Self.standingThresholdInches(settings),
                               middleOfNightHour: settings.middleOfNightHour, events: mergedEvents)
    }

    // MARK: Writes

    public func writeRegister(_ address: UInt32, value: UInt32) async throws {
        if address == Register.bootloaderMagic { throw DeskError.forbiddenAddress(address) }
        guard connected else { throw DeskError.notConnected }
        try await transport.writeRegister(address, value: value)
    }

    /// The desk stores its current height into the preset; the written value is ignored.
    public func captureSittingPreset() async throws { try await capturePreset(offset: Register.UserOffset.sittingHeight) }
    public func captureStandingPreset() async throws { try await capturePreset(offset: Register.UserOffset.standingHeight) }

    private func capturePreset(offset: UInt32) async throws {
        // The desk stores whatever height it is at *when the write lands*, so the guards
        // below have to run against a fresh reading, not whatever the 1 Hz poll last saw.
        try await pollStatus()
        guard let settings = state.settings, let height = state.heightTenths else { throw DeskError.notConnected }
        guard !state.isMoving else { throw DeskError.invalidValue("desk is moving") }
        // The motion bit can clear before the desk has actually stopped travelling (see
        // `lastHeightChangeAt`), so `!state.isMoving` alone isn't proof the height above is
        // final - capturing during that window would store a transient, in-between height.
        guard pendingSettle == nil, Date().timeIntervalSince(lastHeightChangeAt) >= settleGrace else {
            throw DeskError.invalidValue("desk is still settling")
        }
        try await writeRegister(Register.userBase(settings.userIndex) + offset, value: UInt32(height))
        try await refreshSettings()
        let stored = offset == Register.UserOffset.sittingHeight ? state.settings?.sittingHeightTenths : state.settings?.standingHeightTenths
        guard let stored, abs(stored - height) <= 3 else {
            throw DeskError.invalidValue("""
                The desk stored \(Formatting.height(tenths: stored)) instead of \
                \(Formatting.height(tenths: height)). Move the desk to the height you want \
                and try again.
                """)
        }
        recomputeToday()
    }

    /// `nil` disables cruise control. Otherwise writes slot 1 (the app's custom slot) and selects it.
    public func setCruise(_ slot: CruiseSlot?) async throws {
        guard let settings = state.settings else { throw DeskError.notConnected }
        let base = Register.userBase(settings.userIndex)
        if let slot {
            guard slot.standingSeconds > 0, slot.sittingSeconds > 0 else {
                throw DeskError.invalidValue("cruise timing must be positive")
            }
            try await writeRegister(Register.cruiseSlotAddress(user: settings.userIndex, slot: 1), value: slot.raw)
            try await writeRegister(base + Register.UserOffset.activeCruiseSlot, value: 1)
        } else {
            try await writeRegister(base + Register.UserOffset.activeCruiseSlot, value: 0)
        }
        try await refreshSettings()
        recomputeToday()
    }

    public func setPaused(_ paused: Bool) async throws {
        guard let settings = state.settings else { throw DeskError.notConnected }
        var flags = UserFlags(rawValue: settings.flags)
        if paused { flags.insert(.paused) } else { flags.remove(.paused) }
        try await writeRegister(Register.userBase(settings.userIndex) + Register.UserOffset.flags, value: flags.rawValue)
        try await refreshSettings()
        recomputeToday()
    }

    public func syncClock() async throws {
        try await writeRegister(Register.clock, value: DeskClock(date: now()).raw)
    }
}
