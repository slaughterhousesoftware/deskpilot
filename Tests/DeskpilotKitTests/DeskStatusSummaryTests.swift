import XCTest
@testable import DeskpilotKit

final class DeskStatusSummaryTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func snapshot(connected: Bool = true, present: Bool = true, standing: Bool? = true,
                  nextMove: NextMove? = nil, paused: Bool = false, age: TimeInterval = 0) -> DeskSnapshot {
        DeskSnapshot(updatedAt: now.addingTimeInterval(-age), connected: connected, heightTenths: 411,
                     isMoving: false, isPresent: present, isStanding: standing,
                     atDeskSeconds: 3 * 3600 + 20 * 60, standsToday: 6, nextMove: nextMove, paused: paused,
                     cruise: CruiseSlot(standingSeconds: 1200, sittingSeconds: 1200),
                     sittingHeightTenths: 266, standingHeightTenths: 411)
    }

    func testStandingWithACountdown() {
        let next = NextMove(at: now.addingTimeInterval(11 * 60 + DayRollup.beepSeconds), toStanding: false)
        XCTAssertEqual(DeskStatusSummary.sentence(snapshot(nextMove: next), now: now),
                       "You're standing at 41.1\". 3h 20m at the desk and 6 stands today. Next sit in 11m.")
    }

    func testSittingWithAnOverdueMove() {
        let next = NextMove(at: now.addingTimeInterval(-120), toStanding: true)
        XCTAssertEqual(DeskStatusSummary.sentence(snapshot(standing: false, nextMove: next), now: now),
                       "You're sitting at 41.1\". 3h 20m at the desk and 6 stands today. Next stand any moment.")
    }

    func testPausedAndCruiseOff() {
        XCTAssertEqual(DeskStatusSummary.sentence(snapshot(paused: true), now: now),
                       "You're standing at 41.1\". 3h 20m at the desk and 6 stands today. Cruise control is paused.")
        let off = DeskSnapshot(updatedAt: now, connected: true, heightTenths: 266, isMoving: false, isPresent: true,
                               isStanding: false, atDeskSeconds: 60, standsToday: 0, nextMove: nil, paused: false,
                               cruise: nil, sittingHeightTenths: 266, standingHeightTenths: 411)
        XCTAssertEqual(DeskStatusSummary.sentence(off, now: now),
                       "You're sitting at 26.6\". 1m at the desk and 0 stands today. Cruise control is off.")
    }

    func testAway() {
        XCTAssertEqual(DeskStatusSummary.sentence(snapshot(present: false), now: now),
                       "You're away from the desk. 3h 20m at the desk and 6 stands today.")
    }

    func testDisconnectedMissingAndStale() {
        XCTAssertEqual(DeskStatusSummary.sentence(nil, now: now), "Deskpilot isn't connected to the desk.")
        XCTAssertEqual(DeskStatusSummary.sentence(snapshot(connected: false), now: now),
                       "Deskpilot isn't connected to the desk.")
        XCTAssertEqual(DeskStatusSummary.sentence(snapshot(age: DeskSnapshot.staleAfter + 1), now: now),
                       "Deskpilot isn't connected to the desk.")
    }
}
