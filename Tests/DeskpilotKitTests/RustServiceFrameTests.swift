import Foundation
import XCTest
@testable import DeskpilotKit

final class RustServiceFrameTests: XCTestCase {
    func testDecodesFrameProducedByActualRustDaemon() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "rust-ui-frame", withExtension: "json", subdirectory: "Fixtures"))
        let frame = try RustServiceFrame.decode(Data(contentsOf: url))
        XCTAssertEqual(frame.protocolVersion, 1)
        XCTAssertEqual(frame.state.deskState.status, .connected)
        XCTAssertEqual(frame.state.deskState.settings?.sittingHeightTenths, 266)
        XCTAssertEqual(frame.state.deskState.today?.isStanding, false)
        XCTAssertFalse(frame.todaySegments.isEmpty)
        XCTAssertEqual(frame.snapshot.heightTenths, frame.state.heightTenths)
        XCTAssertNotNil(frame.lastSyncedAt)
    }

    func testRejectsUnsupportedProtocolAndAcceptsDisconnectedFrame() throws {
        let json = """
        {"protocolVersion":1,"state":{"status":"unauthorized","reconnectingInBackground":false,"isMoving":false,"historyRevision":0},"snapshot":{"updatedAt":"2026-10-14T15:00:00Z","connected":false,"isMoving":false,"isPresent":false,"atDeskSeconds":0,"standsToday":0,"paused":false},"todaySegments":[],"lastSyncedAt":null}
        """
        let frame = try RustServiceFrame.decode(Data(json.utf8))
        XCTAssertEqual(frame.state.deskState.status, .unauthorized)
        XCTAssertEqual(frame.state.deskState.updatedAt, .distantPast)
        XCTAssertNil(frame.savedToday)
        XCTAssertThrowsError(try RustServiceFrame.decode(Data(json.replacingOccurrences(of: "\"protocolVersion\":1", with: "\"protocolVersion\":2").utf8)))
    }

    func testDecodesCancelledMoveAndPredictedHeight() throws {
        let json = """
        {"protocolVersion":1,"state":{"status":"connected","reconnectingInBackground":false,"heightTenths":405,"isMoving":false,"predictedHeightTenths":411,"today":{"atDeskSeconds":10,"stands":1,"isPresent":true,"nextMove":{"at":"2026-10-29T16:00:10Z","toStanding":false},"cancelledMove":{"at":"2026-10-29T15:40:20Z","toStanding":false,"reason":"wavedOff"}},"updatedAt":"2026-10-29T15:40:30Z","historyRevision":3},"snapshot":{"updatedAt":"2026-10-29T15:40:30Z","connected":true,"isMoving":false,"isPresent":true,"atDeskSeconds":10,"standsToday":1,"paused":false},"todaySegments":[]}
        """
        let frame = try RustServiceFrame.decode(Data(json.utf8))
        let state = frame.state.deskState
        XCTAssertEqual(state.predictedHeightTenths, 411)
        let cancelled = try XCTUnwrap(state.today?.cancelledMove)
        XCTAssertEqual(cancelled.reason, .wavedOff)
        XCTAssertFalse(cancelled.toStanding)
        XCTAssertTrue(cancelled.isShowing(now: cancelled.at.addingTimeInterval(CancelledMove.displaySeconds - 1)))
        XCTAssertFalse(cancelled.isShowing(now: cancelled.at.addingTimeInterval(CancelledMove.displaySeconds)))
        XCTAssertEqual(state.today?.nextMove?.toStanding, false)
    }
}
