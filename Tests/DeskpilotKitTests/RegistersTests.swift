import XCTest
@testable import DeskpilotKit

final class RegistersTests: XCTestCase {
    func testStatusWordDecodesHeightAndMotion() {
        let idle = StatusWord(raw: 0x0000_010B)
        XCTAssertEqual(idle.heightTenths, 267)
        XCTAssertEqual(idle.heightInches, 26.7, accuracy: 0.001)
        XCTAssertFalse(idle.isMoving)

        let moving = StatusWord(raw: 0x8000_0126)
        XCTAssertEqual(moving.heightTenths, 294)
        XCTAssertTrue(moving.isMoving)
    }

    func testUserFlagsBitOrderMatchesPhoneApp() {
        let flags = UserFlags(rawValue: 0x1E3)
        XCTAssertTrue(flags.contains(.sitPresetSet))
        XCTAssertTrue(flags.contains(.standingPresetSet))
        XCTAssertFalse(flags.contains(.paused))
        XCTAssertFalse(flags.contains(.pulseOnly))
        XCTAssertTrue(flags.contains(.userEnabled))
        XCTAssertTrue(flags.contains(.userSelected))
        XCTAssertTrue(flags.contains(.historyLogging))
        XCTAssertEqual(flags.union(.paused).rawValue, 0x1E7)
    }

    func testFirmwareVersionFormatsBytes() {
        XCTAssertEqual(FirmwareVersion(raw: 0x0001_0005).description, "1.0.5")
        XCTAssertEqual(FirmwareVersion(raw: 0x0002_0A01).description, "2.10.1")
    }

    func testDeskClockRoundTrips() {
        let clock = DeskClock(raw: 0x000C_0C2B)
        XCTAssertEqual(clock.hour, 12)
        XCTAssertEqual(clock.minute, 12)
        XCTAssertEqual(clock.second, 43)
        XCTAssertEqual(clock.raw, 0x000C_0C2B)

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let date = cal.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 17, minute: 5, second: 9))!
        let fromDate = DeskClock(date: date, calendar: cal)
        XCTAssertEqual(fromDate.raw, 0x0011_0509)
    }

    func testAddressHelpers() {
        XCTAssertEqual(Register.userBase(0), 4096)
        XCTAssertEqual(Register.userBase(1), 8192)
        XCTAssertEqual(Register.cruiseSlotAddress(user: 0, slot: 1), 4624)
        XCTAssertEqual(Register.cruiseSlotAddress(user: 1, slot: 4), 8192 + 512 + 64)
        XCTAssertEqual(Register.userBase(0) + Register.UserOffset.standingHeight, 4112)
    }
}
