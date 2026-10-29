import XCTest
@testable import DeskpilotKit

final class PostureTimelineTests: XCTestCase {
    let day0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ offset: TimeInterval) -> Date { day0.addingTimeInterval(offset) }
    func ev(_ offset: TimeInterval, _ kind: HistoryEventKind) -> HistoryEvent {
        HistoryEvent(byteOffset: 0, date: at(offset), kind: kind)
    }

    func testSegmentsAwayPresentSittingStandingClippedAndMerged() {
        let from = day0
        let to = at(4 * 3600)
        let events = [
            ev(3600, .presence(present: true)),      // +1h: present, no move yet -> sitting
            ev(7200, .move(toStanding: true)),        // +2h: standing
            ev(9000, .countdown(toStanding: true)),   // +2.5h: still standing - must merge, not split
            ev(10800, .presence(present: false)),     // +3h: away
            ev(18000, .presence(present: true)),      // +5h: outside [from, to], must be ignored
        ]
        let segments = PostureTimeline.segments(events: events, from: from, to: to, standingThresholdInches: nil)
        XCTAssertEqual(segments, [
            PostureSegment(start: from, end: at(3600), state: .away),
            PostureSegment(start: at(3600), end: at(7200), state: .sitting),
            PostureSegment(start: at(7200), end: at(10800), state: .standing),
            PostureSegment(start: at(10800), end: to, state: .away),
        ])
    }

    func testNudgeWithinPresetsStaysSitting() {
        // "HEIGHT 29, MOVE up" within one minute never crossed the standing threshold - the
        // desk still logs MOVE up, so without deriving posture from the preceding HEIGHT entry
        // this would wrongly read as standing (mirrors DayRollup's nudge test).
        let events = [
            ev(0, .presence(present: true)),
            ev(60, .heightChange(inches: 29)),
            ev(60, .move(toStanding: true)),
        ]
        let segments = PostureTimeline.segments(events: events, from: day0, to: at(3600),
                                                 standingThresholdInches: 34)
        XCTAssertEqual(segments, [PostureSegment(start: day0, end: at(3600), state: .sitting)])
    }

    func testTotalsSplitSegmentSpanningMidnightAndCountStandsPerDay() {
        let day1 = day0
        let day2 = day0.addingTimeInterval(86_400)
        let events = [
            ev(0, .presence(present: true)),          // day1 +0h: present, sitting
            ev(3600, .move(toStanding: true)),         // day1 +1h: stands (day1 stand #1)
            // continuous standing spans the midnight boundary with no events in between
            ev(90_000, .move(toStanding: false)),      // day2 +1h: sits (not a stand)
            ev(93_600, .move(toStanding: true)),        // day2 +2h: stands (day2 stand #1)
        ]
        let now = at(100_000) // after the last event, before day2 ends
        let totals = PostureTimeline.totals(events: events, dayStarts: [day1, day2],
                                            standingThresholdInches: nil, now: now)
        XCTAssertEqual(totals.count, 2)

        XCTAssertEqual(totals[0].day, day1)
        XCTAssertEqual(totals[0].sitting, 3600, accuracy: 1)
        XCTAssertEqual(totals[0].standing, 82_800, accuracy: 1) // 3600..<86400
        XCTAssertEqual(totals[0].away, 0, accuracy: 1)
        XCTAssertEqual(totals[0].stands, 1)

        XCTAssertEqual(totals[1].day, day2)
        // standing continues from day2's start (86400) through 90000, then again 93600..now
        XCTAssertEqual(totals[1].standing, 3600 + 6400, accuracy: 1)
        XCTAssertEqual(totals[1].sitting, 3600, accuracy: 1)
        XCTAssertEqual(totals[1].away, 0, accuracy: 1)
        XCTAssertEqual(totals[1].stands, 1)
    }

    func testTotalsClipToNowForAnUnfinishedDay() {
        let events = [ev(0, .presence(present: true)), ev(60, .move(toStanding: true))]
        let now = at(1800) // half an hour into day1; day1 is not over yet
        let totals = PostureTimeline.totals(events: events, dayStarts: [day0],
                                            standingThresholdInches: nil, now: now)
        XCTAssertEqual(totals[0].standing + totals[0].sitting + totals[0].away, 1800, accuracy: 1)
    }

    func testSegmentsReturnsEmptyWhenToIsNotAfterFrom() {
        XCTAssertEqual(PostureTimeline.segments(events: [], from: day0, to: day0, standingThresholdInches: nil), [])
    }
}
