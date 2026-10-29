import XCTest
@testable import DeskpilotKit

final class CruiseSlotTests: XCTestCase {
    func testDecodesObservedSlots() {
        let custom = CruiseSlot(raw: 0x04B0_04B0)
        XCTAssertEqual(custom.standingSeconds, 1200)
        XCTAssertEqual(custom.sittingSeconds, 1200)
        XCTAssertEqual(custom.cycleSeconds, 2400)
        XCTAssertEqual(custom.standingMinutesPerHour, 30)

        let tenPerHour = CruiseSlot(raw: 0x0258_0BB8)
        XCTAssertEqual(tenPerHour.standingSeconds, 600)
        XCTAssertEqual(tenPerHour.sittingSeconds, 3000)
        XCTAssertEqual(tenPerHour.standingMinutesPerHour, 10)
    }

    func testEncodesLikePhoneApp() throws {
        // App: standing 20 min, cycle 60 min -> (1200 << 16) | 2400
        let slot = try CruiseSlot.make(standingMinutes: 20, cycleMinutes: 60)
        XCTAssertEqual(slot.raw, 0x04B0_0960)
        XCTAssertEqual(CruiseSlot(raw: slot.raw), slot)
    }

    func testRejectsInvalidTiming() {
        XCTAssertThrowsError(try CruiseSlot.make(standingMinutes: 0, cycleMinutes: 30))
        XCTAssertThrowsError(try CruiseSlot.make(standingMinutes: 30, cycleMinutes: 30))
        XCTAssertThrowsError(try CruiseSlot.make(standingMinutes: 10, cycleMinutes: 5))
        XCTAssertThrowsError(try CruiseSlot.make(standingMinutes: 10, cycleMinutes: 241))
    }

    func testPresetsMirrorTheApp() {
        let perHour = CruiseSlot.presets.map(\.standingMinutesPerHour)
        XCTAssertEqual(perHour, [5, 10, 15, 20, 22, 30, 40])
        XCTAssertTrue(CruiseSlot.presets.allSatisfy { $0.cycleSeconds == 3600 })
    }
}
