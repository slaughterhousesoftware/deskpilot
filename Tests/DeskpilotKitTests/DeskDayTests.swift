import XCTest
@testable import DeskpilotKit

final class DeskDayTests: XCTestCase {
    /// 4:00 AM in a fixed zone, so minute offsets read as clock times: 22 is 4:22 AM, 420 is 11 AM.
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private let base = Date(timeIntervalSince1970: 1_800_000_000 - 4 * 3600)
    /// A segment from minute `from` to `to` after `base`.
    private func seg(_ state: PostureState, _ from: Double, _ to: Double) -> PostureSegment {
        PostureSegment(start: base.addingTimeInterval(from * 60), end: base.addingTimeInterval(to * 60), state: state)
    }
    private func firstArrival(_ segments: [PostureSegment]) -> Date? {
        segments.first { $0.state != .away }?.start
    }
    private func cleaned(_ day: [PostureSegment], openEnded: Bool = false,
                         night: NightWindow = .around(middleOfNightHour: 4)) -> [PostureSegment] {
        DeskDay.withoutStrays(day, openEnded: openEnded, night: night, calendar: calendar)
    }

    func testANightBlipDoesNotStartTheDay() {
        // 4:22 AM for eight minutes, then nothing until 11:00.
        let day = [seg(.away, 0, 22), seg(.sitting, 22, 30), seg(.away, 30, 420), seg(.sitting, 420, 600), seg(.away, 600, 700)]
        let result = cleaned(day)
        XCTAssertEqual(firstArrival(result), base.addingTimeInterval(420 * 60))
        XCTAssertEqual(result.first, seg(.away, 0, 420))
    }

    func testAStringOfNightBlipsGoes() {
        // 4:00, 5:19 and 6:30, a few minutes each; the day starts at 10:40.
        let day = [seg(.sitting, 0, 8), seg(.away, 8, 79), seg(.sitting, 79, 87), seg(.away, 87, 150),
                   seg(.sitting, 150, 156), seg(.away, 156, 400), seg(.standing, 400, 500)]
        XCTAssertEqual(firstArrival(cleaned(day)), base.addingTimeInterval(400 * 60))
    }

    func testAShortVisitMidDayStays() {
        let day = [seg(.sitting, 300, 420), seg(.away, 420, 660), seg(.sitting, 660, 667), seg(.away, 667, 750),
                   seg(.sitting, 750, 900)]
        XCTAssertEqual(cleaned(day), day)
    }

    func testAShortEveningVisitStays() {
        // Done at 7 PM, back for six minutes at 9 PM: someone using their computer, not the sensor.
        let day = [seg(.sitting, 300, 900), seg(.away, 900, 1020), seg(.sitting, 1020, 1026), seg(.away, 1026, 1200)]
        XCTAssertEqual(cleaned(day), day)
    }

    func testAShortVisitInTheSmallHoursDoesNotStretchAFinishedDay() {
        // Done at 7 PM; six minutes at 3 AM is the sensor.
        let day = [seg(.sitting, 300, 900), seg(.away, 900, 1380), seg(.sitting, 1380, 1386), seg(.away, 1386, 1440)]
        XCTAssertEqual(cleaned(day).last(where: { $0.state != .away })?.end, base.addingTimeInterval(900 * 60))
    }

    func testANightOwlKeepsTheirSmallHours() {
        // Someone who usually works 8 PM to 3 AM: their night is 6 AM to 5 PM, and a short
        // 4 AM spell is theirs.
        let night = NightWindow.usual(arrivals: [20 * 60, 20 * 60 + 30, 19 * 60 + 45],
                                      departures: [27 * 60, 26 * 60 + 30, 27 * 60 + 15], middleOfNightHour: 4)!
        XCTAssertEqual(night.start, 6 * 60); XCTAssertEqual(night.end, 17 * 60)
        let day = [seg(.sitting, 960, 1380), seg(.away, 1380, 1440), seg(.sitting, 1440, 1446), seg(.away, 1446, 1500)]
        XCTAssertEqual(cleaned(day, night: night), day)
    }

    func testTodaysLatestVisitIsNeverAStray() {
        // Back from a long lunch five minutes ago.
        let day = [seg(.sitting, 0, 300), seg(.away, 300, 450), seg(.sitting, 450, 455)]
        XCTAssertEqual(cleaned(day, openEnded: true), day)
    }

    func testCloseShortSpellsCountTogether() {
        // Two eight-minute spells twenty minutes apart at 4 AM: sixteen minutes, a real start.
        let day = [seg(.sitting, 0, 8), seg(.away, 8, 28), seg(.sitting, 28, 36), seg(.away, 36, 200), seg(.sitting, 200, 400)]
        XCTAssertEqual(firstArrival(cleaned(day)), base)
    }

    func testADayOfOnlyShortSpellsIsLeftAlone() {
        let day = [seg(.sitting, 0, 6)]
        XCTAssertEqual(cleaned(day), day)
    }

    // MARK: NightWindow

    func testTheDefaultNightIsThreeHoursEitherSideOfTheMiddle() {
        let night = NightWindow.around(middleOfNightHour: 4)
        XCTAssertEqual(night.start, 60); XCTAssertEqual(night.end, 7 * 60)
        XCTAssertTrue(night.contains(base.addingTimeInterval(22 * 60), calendar: calendar))   // 4:22
        XCTAssertFalse(night.contains(base.addingTimeInterval(1020 * 60), calendar: calendar)) // 21:00
    }

    func testTheUsualNightRunsFromThreeHoursAfterLeavingToThreeHoursBeforeArriving() {
        // 9 to 6, give or take: night is 9 PM to 6 AM.
        let night = NightWindow.usual(arrivals: [9 * 60, 9 * 60 + 20, 8 * 60 + 40, 9 * 60],
                                      departures: [18 * 60, 17 * 60 + 40, 18 * 60 + 30, 18 * 60], middleOfNightHour: 4)!
        XCTAssertEqual(night.start, 21 * 60); XCTAssertEqual(night.end, 6 * 60)
        XCTAssertTrue(night.contains(base, calendar: calendar))                                  // 4:00
        XCTAssertTrue(night.contains(base.addingTimeInterval(1050 * 60), calendar: calendar))   // 21:30
        XCTAssertFalse(night.contains(base.addingTimeInterval(990 * 60), calendar: calendar))   // 20:30
        XCTAssertFalse(night.contains(base.addingTimeInterval(180 * 60), calendar: calendar))   // 7:00
    }

    func testADayThatLeavesNoNightFallsBack() {
        XCTAssertNil(NightWindow.usual(arrivals: [5 * 60], departures: [26 * 60], middleOfNightHour: 4))
    }
}
