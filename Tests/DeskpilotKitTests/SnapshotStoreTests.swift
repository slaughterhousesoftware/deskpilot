import XCTest
@testable import DeskpilotKit

final class SnapshotStoreTests: XCTestCase {
    func testWriteThenReadRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tempo-snapshot-\(UUID().uuidString)")
        let store = SnapshotStore(directory: dir)
        XCTAssertNil(store.read())

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snap = DeskSnapshot(updatedAt: now, connected: true, heightTenths: 411, isMoving: false,
                                isPresent: true, isStanding: true, atDeskSeconds: 3600, standsToday: 4,
                                nextMove: NextMove(at: now.addingTimeInterval(600), toStanding: false),
                                paused: false, cruise: CruiseSlot(standingSeconds: 1200, sittingSeconds: 1200),
                                sittingHeightTenths: 266, standingHeightTenths: 411)
        try store.write(snap)
        XCTAssertEqual(store.read(), snap)
    }

    func testDataUInt32Helpers() {
        XCTAssertEqual(Data([0x0B, 0x01, 0x00, 0x80]).uint32LE, 0x8000_010B)
        XCTAssertEqual(Data(uint32LE: 0x0001_0005), Data([0x05, 0x00, 0x01, 0x00]))
        XCTAssertNil(Data([1, 2]).uint32LE)
    }
}
