import XCTest
@testable import DeskpilotKit

final class CommandQueueTests: XCTestCase {
    func makeQueue() -> CommandQueue {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tempo-commands-\(UUID().uuidString)")
        return CommandQueue(directory: dir)
    }

    /// Cancelling withdraws a command the menu bar app hasn't picked up yet, so a command the
    /// dashboard has already given up on can't be applied to the desk afterwards.
    func testCancelRemovesAPendingCommand() throws {
        let queue = makeQueue()
        let id = try queue.enqueue(.captureStandingPreset)
        XCTAssertEqual(queue.pending().map(\.id), [id])

        try queue.cancel(id: id)

        XCTAssertEqual(queue.pending(), [])
        XCTAssertNil(queue.result(for: id))
    }

    /// Cancelling something that isn't queued - already executed, already cancelled, or never
    /// there - is a no-op rather than an error, and leaves other commands alone.
    func testCancelIsANoOpWhenTheCommandIsGone() throws {
        let queue = makeQueue()
        let kept = try queue.enqueue(.captureSittingPreset)
        let done = try queue.enqueue(.setPaused(true))
        try queue.complete(done, success: true, message: nil)

        XCTAssertNoThrow(try queue.cancel(id: done))
        XCTAssertNoThrow(try queue.cancel(id: UUID()))

        XCTAssertEqual(queue.pending().map(\.id), [kept])
        XCTAssertEqual(queue.result(for: done)?.success, true)
    }

    /// A command left behind while the menu bar app wasn't running must not be applied to the
    /// desk minutes or hours later: `pending()` drops it and deletes the file.
    func testPendingDropsAndDeletesStaleCommands() throws {
        let queue = makeQueue()
        let fresh = try queue.enqueue(.captureSittingPreset)
        let stale = try queue.enqueue(.setPaused(true))

        // Backdate the stale envelope past the cutoff, in place.
        let staleURL = queue.commandFileURL(for: stale)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let old = CommandEnvelope(id: stale,
                                  createdAt: Date().addingTimeInterval(-CommandQueue.staleAfter - 60),
                                  command: .setPaused(true))
        try encoder.encode(old).write(to: staleURL, options: .atomic)

        XCTAssertEqual(queue.pending().map(\.id), [fresh])
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleURL.path),
                       "a stale command should be deleted, not just skipped")
    }

    func testEnqueuePendingCompleteResult() throws {
        let queue = makeQueue()
        XCTAssertEqual(queue.pending(), [])

        let id1 = try queue.enqueue(.captureSittingPreset)
        let id2 = try queue.enqueue(.setCruise(CruiseSlot(standingSeconds: 1200, sittingSeconds: 1200)))

        let pending = queue.pending()
        XCTAssertEqual(Set(pending.map(\.id)), Set([id1, id2]))
        XCTAssertEqual(pending.first(where: { $0.id == id1 })?.command, .captureSittingPreset)
        XCTAssertEqual(pending.first(where: { $0.id == id2 })?.command,
                       .setCruise(CruiseSlot(standingSeconds: 1200, sittingSeconds: 1200)))

        XCTAssertNil(queue.result(for: id1))
        try queue.complete(id1, success: true, message: "done")

        // Completing removes the command from the pending queue.
        XCTAssertEqual(queue.pending().map(\.id), [id2])

        let result = queue.result(for: id1)
        XCTAssertEqual(result?.success, true)
        XCTAssertEqual(result?.message, "done")
    }

    func testPendingIsSortedByCreatedAt() throws {
        let queue = makeQueue()
        for _ in 0..<3 { _ = try queue.enqueue(.setPaused(true)) }
        let dates = queue.pending().map(\.createdAt)
        XCTAssertEqual(dates, dates.sorted())
    }

    func testAllCommandCasesRoundTrip() throws {
        let queue = makeQueue()
        let commands: [DeskCommand] = [
            .captureSittingPreset,
            .captureStandingPreset,
            .setCruise(CruiseSlot(standingSeconds: 300, sittingSeconds: 900)),
            .setCruise(nil),
            .setPaused(true),
            .setPaused(false),
            .reconnect,
        ]
        var ids: [UUID] = []
        for command in commands { ids.append(try queue.enqueue(command)) }
        let pending = queue.pending()
        for (id, command) in zip(ids, commands) {
            XCTAssertEqual(pending.first(where: { $0.id == id })?.command, command)
        }
    }

    func testCompleteWithFailureMessageIsPreserved() throws {
        let queue = makeQueue()
        let id = try queue.enqueue(.captureStandingPreset)
        try queue.complete(id, success: false, message: "desk did not respond")
        let result = queue.result(for: id)
        XCTAssertEqual(result?.success, false)
        XCTAssertEqual(result?.message, "desk did not respond")
    }

    func testResultForUnknownIdIsNil() {
        let queue = makeQueue()
        XCTAssertNil(queue.result(for: UUID()))
    }

    func testPurgeRemovesOldResultsOnly() throws {
        let queue = makeQueue()
        let id = try queue.enqueue(.captureStandingPreset)
        try queue.complete(id, success: false, message: nil)
        XCTAssertNotNil(queue.result(for: id))
        queue.purge(olderThan: 0) // completedAt is always strictly before "now" at purge time
        XCTAssertNil(queue.result(for: id))
    }

    func testPurgeKeepsRecentResults() throws {
        let queue = makeQueue()
        let id = try queue.enqueue(.captureStandingPreset)
        try queue.complete(id, success: true, message: nil)
        queue.purge(olderThan: 3600) // nothing is an hour old yet
        XCTAssertNotNil(queue.result(for: id))
    }
}

final class CommandQueueSendTests: XCTestCase {
    func makeQueue() -> CommandQueue {
        CommandQueue(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("tempo-commands-\(UUID().uuidString)"))
    }

    /// `send` returns the result the menu bar app writes, as soon as it appears.
    func testSendReturnsTheResultOnceCompleted() async throws {
        let queue = makeQueue()
        let executor = Task {
            while queue.pending().isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
            for envelope in queue.pending() {
                try queue.complete(envelope.id, success: true, message: "Done.")
            }
        }
        let result = await queue.send(.setPaused(true), timeout: 5, pollEvery: 0.05)
        try await executor.value
        XCTAssertEqual(result?.success, true)
        XCTAssertEqual(result?.message, "Done.")
        XCTAssertEqual(queue.pending(), [])
    }

    /// With nobody executing, `send` gives up after `timeout` and withdraws the command so it
    /// can't be applied later, after the caller has reported failure.
    func testSendTimesOutAndWithdrawsTheCommand() async {
        let queue = makeQueue()
        let started = Date()
        let result = await queue.send(.captureSittingPreset, timeout: 0.3, pollEvery: 0.05)
        XCTAssertNil(result)
        XCTAssertEqual(queue.pending(), [])
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }
}
