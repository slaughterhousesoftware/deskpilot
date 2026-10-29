import XCTest
@testable import DeskpilotKit

final class HistoryStoreTests: XCTestCase {
    func testSyncAfterDeskResetPreservesOlderDaysAndClosesUnknownGap() throws {
        let store = tempStore()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let old = HistoryDocument(writtenAt: start.addingTimeInterval(3600),
                                  standingThresholdInches: 34, middleOfNightHour: 4,
                                  events: [HistoryEvent(byteOffset: 0, date: start, kind: .presence(present: true))])
        try store.write(old)
        let next = start.addingTimeInterval(86400)
        let incoming = HistoryDocument(writtenAt: next.addingTimeInterval(3600),
                                       standingThresholdInches: 34, middleOfNightHour: 4,
                                       events: [HistoryEvent(byteOffset: 0, date: next, kind: .presence(present: true))])
        try store.mergeAndWrite(incoming)
        let recovered = try XCTUnwrap(store.read())
        XCTAssertEqual(recovered.events, old.events + [
            HistoryEvent(byteOffset: -1, date: old.writtenAt, kind: .presence(present: false))
        ] + incoming.events)
        let segments = PostureTimeline.segments(events: recovered.events, from: start, to: next,
                                               standingThresholdInches: 34)
        XCTAssertEqual(segments.last?.state, .away)
        try store.mergeAndWrite(incoming)
        XCTAssertEqual(store.read(), recovered)
        let backups = try FileManager.default.contentsOfDirectory(
            at: store.fileURL.deletingLastPathComponent().appendingPathComponent("history-backups"),
            includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(HistoryDocument.self, from: Data(contentsOf: backups[0])), old)
    }

    func testReanchoredOverlappingSyncDoesNotDuplicateFirstEvent() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let saved = HistoryDocument(writtenAt: start.addingTimeInterval(1000),
                                    standingThresholdInches: 34, middleOfNightHour: 4,
                                    events: [HistoryEvent(byteOffset: 0, date: start.addingTimeInterval(-86400), kind: .presence(present: false)),
                                             HistoryEvent(byteOffset: 2, date: start, kind: .presence(present: true))])
        let incoming = HistoryDocument(writtenAt: start.addingTimeInterval(1100),
                                       standingThresholdInches: 34, middleOfNightHour: 4,
                                       events: [HistoryEvent(byteOffset: 2, date: start.addingTimeInterval(20), kind: .presence(present: true))])
        XCTAssertEqual(HistoryStore.merging(saved: saved, incoming: incoming).events,
                       [saved.events[0]] + incoming.events)
    }

    func testEmptySyncPreservesArchiveAndCorruptFileCannotBeOverwritten() throws {
        let store = tempStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let saved = HistoryDocument(writtenAt: now, standingThresholdInches: 34, middleOfNightHour: 4,
                                    events: [HistoryEvent(byteOffset: 0, date: now, kind: .presence(present: true))])
        try store.write(saved)
        try store.mergeAndWrite(HistoryDocument(writtenAt: now.addingTimeInterval(60),
                                               standingThresholdInches: nil, middleOfNightHour: 4, events: []))
        XCTAssertEqual(store.read(), saved)
        let damaged = Data("invalid history".utf8)
        try damaged.write(to: store.fileURL)
        XCTAssertThrowsError(try store.mergeAndWrite(saved))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), damaged)
    }

    func tempStore() -> HistoryStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tempo-history-\(UUID().uuidString)")
        return HistoryStore(directory: dir)
    }

    func testWriteThenReadRoundTripsEveryEventKind() throws {
        let store = tempStore()
        XCTAssertNil(store.read())

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let events = [
            HistoryEvent(byteOffset: 0, date: now, kind: .presence(present: true)),
            HistoryEvent(byteOffset: 2, date: now.addingTimeInterval(60), kind: .presence(present: false)),
            HistoryEvent(byteOffset: 4, date: now.addingTimeInterval(120), kind: .countdown(toStanding: true)),
            HistoryEvent(byteOffset: 6, date: now.addingTimeInterval(180), kind: .countdown(toStanding: false)),
            HistoryEvent(byteOffset: 8, date: now.addingTimeInterval(240), kind: .move(toStanding: true)),
            HistoryEvent(byteOffset: 10, date: now.addingTimeInterval(300), kind: .move(toStanding: false)),
            HistoryEvent(byteOffset: 12, date: now.addingTimeInterval(360), kind: .heightChange(inches: 29)),
            HistoryEvent(byteOffset: 14, date: now.addingTimeInterval(420), kind: .userChange(user: 3)),
            HistoryEvent(byteOffset: 16, date: now.addingTimeInterval(480), kind: .nop(raw: 0xFF)),
        ]
        let doc = HistoryDocument(writtenAt: now, standingThresholdInches: 34, middleOfNightHour: 4, events: events)
        try store.write(doc)
        XCTAssertEqual(store.read(), doc)
    }

    func testStandingThresholdInchesRoundTripsNil() throws {
        let store = tempStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let doc = HistoryDocument(writtenAt: now, standingThresholdInches: nil, middleOfNightHour: 4, events: [])
        try store.write(doc)
        XCTAssertEqual(store.read(), doc)
    }

    func testWriteOverwritesPreviousDocument() throws {
        let store = tempStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try store.write(HistoryDocument(writtenAt: now, standingThresholdInches: nil, middleOfNightHour: 4, events: []))
        let updated = HistoryDocument(writtenAt: now.addingTimeInterval(60), standingThresholdInches: 30,
                                      middleOfNightHour: 4,
                                      events: [HistoryEvent(byteOffset: 0, date: now, kind: .presence(present: true))])
        try store.write(updated)
        XCTAssertEqual(store.read(), updated)
    }
}
