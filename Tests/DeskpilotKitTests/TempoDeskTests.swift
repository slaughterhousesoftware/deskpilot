import XCTest
@testable import DeskpilotKit

/// A clock the test can move forward, for the actor's injected `now`.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) {
        lock.lock(); value = value.addingTimeInterval(seconds); lock.unlock()
    }
}

/// Thrown by `firstState`/`waitForHistory` on timeout, so a caller that forgets to check the
/// (already failed) test result doesn't silently keep running against stale state.
private struct TestTimeoutError: Error {}

final class TempoDeskTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func makeFake() -> FakeTransport {
        let fake = FakeTransport()
        fake.registers = [
            Register.firmwareApplication: 0x0001_0005,
            Register.minutesSincePowerOn: 5883,
            Register.historySize: 8192,
            Register.currentUser: 0,
            Register.status: 0x0000_010B,
            4096 + Register.UserOffset.flags: 0x1E3,
            4096 + Register.UserOffset.activeCruiseSlot: 1,
            4096 + Register.UserOffset.middleOfNightHour: 4,
            4096 + Register.UserOffset.standingHeight: 411,
            4096 + Register.UserOffset.sittingHeight: 266,
            4096 + Register.UserOffset.customHeightOne: 0,
            4096 + Register.UserOffset.customHeightTwo: 0,
            Register.cruiseSlotAddress(user: 0, slot: 1): 0x04B0_04B0,
        ]
        // present at t=231, move up at t=231 -> "now" (5883 % 256 == 251) is 20 min later
        fake.setHistory([0xE7, 0x51, 0xE7, 0x5D])
        return fake
    }

    /// Waits for the first published state matching `predicate`. Bounded by `timeout` (a
    /// stuck/broken poll loop used to hang this forever instead of failing the test) - races
    /// the stream against a timer and fails fast if the stream itself ends without a match.
    func firstState(_ desk: TempoDesk, timeout: TimeInterval = 10,
                    where predicate: @escaping (DeskState) -> Bool) async throws -> DeskState {
        try await withThrowingTaskGroup(of: DeskState?.self) { group in
            group.addTask {
                for await state in await desk.states() where predicate(state) { return state }
                return nil // the stream ended without ever matching
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil // timed out
            }
            defer { group.cancelAll() }
            if let first = try await group.next(), let state = first { return state }
            XCTFail("state did not satisfy predicate within \(timeout) s")
            throw TestTimeoutError()
        }
    }

    /// Waits until the desk has decoded at least `entries` history entries. Ingestion is not
    /// visible in `DeskState`, so this polls the actor instead of the state stream.
    func waitForHistory(_ entries: Int, in desk: TempoDesk, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await desk.decodedHistoryEntryCount >= entries { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("history was not ingested within \(timeout) s")
        throw TestTimeoutError()
    }

    func testQuietRetriesRecoverAndResetAfterASuccessfulSync() async throws {
        let fake = makeFake()
        fake.connectError = .timeout("scan")
        let desk = TempoDesk(transport: fake, pollInterval: 0.01, initialBackoff: 0.01,
                             backgroundRetryInterval: 0.15)
        await desk.start()
        _ = try await firstState(desk) { $0.reconnectingInBackground }
        XCTAssertEqual(fake.connectCalls, 3)
        fake.emit(.connecting)
        try await Task.sleep(for: .milliseconds(30))
        let quiet = await desk.currentState
        XCTAssertEqual(quiet.status, .disconnected)
        XCTAssertTrue(quiet.reconnectingInBackground)
        XCTAssertEqual(fake.connectCalls, 3, "Quiet mode must wait before probing again")

        fake.connectError = nil
        _ = try await firstState(desk) {
            $0.status == .connected && $0.today != nil && !$0.reconnectingInBackground
        }
        XCTAssertGreaterThanOrEqual(fake.connectCalls, 4, "Recovery must happen without manual reconnect")
        let callsBeforeDisconnect = fake.connectCalls
        fake.connectError = .timeout("scan")
        fake.emit(.disconnected(reason: "lost link"))
        let retry = try await firstState(desk) { $0.status == .connecting }
        XCTAssertFalse(retry.reconnectingInBackground, "A new disconnection gets visible retries")
        _ = try await firstState(desk) { $0.reconnectingInBackground }
        XCTAssertEqual(fake.connectCalls, callsBeforeDisconnect + 3)
        await desk.stop()
    }

    func testManualRestartLeavesQuietMode() async throws {
        let fake = makeFake()
        fake.connectError = .timeout("scan")
        let desk = TempoDesk(transport: fake, initialBackoff: 0.01, backgroundRetryInterval: 1)
        await desk.start()
        _ = try await firstState(desk) { $0.reconnectingInBackground }
        await desk.stop()
        await desk.start()
        let retry = try await firstState(desk) { $0.status == .connecting }
        XCTAssertFalse(retry.reconnectingInBackground)
        await desk.stop()
    }

    func testConnectReadsSettingsAndHistory() async throws {
        let fake = makeFake()
        let desk = TempoDesk(transport: fake, now: { self.now }, pollInterval: 0.02, historyPollInterval: 0.02)
        await desk.start()
        let state = try await firstState(desk) { $0.status == .connected && $0.today != nil }
        XCTAssertEqual(state.heightTenths, 267)
        XCTAssertEqual(state.settings?.firmware, "1.0.5")
        XCTAssertEqual(state.settings?.standingHeightTenths, 411)
        XCTAssertEqual(state.settings?.sittingHeightTenths, 266)
        XCTAssertEqual(state.settings?.cruise, CruiseSlot(standingSeconds: 1200, sittingSeconds: 1200))
        XCTAssertEqual(state.settings?.paused, false)
        XCTAssertEqual(state.today?.stands, 1)
        // The log's last move was up, but the desk reports 26.7\" - below the 33.8\" midpoint
        // of the 26.6/41.1 presets - so the live height wins. See testPostureComesFromLiveHeight.
        XCTAssertEqual(state.today?.isStanding, false)
        XCTAssertTrue(state.today?.isPresent ?? false)
        // moved up 20 min ago, standing lasts 20 min -> the interval already elapsed; the desk's
        // ~60 s move-lead pushes the target 60 s past "now"
        XCTAssertEqual(state.today?.nextMove, NextMove(at: now.addingTimeInterval(DayRollup.moveLeadSeconds), toStanding: false))
        await desk.stop()
    }

    func testPollPicksUpNewHistoryEntries() async throws {
        let fake = makeFake()
        let desk = TempoDesk(transport: fake, now: { self.now }, pollInterval: 0.02, historyPollInterval: 0.02)
        await desk.start()
        _ = try await firstState(desk) { $0.today != nil }
        fake.appendHistory([0xFB, 0x5C]) // move down at t=251 (= now)
        let state = try await firstState(desk) { $0.today?.nextMove?.toStanding == true }
        XCTAssertEqual(state.today?.stands, 1)
        XCTAssertEqual(state.today?.nextMove,
                       NextMove(at: now.addingTimeInterval(1200 + DayRollup.moveLeadSeconds), toStanding: true))
        await desk.stop()
    }

    func testCountdownEntryHandsTimingToTheDesk() async throws {
        // The desk announces a sit (COUNTDOWN down, stamped with the current minute): from
        // then on the next move is the desk's own timing - the entry's read time plus the
        // measured entry-to-motor lag - not the interval estimate, until the move it
        // announced is observed live, which hands the estimate the next interval. (The log's
        // last move was a stand, so the rollup already expects a sit and the two agree.)
        let fake = makeFake()
        let clock = TestClock(now)
        let desk = TempoDesk(transport: fake, now: { clock.now }, pollInterval: 0.02,
                             movingPollInterval: 0.02, historyPollInterval: 0.02)
        await desk.start()
        _ = try await firstState(desk) { $0.today != nil }
        fake.appendHistory([0xFB, 0x58])
        let announced = try await firstState(desk) { $0.today?.nextMove?.isAnnounced == true }
        XCTAssertEqual(announced.today?.nextMove,
                       NextMove(at: now.addingTimeInterval(TempoDesk.countdownEntryToMotorSeconds),
                                toStanding: false, announcedAt: now))
        XCTAssertEqual(announced.today?.nextMove?.announceAt, now)

        // The motor starts 13 s later and the desk settles 8 s after that: the observed move
        // is dated at the motor start, and the next interval counts from there.
        clock.advance(13)
        fake.registers[Register.status] = 0x8000_0150
        _ = try await firstState(desk) { $0.isMoving }
        clock.advance(8)
        fake.registers[Register.status] = 0x0000_010A
        let moved = try await firstState(desk) { !$0.isMoving && $0.today?.nextMove?.toStanding == true }
        XCTAssertEqual(moved.today?.nextMove?.isAnnounced, false)
        XCTAssertEqual(moved.today?.nextMove,
                       NextMove(at: now.addingTimeInterval(13 + 1200 + DayRollup.moveLeadSeconds), toStanding: true))
        await desk.stop()
    }

    func testDismissedCountdownRestartsTheIntervalOnceTheGraceExpires() async throws {
        // 2026-09-12, 13:39: the desk announced a sit, the user waved it off, and the motor
        // never started. The desk's timing showed "now" for the announcement grace, then the
        // rollup's log-only view took over and announced a move already due ("sit coming
        // up", then "waiting for the desk") until its five-minute resolution window ran out.
        // The app watched the motor not start; that is the moment the countdown is dismissed
        // and the next sit becomes a fresh interval from the read time.
        let fake = makeFake()
        let clock = TestClock(now)
        let desk = TempoDesk(transport: fake, now: { clock.now }, pollInterval: 0.02,
                             movingPollInterval: 0.02, historyPollInterval: 0.02)
        await desk.start()
        _ = try await firstState(desk) { $0.today != nil }
        fake.appendHistory([0xFB, 0x58])
        _ = try await firstState(desk) { $0.today?.nextMove?.isAnnounced == true }

        // Motor due at +14.1 s; grace runs out 15 s after that. The desk hasn't moved.
        clock.advance(TempoDesk.countdownEntryToMotorSeconds + TempoDesk.announcementGraceSeconds)
        let dismissed = try await firstState(desk) { $0.today?.nextMove?.isAnnounced == false }
        XCTAssertEqual(dismissed.today?.stands, 1, "no move happened")
        XCTAssertEqual(dismissed.today?.nextMove,
                       NextMove(at: now.addingTimeInterval(1200 + DayRollup.moveLeadSeconds), toStanding: false),
                       "a plain sitting interval from when the announcement was read")
        await desk.stop()
    }

    func testStatusPollUpdatesHeightAndMotion() async throws {
        let fake = makeFake()
        let desk = TempoDesk(transport: fake, now: { self.now }, pollInterval: 0.02, historyPollInterval: 1)
        await desk.start()
        _ = try await firstState(desk) { $0.status == .connected }
        try await fake.writeRegister(Register.status, value: 0x8000_0126)
        let state = try await firstState(desk) { $0.isMoving }
        XCTAssertEqual(state.heightTenths, 294)
        await desk.stop()
    }

    func testAdaptivePollingSpeedsUpWhileMoving() async throws {
        // The desk is only cheap to poll at 1 Hz while stationary; the live height readout
        // and the moving indicator should update smoothly (not in ~1 s jumps) while it's
        // actually in motion. `historyPollInterval` is set well beyond both measurement
        // windows so history bursts never fire during them, but count only
        // `Register.status` reads regardless: the run loop's very first history poll always
        // fires on iteration 1 (`lastHistoryPoll` starts at `.distantPast`), which would
        // otherwise pollute the stationary baseline with an extra, timing-dependent read.
        let fake = makeFake()
        let desk = TempoDesk(transport: fake, now: { self.now }, pollInterval: 0.2,
                             movingPollInterval: 0.02, historyPollInterval: 5)
        await desk.start()
        _ = try await firstState(desk) { $0.today != nil }

        func statusReads() -> Int { fake.readCounts[Register.status] ?? 0 }

        let stationaryBefore = statusReads()
        try await Task.sleep(nanoseconds: 300_000_000)
        let stationaryGrowth = statusReads() - stationaryBefore
        XCTAssertGreaterThan(stationaryGrowth, 0, "expected at least one stationary status read in 0.3 s")

        fake.registers[Register.status] = 0x8000_0150 // moving, 33.6"
        _ = try await firstState(desk) { $0.isMoving }
        let movingBefore = statusReads()
        try await Task.sleep(nanoseconds: 300_000_000)
        let movingGrowth = statusReads() - movingBefore

        // Compare ratios, not absolute counts, so this can't flake under CI load - but also
        // demand a floor, so a slow machine that starves both windows equally (making the
        // ratio look fine by coincidence) can't slip through either.
        XCTAssertGreaterThanOrEqual(movingGrowth, 6,
                                    "expected at least 6 status reads in 0.3 s while moving (moving=\(movingGrowth))")
        XCTAssertGreaterThanOrEqual(
            Double(movingGrowth), Double(stationaryGrowth) * 3,
            "expected status polling to speed up at least 3x while moving (stationary=\(stationaryGrowth), moving=\(movingGrowth))")
        await desk.stop()
    }

    func testFastPollingContinuesUntilHeightSettles() async throws {
        // Field observation: the desk clears the motion bit while still travelling (last
        // moving sample 40.5 in, settled at 41.1 in about a second later). Polling must not
        // drop back to the stationary cadence the instant the motion bit clears - it has to
        // keep polling fast for as long as the height keeps changing sample to sample, too.
        let fake = makeFake()
        let desk = TempoDesk(transport: fake, now: { self.now }, pollInterval: 0.2,
                             movingPollInterval: 0.02, historyPollInterval: 5)
        await desk.start()
        _ = try await firstState(desk) { $0.today != nil }

        func statusReads() -> Int { fake.readCounts[Register.status] ?? 0 }

        let stationaryBefore = statusReads()
        try await Task.sleep(nanoseconds: 300_000_000)
        let stationaryGrowth = statusReads() - stationaryBefore
        XCTAssertGreaterThan(stationaryGrowth, 0, "expected at least one stationary status read in 0.3 s")

        fake.registers[Register.status] = 0x8000_0190 // moving, 40.5"
        _ = try await firstState(desk) { $0.isMoving }
        fake.registers[Register.status] = 0x0000_0190 // motion bit clears, still 40.5" - not
                                                        // actually settled yet
        _ = try await firstState(desk) { $0.status == .connected && !$0.isMoving }

        // Keep feeding a *different* height every 40 ms - well under the 1 s settle grace -
        // for 300 ms, simulating the desk still creeping toward its final position with the
        // motion bit already clear. Polling must stay fast throughout: no two of these
        // samples are equal, so nothing here should ever be mistaken for "settled".
        let settlingBefore = statusReads()
        let stillChangingHeights: [UInt32] = [0x195, 0x199, 0x19D, 0x1A1, 0x1A5, 0x1A9]
        for h in stillChangingHeights {
            fake.registers[Register.status] = h // stopped, still changing
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        let settlingGrowth = statusReads() - settlingBefore
        XCTAssertGreaterThanOrEqual(settlingGrowth, 6,
                                    "expected at least 6 status reads in 0.3 s while still settling (settling=\(settlingGrowth))")
        XCTAssertGreaterThanOrEqual(
            Double(settlingGrowth), Double(stationaryGrowth) * 3,
            """
            expected fast polling to continue while the height is still settling, even with \
            the motion bit clear (stationary=\(stationaryGrowth), settling=\(settlingGrowth))
            """)
        await desk.stop()
    }

    func testWritesGoToTheRightRegistersAndRefuseMagic() async throws {
        let fake = makeFake()
        let desk = TempoDesk(transport: fake, now: { self.now }, pollInterval: 1, historyPollInterval: 1)
        await desk.start()
        _ = try await firstState(desk) { $0.settings != nil && $0.heightTenths != nil }

        try await desk.captureSittingPreset()
        XCTAssertEqual(fake.registers[4096 + Register.UserOffset.sittingHeight], 267)

        try await desk.captureStandingPreset()
        XCTAssertEqual(fake.registers[4096 + Register.UserOffset.standingHeight], 267)

        try await desk.setCruise(CruiseSlot(standingSeconds: 600, sittingSeconds: 3000))
        XCTAssertEqual(fake.registers[Register.cruiseSlotAddress(user: 0, slot: 1)], 0x0258_0BB8)
        XCTAssertEqual(fake.registers[4096 + Register.UserOffset.activeCruiseSlot], 1)

        try await desk.setCruise(nil)
        XCTAssertEqual(fake.registers[4096 + Register.UserOffset.activeCruiseSlot], 0)

        try await desk.setPaused(true)
        XCTAssertEqual(fake.registers[4096 + Register.UserOffset.flags], 0x1E7)
        try await desk.setPaused(false)
        XCTAssertEqual(fake.registers[4096 + Register.UserOffset.flags], 0x1E3)

        do {
            try await desk.writeRegister(Register.bootloaderMagic, value: 14)
            XCTFail("expected forbidden")
        } catch let error as DeskError {
            XCTAssertEqual(error, .forbiddenAddress(16))
        }
        XCTAssertFalse(fake.writes.contains { $0.address == 16 })
        await desk.stop()
    }

    func testPeriodicFlagsPollPicksUpDeskSidePauseChange() async throws {
        let fake = makeFake()
        let desk = TempoDesk(transport: fake, now: { self.now }, pollInterval: 0.02,
                             historyPollInterval: 1, flagsPollInterval: 0.05)
        await desk.start()
        let connected = try await firstState(desk) { $0.settings != nil }
        XCTAssertEqual(connected.settings?.paused, false)

        // The desk's own handset toggled pause - set bit 2 (UserFlags.paused) directly on
        // the fake, bypassing writeRegister (which only the app itself ever calls), to
        // simulate the desk changing this on its own. Only the periodic pollDiagnostics()
        // read (not the 1 s status/height poll) will ever notice this.
        fake.registers[4096 + Register.UserOffset.flags] = 0x1E3 | 0x4

        let state = try await firstState(desk) { $0.settings?.paused == true }
        XCTAssertEqual(state.settings?.paused, true)
        await desk.stop()
    }

    func testCapturePresetRefusesWhileMoving() async throws {
        let fake = makeFake()
        let desk = TempoDesk(transport: fake, now: { self.now }, pollInterval: 0.02, historyPollInterval: 1)
        await desk.start()
        _ = try await firstState(desk) { $0.settings != nil }

        try await fake.writeRegister(Register.status, value: 0x8000_010C)
        _ = try await firstState(desk) { $0.isMoving }

        do {
            try await desk.captureSittingPreset()
            XCTFail("expected invalid")
        } catch let error as DeskError {
            if case .invalidValue = error {} else { XCTFail("wrong error \(error)") }
        }
        XCTAssertFalse(fake.writes.contains { $0.address == 4096 + Register.UserOffset.sittingHeight })
        await desk.stop()
    }

    func testCapturePresetRefusesWhileSettling() async throws {
        // The motion bit can clear before the desk has actually stopped travelling (field
        // observation, see `lastHeightChangeAt`), so `!isMoving` alone isn't proof a capture
        // right now would store the desk's real, final height. `settleGrace` is shrunk so
        // this doesn't have to real-sleep a full second to exercise it.
        let fake = makeFake()
        let desk = TempoDesk(transport: fake, now: { self.now }, pollInterval: 0.02,
                             movingPollInterval: 0.02, historyPollInterval: 1, settleGrace: 0.02)
        await desk.start()
        _ = try await firstState(desk) { $0.settings != nil }

        fake.registers[Register.status] = 0x8000_0190 // moving, 40.5"
        _ = try await firstState(desk) { $0.isMoving }
        fake.registers[Register.status] = 0x0000_0190 // motion bit clears, still 40.5" - not
                                                        // actually settled yet
        _ = try await firstState(desk) { $0.status == .connected && !$0.isMoving }
        fake.registers[Register.status] = 0x0000_0195 // still creeping toward its final height

        do {
            // No sleep first: whichever poll (the background loop's or this call's own) sees
            // the new height first, `lastHeightChangeAt` ends up set to "just now" either way,
            // so this is still expected to report "still settling".
            try await desk.captureStandingPreset()
            XCTFail("expected invalid")
        } catch let error as DeskError {
            if case .invalidValue = error {} else { XCTFail("wrong error \(error)") }
        }
        XCTAssertFalse(fake.writes.contains { $0.address == 4096 + Register.UserOffset.standingHeight })

        // Hold still long enough for two stable samples and the settle grace to pass.
        try await Task.sleep(nanoseconds: 100_000_000)
        try await desk.captureStandingPreset()
        XCTAssertEqual(fake.registers[4096 + Register.UserOffset.standingHeight], 405)
        await desk.stop()
    }

    func testReconnectsAfterDisconnectWithBackoff() async throws {
        let fake = makeFake()
        let desk = TempoDesk(transport: fake, now: { self.now }, pollInterval: 0.02,
                             historyPollInterval: 1, initialBackoff: 0.01)
        await desk.start()
        _ = try await firstState(desk) { $0.status == .connected }
        fake.emit(.disconnected(reason: "gone"))
        _ = try await firstState(desk) { $0.status == .disconnected }
        let reconnected = try await firstState(desk) { $0.status == .connected }
        XCTAssertEqual(reconnected.status, .connected)
        XCTAssertGreaterThanOrEqual(fake.connectCalls, 2)
        await desk.stop()
    }

    func testStopWaitsForLoopsThenStartRestartsCleanly() async throws {
        let fake = makeFake()
        let desk = TempoDesk(transport: fake, now: { self.now }, pollInterval: 0.02, historyPollInterval: 1)
        await desk.start()
        _ = try await firstState(desk) { $0.status == .connected }

        await desk.stop()
        let stoppedState = await desk.currentState
        XCTAssertEqual(stoppedState.status, .disconnected)

        // If stop() returned before the old loop task actually finished, it would keep
        // polling the transport in the background even though we've moved on.
        let readCountAtStop = fake.readCount
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(fake.readCount, readCountAtStop,
                       "no further transport reads should happen once stop() has returned")

        await desk.start()
        _ = try await firstState(desk) { $0.status == .connected }
        XCTAssertEqual(fake.connectCalls, 2, "a lingering old loop would reconnect on its own")
        await desk.stop()
    }

    func testResyncsHistoryWhenWritePointerGoesBackwards() async throws {
        let fake = makeFake()
        let desk = TempoDesk(transport: fake, now: { self.now }, pollInterval: 0.02, historyPollInterval: 0.02)
        await desk.start()
        _ = try await firstState(desk) { $0.today != nil }

        // Simulate a desk power cycle: history is replaced (not appended) and
        // minutes-since-boot drops, even though the new write pointer (6) is numerically
        // larger than what we'd already consumed (4) under the old boot.
        fake.setHistory([0x05, 0x40, 0x05, 0x51, 0x0A, 0x5C], // user change, present, move down at t=5/10
                        minutesSincePowerOn: 10)

        let state = try await firstState(desk) { $0.today?.stands == 0 }
        XCTAssertEqual(state.today?.stands, 0, "the pre-reboot standing entry must be discarded")
        // moved down at t=10 == "now"; sitting lasts 1200s, plus the desk's ~60s move-lead ->
        // next stand is now + 1260s
        XCTAssertEqual(state.today?.nextMove,
                       NextMove(at: now.addingTimeInterval(1200 + DayRollup.moveLeadSeconds), toStanding: true))
        await desk.stop()
    }

    func testResyncWithEmptyLogDoesNotRepeatedlyWipeObservedMoves() async throws {
        // Regression: a resync (write pointer or minutes regressed) used to return before
        // re-anchoring whenever the log was empty (`writePointer == 0`, e.g. a fresh boot) -
        // the early `guard writePointer > historyBytesRead else { return }` sat *after* the
        // resync branch, so `anchorMinutes` stayed stale. The "minutes regressed" check then
        // re-fired on every history poll, and `forgetHistory()` wiped `observedMoves` (and
        // `lastStatus`, breaking the settle/jump comparison) every `historyPollInterval`, even
        // though nothing was actually still wrong after the first resync.
        let fake = makeFake()
        let desk = TempoDesk(transport: fake, now: { self.now }, pollInterval: 0.02, historyPollInterval: 0.02)
        await desk.start()
        _ = try await firstState(desk) { $0.today != nil }

        fake.setHistory([], minutesSincePowerOn: 3) // fresh boot: empty log, minutes regressed
        // Let several resync-triggering polls run before the live stand below, so an
        // unfixed, persistent resync loop has ample opportunity to wipe the observed move
        // (or prevent it from ever being recorded).
        try await Task.sleep(nanoseconds: 200_000_000)

        fake.registers[Register.status] = 0x8000_0150 // moving, 33.6"
        _ = try await firstState(desk) { $0.isMoving }
        fake.registers[Register.status] = 0x0000_019B // stopped, standing (41.1")

        let state = try await firstState(desk) { $0.today?.isStanding == true && $0.today?.stands == 1 }
        XCTAssertEqual(state.today?.isStanding, true)
        XCTAssertEqual(state.today?.stands, 1, "the observed stand must survive the resync")
        await desk.stop()
    }

    func testNextMoveAnchorIsStableBetweenPolls() async throws {
        // Regression: the history clock used to be re-anchored to `now` on every poll, so
        // every decoded event date - and with it `nextMove.at` - slid forward one second per
        // second. The popover's mm:ss countdown froze for 60 s and then dropped a minute.
        let fake = makeFake()
        let clock = TestClock(now)
        let desk = TempoDesk(transport: fake, now: { clock.now }, pollInterval: 0.02, historyPollInterval: 0.02)
        await desk.start()
        let first = try await firstState(desk) { $0.today != nil }
        let anchored = try XCTUnwrap(first.today?.nextMove)
        let atDeskBefore = try XCTUnwrap(first.today?.atDeskSeconds)

        clock.advance(30)
        // The desk's own minute counter also ticks forward while we wait; already-dated
        // entries must not budge because of it (see `latestMinutes`/`projectedNow` in
        // `recomputeToday`).
        fake.registers[Register.minutesSincePowerOn] = 5884
        let later = try await firstState(desk) { ($0.today?.atDeskSeconds ?? 0) >= atDeskBefore + 29 }
        XCTAssertEqual(later.today?.nextMove, anchored, "the countdown target must not move with the clock")
        XCTAssertEqual(try XCTUnwrap(later.today?.atDeskSeconds) - atDeskBefore, 30, accuracy: 1)
        await desk.stop()
    }

    func testEntriesNewerThanTheAnchorAreDatedForward() async throws {
        // Regression: a log entry stamped *after* the anchor's minute reference used to be
        // misdated 256 minutes into the past, because `dateEntries`'s backward walk assumes
        // every entry is at or before its reference minute. Observed live: the desk flushed a
        // countdown entry at anchor+9 minutes and `nextMove.at` jumped from 16:26:41 to
        // 12:10:41. Here the desk's minute counter ticks forward by 2 (5883 -> 5885) and then
        // logs a move stamped at the new minute (253), which must date forward from the
        // anchor's reference (251), not wrap around it.
        let fake = makeFake()
        let desk = TempoDesk(transport: fake, now: { self.now }, pollInterval: 0.02, historyPollInterval: 0.02)
        await desk.start()
        _ = try await firstState(desk) { $0.today != nil }

        fake.registers[Register.minutesSincePowerOn] = 5885
        fake.appendHistory([0xFD, 0x5C]) // move down at minute 253 (anchor reference 251 + 2)
        // `waitForHistory` only returns once ingestion (and the `recomputeToday` that follows
        // it in the same actor turn) has happened - see the note in
        // `testLoggedMoveDedupesAgainstObservedMove`.
        try await waitForHistory(3, in: desk)

        let state = await desk.currentState
        XCTAssertEqual(state.today?.nextMove,
                       NextMove(at: now.addingTimeInterval(2 * 60 + 1200 + DayRollup.moveLeadSeconds), toStanding: true),
                       "the new entry must date 2 minutes after the anchor, not 256 minutes before it")
        // The pre-existing t=231 move must keep its original date - stands still counts it,
        // and the presence interval it opened is unaffected by the newer entry's dating.
        XCTAssertEqual(state.today?.stands, 1)
        XCTAssertEqual(try XCTUnwrap(state.today?.atDeskSeconds), 1200, accuracy: 1)
        await desk.stop()
    }

    func testIncrementalHistoryReadIsAlignedToFourBytes() async throws {
        // Regression, root-caused live: the desk ignores the low two bits of a burst-read
        // address and always serves data starting at the address rounded down to a multiple
        // of 4 (docs/protocol.md, "Register access"). Six bytes already consumed puts the
        // next incremental read at byte offset 6 (2 mod 4); if `pollHistory` requests that
        // address literally instead of aligning down and dropping the leading bytes, the
        // desk serves data starting at offset 4 instead - re-decoding the already-ingested
        // NOP at offset 4-5 and never reading the real new entry at offset 6-7 at all.
        let fake = makeFake()
        // present at t=231, move up at t=231, NOP at t=232 -> historyBytesRead == 6 (2 mod 4)
        // after the first poll.
        fake.setHistory([0xE7, 0x51, 0xE7, 0x5D, 0xE8, 0x00], minutesSincePowerOn: 5883)
        let desk = TempoDesk(transport: fake, now: { self.now }, pollInterval: 0.02, historyPollInterval: 0.02)
        await desk.start()
        _ = try await firstState(desk) { $0.today != nil }

        fake.appendHistory([0xFB, 0x5C]) // move down at t=251 (== now)
        try await waitForHistory(4, in: desk)

        let state = await desk.currentState
        XCTAssertEqual(state.today?.stands, 1, "the pre-existing move up must not be decoded twice")
        XCTAssertEqual(state.today?.nextMove?.toStanding, true, "the appended move down must be decoded")
        await desk.stop()
    }

    func testBluetoothOffReachesTheUIAsItsOwnStatus() async throws {
        let fake = makeFake()
        fake.connectError = .bluetoothOff
        let desk = TempoDesk(transport: fake, now: { self.now }, pollInterval: 0.02,
                             historyPollInterval: 1, initialBackoff: 0.01)
        await desk.start()
        // `updatedAt` is `.distantPast` only for the never-published initial state.
        let state = try await firstState(desk) { $0.updatedAt != .distantPast && $0.status != .connecting }
        XCTAssertEqual(state.status, .bluetoothOff)
        XCTAssertEqual(state.lastError, "Bluetooth is turned off")
        await desk.stop()
    }

    func testUnauthorizedReachesTheUIAsItsOwnStatus() async throws {
        let fake = makeFake()
        fake.connectError = .unauthorized
        let desk = TempoDesk(transport: fake, now: { self.now }, pollInterval: 0.02,
                             historyPollInterval: 1, initialBackoff: 0.01)
        await desk.start()
        let state = try await firstState(desk) { $0.updatedAt != .distantPast && $0.status != .connecting }
        XCTAssertEqual(state.status, .unauthorized)
        XCTAssertEqual(state.lastError, "Bluetooth access was denied")
        await desk.stop()
    }

    /// A failed connect reaches the menu as a sentence, not the error's Swift debug text
    /// (`timeout("scan")`), and a scan that found nothing says so rather than "didn't answer".
    func testConnectFailuresReachTheUIWrittenOut() async throws {
        for (error, text) in [(DeskError.timeout("scan"), "Couldn't find the desk. Is it on and in range?"),
                              (DeskError.timeout("connect"), "The desk didn't answer in time."),
                              (DeskError.gatt("boom"), "Lost contact with the desk. Try again.")] {
            let fake = makeFake()
            fake.connectError = error
            let desk = TempoDesk(transport: fake, now: { self.now }, pollInterval: 0.02,
                                 historyPollInterval: 1, initialBackoff: 0.01)
            await desk.start()
            let state = try await firstState(desk) { $0.updatedAt != .distantPast && $0.status == .disconnected }
            XCTAssertEqual(state.lastError, text)
            await desk.stop()
        }
    }

    func testTransientGattErrorIsRetriedInsteadOfDroppingTheConnection() async throws {
        let fake = makeFake()
        fake.failNextReads = 1
        // A long backoff makes `connectCalls == 1` meaningful: a reconnect could not have
        // happened this fast.
        let desk = TempoDesk(transport: fake, now: { self.now }, pollInterval: 0.02,
                             historyPollInterval: 0.02, initialBackoff: 5)
        await desk.start()
        let state = try await firstState(desk) { $0.status == .connected && $0.today != nil }
        XCTAssertEqual(state.settings?.firmware, "1.0.5")
        XCTAssertEqual(fake.connectCalls, 1, "a retried read must not tear the connection down")
        await desk.stop()
    }

    func testPostureComesFromLiveHeight() async throws {
        // The user stood up automatically, then lowered the desk by hand: the log still says
        // "up" but the desk is at sitting height, and the popover must not claim "Standing".
        let fake = makeFake()
        let desk = TempoDesk(transport: fake, now: { self.now }, pollInterval: 0.02, historyPollInterval: 1)
        await desk.start()
        let sitting = try await firstState(desk) { $0.today != nil }
        XCTAssertEqual(sitting.heightTenths, 267)
        XCTAssertEqual(sitting.today?.isStanding, false)
        XCTAssertEqual(sitting.today?.nextMove, NextMove(at: now.addingTimeInterval(DayRollup.moveLeadSeconds), toStanding: false),
                       "nextMove stays log-based")

        try await fake.writeRegister(Register.status, value: 0x0000_019B) // 41.1"
        let standing = try await firstState(desk) { $0.today?.isStanding == true }
        XCTAssertEqual(standing.heightTenths, 411)
        await desk.stop()
    }

    func testPresetCaptureStoresTheDesksCurrentHeight() async throws {
        let fake = makeFake()
        let desk = TempoDesk(transport: fake, now: { self.now }, pollInterval: 1,
                             historyPollInterval: 1, settleGrace: 0.02)
        await desk.start()
        _ = try await firstState(desk) { $0.settings != nil && $0.heightTenths != nil }

        // The desk moved since the last 1 Hz poll; capture must re-read the status register
        // first, otherwise it validates the readback against a stale height and fails. That
        // fresh read is itself the *first* time the actor has seen 41.1", though, so it also
        // has to wait out the settle grace (see `lastHeightChangeAt`) before trusting it - the
        // very first attempt right after the move is expected to report "still settling".
        // `settleGrace` is shrunk so waiting it out doesn't mean a full real second, and stays
        // well under `pollInterval` (1 s) so the background loop still hasn't polled again by
        // the time the second attempt below re-reads the register itself.
        try await fake.writeRegister(Register.status, value: 0x0000_019B) // 41.1"
        do {
            try await desk.captureStandingPreset()
            XCTFail("expected the freshly-observed height to need a moment to settle")
        } catch let error as DeskError {
            if case .invalidValue = error {} else { XCTFail("wrong error \(error)") }
        }

        try await Task.sleep(nanoseconds: 100_000_000) // past the settle grace
        try await desk.captureStandingPreset()
        XCTAssertEqual(fake.registers[4096 + Register.UserOffset.standingHeight], 411)
        let state = await desk.currentState
        XCTAssertEqual(state.settings?.standingHeightTenths, 411)
        await desk.stop()
    }

    func testObservedMoveAnchorsNextMoveBeforeLogCatchesUp() async throws {
        // The desk writes its history log minutes late (docs/protocol.md, "Write latency"),
        // so a stand that has just happened is still invisible in the log. The status
        // register is live, and the move has to be picked up there - otherwise the popover
        // keeps saying "Next stand in: now" while the desk is already up.
        let fake = makeFake()
        fake.setHistory([0xFB, 0x5C]) // logged move down at t=251 (== now)
        let desk = TempoDesk(transport: fake, now: { self.now }, pollInterval: 0.02,
                             movingPollInterval: 0.02, historyPollInterval: 0.02)
        await desk.start()
        let sitting = try await firstState(desk) { $0.today != nil }
        XCTAssertEqual(sitting.today?.stands, 0)
        XCTAssertEqual(sitting.today?.isStanding, false)

        fake.registers[Register.status] = 0x8000_0150 // moving, 33.6"
        _ = try await firstState(desk) { $0.isMoving }
        fake.registers[Register.status] = 0x0000_019B // stopped at 41.1"

        let standing = try await firstState(desk) { $0.today?.stands == 1 }
        XCTAssertEqual(standing.today?.isStanding, true)
        let next = try XCTUnwrap(standing.today?.nextMove)
        XCTAssertFalse(next.toStanding, "the live stand must restart the sit countdown")
        XCTAssertEqual(next.at.timeIntervalSince(now), 1200 + DayRollup.moveLeadSeconds, accuracy: 5)
        await desk.stop()
    }

    func testLoggedMoveDedupesAgainstObservedMove() async throws {
        let fake = makeFake()
        fake.setHistory([0xFB, 0x5C]) // logged move down at t=251 (== now)
        let desk = TempoDesk(transport: fake, now: { self.now }, pollInterval: 0.02,
                             movingPollInterval: 0.02, historyPollInterval: 0.02)
        await desk.start()
        _ = try await firstState(desk) { $0.today != nil }

        fake.registers[Register.status] = 0x8000_0150
        _ = try await firstState(desk) { $0.isMoving }
        fake.registers[Register.status] = 0x0000_019B
        _ = try await firstState(desk) { $0.today?.stands == 1 }

        // Minutes later the desk finally writes the move it already made: countdown up,
        // HEIGHT 41, MOVE up, all stamped with the current minute (5883 % 256 == 251).
        XCTAssertEqual(fake.registers[Register.minutesSincePowerOn], 5883)
        fake.appendHistory([0xFB, 0x59, 0xFB, 0x35, 0xFB, 0x5D])
        // `waitForHistory` only returns once the actor has ingested the new entries, and
        // `recomputeToday` runs synchronously right after ingestion within the same poll
        // iteration (no suspension point in between), so the rollup is already current here -
        // no separate sleep needed to let it "catch up".
        try await waitForHistory(4, in: desk)

        let state = await desk.currentState
        XCTAssertEqual(state.today?.stands, 1, "the logged move is the one we already saw live")
        XCTAssertEqual(state.today?.isStanding, true)
        XCTAssertEqual(state.today?.nextMove?.toStanding, false)
        await desk.stop()
    }

    func testStaleLoggedMoveDoesNotSuppressLiveDetection() async throws {
        // Regression for B1: a logged move used to overwrite `lastKnownPosture` unconditionally
        // as soon as it was decoded, even if it was *older* than a move already observed live.
        // Here the desk stands, sits, and only then logs the (by now stale) stand - one minute
        // "before" the sit, since the log's minute stamps are coarse. If the stale entry is
        // allowed to stick, the next live stand looks like a no-op (`known != posture` false)
        // and is silently dropped.
        let fake = makeFake()
        let clock = TestClock(now)
        let desk = TempoDesk(transport: fake, now: { clock.now }, pollInterval: 0.02,
                             movingPollInterval: 0.02, historyPollInterval: 0.02)
        await desk.start()
        _ = try await firstState(desk) { $0.today != nil }

        fake.registers[Register.status] = 0x8000_0150 // moving, 33.6"
        _ = try await firstState(desk) { $0.isMoving }
        fake.registers[Register.status] = 0x0000_019B // stopped, standing (41.1")
        _ = try await firstState(desk) { $0.today?.isStanding == true }

        fake.registers[Register.status] = 0x8000_0150 // moving, 33.6"
        _ = try await firstState(desk) { $0.isMoving }
        fake.registers[Register.status] = 0x0000_010A // stopped, sitting (26.6")
        _ = try await firstState(desk) { $0.today?.isStanding == false }
        // `isStanding` above flips from the live height override alone; the *observed move*
        // (what this test actually needs recorded before moving on) isn't finalized until a
        // second, matching sample confirms the height settled - it's still `0x010A` here, so
        // that confirmation follows within a poll or two. `nextMove` flipping to "next: up"
        // is a precise signal for it, since the initial log's last move ("up") otherwise
        // leaves it "next: down".
        _ = try await firstState(desk) { $0.today?.nextMove?.toStanding == true }

        // The desk finally logs the stand it made above, stamped one minute before "now" - one
        // minute before the sit, since the fixed test clock means both live moves were recorded
        // at the same instant.
        XCTAssertEqual(fake.registers[Register.minutesSincePowerOn], 5883)
        let staleMinute = UInt8((5883 % 256) - 1)
        fake.appendHistory([staleMinute, 0x5D]) // move up, one minute stale
        try await waitForHistory(3, in: desk)

        // Advance well past `observedMoveDedupeWindow` before the next live stand, so this is
        // strictly a `lastKnownPosture` assertion, not a coincidental collision with the
        // (separately tested) dedupe window in `mergeObservedMoves`.
        clock.advance(300)
        fake.registers[Register.status] = 0x8000_0150 // moving, 33.6"
        _ = try await firstState(desk) { $0.isMoving }
        fake.registers[Register.status] = 0x0000_019B // stopped, standing (41.1")

        let state = try await firstState(desk) {
            $0.today?.isStanding == true && $0.today?.nextMove?.toStanding == false
        }
        let next = try XCTUnwrap(state.today?.nextMove, "the live stand must have been detected and re-anchored the countdown")
        XCTAssertEqual(next.at.timeIntervalSince(clock.now), 1200 + DayRollup.moveLeadSeconds, accuracy: 5)
        await desk.stop()
    }

    func testImplausibleStatusReadingIsIgnored() async throws {
        // Regression for B4: a garbled status read (the fake's stand-in for a dropped/corrupted
        // notification) used to trip the settle/jump heuristics and record a bogus move that no
        // log entry will ever dedupe against. It must also never reach `heightTenths` at all -
        // that value drives the live-height `isStanding` override and the widget snapshot, so
        // publishing it even transiently would leak the garbage further downstream.
        let fake = makeFake()
        let desk = TempoDesk(transport: fake, now: { self.now }, pollInterval: 0.02, historyPollInterval: 1)
        await desk.start()
        let connected = try await firstState(desk) { $0.today != nil }
        let standsBefore = connected.today?.stands
        let nextMoveBefore = connected.today?.nextMove
        XCTAssertEqual(connected.heightTenths, 267)

        let readsBefore = fake.readCount
        fake.registers[Register.status] = 0xDEAD_BEEF // heightTenths == 48879, wildly implausible
        // No `firstState` predicate can observe this: the fix is precisely that no new state
        // is ever published for it. Instead, wait for several poll cycles to run against the
        // bogus reading (pollInterval 0.02 s, one status read each), then check the actor's
        // current state directly.
        let deadline = Date().addingTimeInterval(2)
        while fake.readCount < readsBefore + 10, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThanOrEqual(fake.readCount, readsBefore + 10,
                                    "expected several polls to run against the bogus reading")
        let whileBogus = await desk.currentState
        XCTAssertEqual(whileBogus.heightTenths, 267, "the implausible reading must never reach heightTenths")
        XCTAssertEqual(whileBogus.today?.stands, standsBefore, "nor must it be counted as a move")
        XCTAssertEqual(whileBogus.today?.nextMove, nextMoveBefore, "nor must it perturb the countdown")

        fake.registers[Register.status] = 0x0000_010B // back to the real reading
        let after = try await firstState(desk) { $0.heightTenths == 267 }
        XCTAssertEqual(after.today?.stands, standsBefore, "the implausible reading must not be counted as a move")
        XCTAssertEqual(after.today?.nextMove, nextMoveBefore, "nor must it perturb the countdown")
        await desk.stop()
    }

    func testHistoryDocumentReturnsTheMergedDatedEvents() async throws {
        let fake = makeFake()
        let desk = TempoDesk(transport: fake, now: { self.now }, pollInterval: 0.02, historyPollInterval: 0.02)
        await desk.start()
        _ = try await firstState(desk) { $0.today != nil }

        let historyDocument = await desk.historyDocument()
        let document = try XCTUnwrap(historyDocument)
        // The fixture logs presence(true) and move(toStanding: true), both at t=231 - see
        // `makeFake`.
        XCTAssertEqual(document.events.count, 2)
        XCTAssertEqual(document.events.map(\.kind), [.presence(present: true), .move(toStanding: true)])
        // Whole-inch midpoint of the 26.6"/41.1" presets: (266+411)/2 = 338 (truncated), +5,
        // /10 = 34.
        XCTAssertEqual(document.standingThresholdInches, 34)
        XCTAssertEqual(document.middleOfNightHour, 4)
        await desk.stop()
    }

    func testHistoryDocumentIsNilBeforeSettingsAreKnown() async throws {
        let desk = TempoDesk(transport: FakeTransport(), now: { self.now })
        let historyDocument = await desk.historyDocument()
        XCTAssertNil(historyDocument)
    }

    func testMergeObservedMovesDedupesWithinThreeMinutes() {
        let logged = [HistoryEvent(byteOffset: 8, date: now, kind: .move(toStanding: true))]
        func observed(_ offset: TimeInterval, toStanding: Bool) -> HistoryEvent {
            HistoryEvent(byteOffset: -1, date: now.addingTimeInterval(offset), kind: .move(toStanding: toStanding))
        }

        let near = TempoDesk.mergeObservedMoves(logged: logged, observed: [observed(120, toStanding: true)])
        XCTAssertEqual(near, [HistoryEvent(byteOffset: 8, date: now.addingTimeInterval(120), kind: .move(toStanding: true))],
                       "a logged move within 3 min is the same move - kept, but dated to the observed, second-precise timestamp")

        let far = TempoDesk.mergeObservedMoves(logged: logged, observed: [observed(300, toStanding: true)])
        XCTAssertEqual(far.count, 2, "5 min apart is a different move")
        XCTAssertEqual(far.map(\.date), [now, now.addingTimeInterval(300)])

        let opposite = TempoDesk.mergeObservedMoves(logged: logged, observed: [observed(60, toStanding: false)])
        XCTAssertEqual(opposite.count, 2, "opposite directions are never the same move")
        XCTAssertEqual(opposite.last?.kind, .move(toStanding: false))

        XCTAssertEqual(TempoDesk.mergeObservedMoves(logged: logged, observed: []), logged)
    }

    func testMergeObservedMovesUsesTheObservedDateForADedupedMove() {
        // Field result: the desk stood 21 min after the *actual* end of a manual sit, but the
        // app predicted a minute early because it anchored to the logged move's minute-rounded
        // timestamp instead of the observed one's second precision.
        let logged = [HistoryEvent(byteOffset: 8, date: now, kind: .move(toStanding: true))] // T, minute-rounded
        let observed = [HistoryEvent(byteOffset: -1, date: now.addingTimeInterval(50), kind: .move(toStanding: true))] // T+50s
        let merged = TempoDesk.mergeObservedMoves(logged: logged, observed: observed)
        XCTAssertEqual(merged, [HistoryEvent(byteOffset: 8, date: now.addingTimeInterval(50), kind: .move(toStanding: true))])
    }
}
