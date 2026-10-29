import XCTest
@testable import DeskpilotKit

final class TypicalDayStartTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto")!
        return calendar
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    /// A day: away from the boundary until `arrival`, then an hour sitting.
    private func day(_ day: Int, arrival hour: Int, _ minute: Int = 0) -> [PostureSegment] {
        let arrival = date(day, hour, minute)
        return [PostureSegment(start: date(day, 4), end: arrival, state: .away),
                PostureSegment(start: arrival, end: arrival.addingTimeInterval(3600), state: .sitting)]
    }

    func testMedianFirstArrivalAsAnHour() {
        let segments = day(20, arrival: 8, 40) + day(21, arrival: 9, 10) + day(22, arrival: 9, 5)
            + day(23, arrival: 7, 55) + day(26, arrival: 9, 20)
        XCTAssertEqual(TypicalDayStart.hour(segments: segments, middleOfNightHour: 4, calendar: calendar), 9)
    }

    func testTooFewDaysGivesNothing() {
        let segments = day(20, arrival: 8) + day(21, arrival: 9)
        XCTAssertNil(TypicalDayStart.hour(segments: segments, middleOfNightHour: 4, calendar: calendar))
    }

    func testABlipIsNotTheStartOfTheDay() {
        let blip = PostureSegment(start: date(20, 5), end: date(20, 5).addingTimeInterval(20), state: .sitting)
        let segments = [blip] + day(20, arrival: 8, 30) + day(21, arrival: 8, 15) + day(22, arrival: 8, 45)
        XCTAssertEqual(TypicalDayStart.hour(segments: segments, middleOfNightHour: 4, calendar: calendar), 8)
    }

    func testOnlyTheFirstArrivalOfEachDayCounts() {
        let segments = day(20, arrival: 8) + [PostureSegment(start: date(20, 14), end: date(20, 15), state: .standing)]
            + day(21, arrival: 8, 30) + day(22, arrival: 8, 20)
        XCTAssertEqual(TypicalDayStart.hour(segments: segments, middleOfNightHour: 4, calendar: calendar), 8)
    }
}
