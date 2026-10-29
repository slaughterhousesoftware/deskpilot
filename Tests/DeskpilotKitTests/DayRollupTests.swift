import XCTest
@testable import DeskpilotKit

final class DayRollupTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func minutesAgo(_ m: Double) -> Date { now.addingTimeInterval(-m * 60) }
    func ev(_ m: Double, _ kind: HistoryEventKind) -> HistoryEvent {
        HistoryEvent(byteOffset: 0, date: minutesAgo(m), kind: kind)
    }
    let cruise = CruiseSlot(standingSeconds: 20 * 60, sittingSeconds: 20 * 60)

    func testDayStartUsesMiddleOfNightHour() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let afternoon = cal.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 15))!
        XCTAssertEqual(DayRollup.dayStart(now: afternoon, middleOfNightHour: 4, calendar: cal),
                       cal.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 4))!)
        let earlyMorning = cal.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 2))!
        XCTAssertEqual(DayRollup.dayStart(now: earlyMorning, middleOfNightHour: 4, calendar: cal),
                       cal.date(from: DateComponents(year: 2026, month: 9, day: 3, hour: 4))!)
    }

    func testCountsStandsAndSumsPresenceSinceDayStart() {
        let events = [
            ev(600, .move(toStanding: true)),      // before day start, ignored for stands
            ev(400, .move(toStanding: false)),      // also before day start: sits back down,
                                                     // so the stand at -89 below is a genuine
                                                     // transition, not a re-affirmation
            ev(120, .presence(present: true)),
            ev(90, .countdown(toStanding: true)),
            ev(89, .move(toStanding: true)),
            ev(69, .move(toStanding: false)),
            ev(30, .presence(present: false)),
            ev(10, .presence(present: true)),
        ]
        let stats = DayRollup.compute(events: events, now: now, dayStart: minutesAgo(300),
                                      cruise: cruise, paused: false)
        XCTAssertEqual(stats.stands, 1)
        XCTAssertEqual(stats.isStanding, false)
        XCTAssertTrue(stats.isPresent)
        // present 120->30 (90 min) plus 10->now (10 min)
        XCTAssertEqual(stats.atDeskSeconds, 100 * 60, accuracy: 1)
        // last move was to sitting 69 min ago; the desk held its timer through the absence
        // -37..-10 (logged at -30, `absenceLogLagSeconds` late), so sitting 20 min -> next
        // stand at -69 + 20 + 27 min (+ moveLeadSeconds): long overdue, which the UI presents
        // as waiting for the desk.
        XCTAssertEqual(stats.nextMove,
                       NextMove(at: minutesAgo(22).addingTimeInterval(DayRollup.moveLeadSeconds),
                                toStanding: true))
    }

    func testPresenceIntervalIsClippedToDayStart() {
        let events = [ev(500, .presence(present: true))]
        let stats = DayRollup.compute(events: events, now: now, dayStart: minutesAgo(60),
                                      cruise: cruise, paused: false)
        XCTAssertEqual(stats.atDeskSeconds, 60 * 60, accuracy: 1)
        XCTAssertNil(stats.nextMove) // never moved, nothing to anchor to
    }

    func testMoveImpliesPresence() {
        let events = [ev(40, .presence(present: false)), ev(5, .move(toStanding: true))]
        let stats = DayRollup.compute(events: events, now: now, dayStart: minutesAgo(60),
                                      cruise: cruise, paused: false)
        XCTAssertTrue(stats.isPresent)
        // No presence info before the "absent" event, so the rollup starts absent; only the 5 min since the move count.
        XCTAssertEqual(stats.atDeskSeconds, 5 * 60, accuracy: 1)
    }

    func testNudgeWithinPresetsDoesNotCountAsStand() {
        // Observed live: "HEIGHT 29, MOVE up, HEIGHT 26, MOVE down" within one minute - a
        // paddle nudge that never reached standing height. The desk still logs MOVE up/down
        // with the raise bit set, so without deriving posture from the preceding HEIGHT
        // entry this would wrongly count as a stand.
        let events = [
            ev(5, .heightChange(inches: 29)),
            ev(5, .move(toStanding: true)),
            ev(4, .heightChange(inches: 26)),
            ev(4, .move(toStanding: false)),
        ]
        let stats = DayRollup.compute(events: events, now: now, dayStart: minutesAgo(60),
                                      cruise: cruise, paused: false, standingThresholdInches: 34)
        XCTAssertEqual(stats.stands, 0)
        XCTAssertEqual(stats.isStanding, false)
    }

    func testRealStandDerivedFromHeightCountsOnce() {
        let events = [
            ev(3, .heightChange(inches: 41)),
            ev(3, .move(toStanding: true)),
        ]
        let stats = DayRollup.compute(events: events, now: now, dayStart: minutesAgo(60),
                                      cruise: cruise, paused: false, standingThresholdInches: 34)
        XCTAssertEqual(stats.stands, 1)
        XCTAssertEqual(stats.isStanding, true)
    }

    func testConsecutiveMovesToTheSamePostureCountOnce() {
        // The desk occasionally logs a duplicate MOVE for the same transition (no opposite
        // move in between); only the first should count as a stand.
        let events = [
            ev(10, .move(toStanding: true)),
            ev(9, .move(toStanding: true)),
        ]
        let stats = DayRollup.compute(events: events, now: now, dayStart: minutesAgo(60),
                                      cruise: cruise, paused: false)
        XCTAssertEqual(stats.stands, 1)
        XCTAssertEqual(stats.isStanding, true)
    }

    func testWithoutThresholdPostureMatchesRaiseBit() {
        // No `standingThresholdInches` given (e.g. before presets are known): a HEIGHT entry
        // immediately before a MOVE must not suppress the count - the raise bit alone decides.
        let events = [
            ev(5, .heightChange(inches: 29)),
            ev(5, .move(toStanding: true)),
        ]
        let stats = DayRollup.compute(events: events, now: now, dayStart: minutesAgo(60),
                                      cruise: cruise, paused: false)
        XCTAssertEqual(stats.stands, 1)
        XCTAssertEqual(stats.isStanding, true)
    }

    func testStandingAcrossDayBoundaryIsNotCountedAgain() {
        // The desk was already standing when today started (a move to standing before
        // `dayStart`, with no sit in between). A move that merely re-affirms that same
        // posture just after the boundary must not count as a fresh stand.
        let dayStart = minutesAgo(600)
        let events = [
            ev(620, .move(toStanding: true)),  // standing since before day start
            ev(500, .move(toStanding: true)),  // re-affirms the same posture just after the
                                                // boundary -> not a transition
            ev(300, .move(toStanding: false)), // sits
            ev(100, .move(toStanding: true)),  // now a genuine stand
        ]
        let stats = DayRollup.compute(events: events, now: now, dayStart: dayStart,
                                      cruise: cruise, paused: false)
        XCTAssertEqual(stats.stands, 1)
        XCTAssertEqual(stats.isStanding, true)
    }

    func testAbsenceHoldsTheTimer() {
        // Field data 2026-09-11: sat 12:41, away 13:04-13:12, and the stand due at 13:21
        // came at 13:33 - the desk holds its interval timer while it doesn't see you.
        let events = [
            ev(40, .move(toStanding: true)),   // stood, well before the absence
            ev(30, .presence(present: false)), // then left
            ev(10, .presence(present: true)),  // and came back
        ]
        let stats = DayRollup.compute(events: events, now: now, dayStart: minutesAgo(60),
                                      cruise: cruise, paused: false)
        // -40 + 20 min standing + the 27 min hold (from -37: the absence is logged
        // `absenceLogLagSeconds` late) = 7 min from now (+ moveLeadSeconds).
        XCTAssertEqual(stats.nextMove,
                       NextMove(at: minutesAgo(-7).addingTimeInterval(DayRollup.moveLeadSeconds), toStanding: false))
    }

    func testTheTimerRestartsAtTheDayBoundary() {
        // Every overnight cycle on record with no visit after the boundary moved one full
        // interval after the morning's return (sits 39-41 min on 40, stands 18-20 on 20):
        // the desk starts its interval afresh each day rather than holding yesterday's.
        let events = [
            ev(600, .move(toStanding: false)),  // sat last night
            ev(580, .presence(present: true)),
            ev(560, .presence(present: false)), // 20 min of it counted, then gone
            ev(10, .presence(present: true)),   // back this morning
        ]
        let stats = DayRollup.compute(events: events, now: now, dayStart: minutesAgo(300),
                                      cruise: cruise, paused: false)
        XCTAssertEqual(stats.nextMove,
                       NextMove(at: minutesAgo(10).addingTimeInterval(20 * 60 + DayRollup.moveLeadSeconds),
                                toStanding: true))
    }

    func testPresentAcrossTheDayBoundaryCountsFromTheBoundary() {
        let events = [ev(90, .move(toStanding: false))]
        let stats = DayRollup.compute(events: events, now: now, dayStart: minutesAgo(15),
                                      cruise: cruise, paused: false)
        XCTAssertEqual(stats.nextMove,
                       NextMove(at: minutesAgo(15).addingTimeInterval(20 * 60 + DayRollup.moveLeadSeconds),
                                toStanding: true))
    }

    func testAbsenceIsLoggedLateSoTheHoldStartsEarlier() {
        // The desk writes "not present" about `absenceLogLagSeconds` after the user leaves,
        // and its timer stopped when they did.
        let events = [
            ev(40, .move(toStanding: true)),
            ev(30, .presence(present: false)), // left at -37
            ev(10, .presence(present: true)),
        ]
        let stats = DayRollup.compute(events: events, now: now, dayStart: minutesAgo(60),
                                      cruise: cruise, paused: false)
        XCTAssertEqual(stats.nextMove,
                       NextMove(at: now.addingTimeInterval(DayRollup.absenceLogLagSeconds + DayRollup.moveLeadSeconds),
                                toStanding: false))
    }

    func testReturnAfterAQuietDayIsNotOverdue() {
        // 2026-09-26, the evening the menu bar sat on "↑…": a 40/20 slot, a sit at 20:48 the
        // night before, eight-minute visits (the absence lag, mostly) overnight and in the
        // afternoon, back at 21:07. Holding yesterday's minutes put the stand at 20:58 -
        // overdue on arrival.
        let iso = ISO8601DateFormatter()
        func at(_ s: String, _ kind: HistoryEventKind) -> HistoryEvent {
            HistoryEvent(byteOffset: 0, date: iso.date(from: s)!, kind: kind)
        }
        let events = [
            at("2026-09-26T00:48:34Z", .heightChange(inches: 26)),
            at("2026-09-26T00:48:34Z", .move(toStanding: false)),
            at("2026-09-26T00:53:34Z", .presence(present: true)),
            at("2026-09-26T01:03:34Z", .presence(present: false)),
            at("2026-09-26T02:51:34Z", .presence(present: true)),
            at("2026-09-26T02:59:34Z", .presence(present: false)),
            at("2026-09-26T03:53:34Z", .presence(present: true)),
            at("2026-09-26T04:00:34Z", .presence(present: false)),
            at("2026-09-26T05:20:34Z", .presence(present: true)),
            at("2026-09-26T05:28:34Z", .presence(present: false)),
            at("2026-09-26T20:50:34Z", .presence(present: true)),
            at("2026-09-26T20:58:34Z", .presence(present: false)),
            at("2026-09-26T21:43:34Z", .presence(present: true)),
            at("2026-09-26T21:51:34Z", .presence(present: false)),
            at("2026-09-27T01:07:34Z", .presence(present: true)),
        ]
        let stats = DayRollup.compute(events: events, now: iso.date(from: "2026-09-27T01:10:00Z")!,
                                      dayStart: iso.date(from: "2026-09-26T08:00:00Z")!,
                                      cruise: CruiseSlot(standingSeconds: 20 * 60, sittingSeconds: 40 * 60),
                                      paused: false, standingThresholdInches: 31)
        // From 04:00: two visits worth 8 - 7 min each, so 38 of the 40 min remain at 21:07:34
        // (the desk announced at 21:47:25).
        XCTAssertEqual(stats.nextMove,
                       NextMove(at: iso.date(from: "2026-09-27T01:45:44Z")!, toStanding: true))
    }

    func testAHoldCountsFromAMoveMadeWhileAbsent() {
        // A `.move`/`.countdown` event calls `markPresent`, which would otherwise flip
        // `present` back to true mid-absence and hide that an absence happened at all by the
        // time the real `.presence(true)` arrives - `sawAbsence` tracks it independently.
        let events = [
            ev(40, .move(toStanding: true)),    // stood, before the absence
            ev(30, .presence(present: false)),  // left
            ev(25, .move(toStanding: false)),   // sat while still marked absent
            ev(10, .presence(present: true)),   // returned
        ]
        let stats = DayRollup.compute(events: events, now: now, dayStart: minutesAgo(60),
                                      cruise: cruise, paused: false)
        // lastMove is the sit at -25; the desk held its timer from then until the return at
        // -10 (15 min) -> next stand at -25 + 20 + 15 min (+ moveLeadSeconds).
        XCTAssertEqual(stats.nextMove,
                       NextMove(at: minutesAgo(-10).addingTimeInterval(DayRollup.moveLeadSeconds),
                                toStanding: true))
    }

    func testLoggedAbsencesSinceTheMovePushTheEstimateBack() {
        // The desk holds its interval timer while it doesn't see you: an absence logged a
        // minute after the move, back 30 s later, pushes the next move back by the whole
        // 90 s - the user left before the entry (`absenceLogLagSeconds`), but not before
        // the move.
        let events = [
            ev(2, .move(toStanding: true)),    // stood 2 min ago
            ev(1, .presence(present: false)),  // brief absence
            ev(0.5, .presence(present: true)), // and back
        ]
        let stats = DayRollup.compute(events: events, now: now, dayStart: minutesAgo(60),
                                      cruise: cruise, paused: false)
        XCTAssertEqual(stats.nextMove,
                       NextMove(at: minutesAgo(2).addingTimeInterval(20 * 60 + 90 + DayRollup.moveLeadSeconds),
                                toStanding: false))
    }

    func testAbsencesBeforeTheMoveDoNotCount() {
        let events = [
            ev(30, .presence(present: false)),
            ev(10, .presence(present: true)),
            ev(2, .move(toStanding: true)),
        ]
        let stats = DayRollup.compute(events: events, now: now, dayStart: minutesAgo(60),
                                      cruise: cruise, paused: false)
        XCTAssertEqual(stats.nextMove,
                       NextMove(at: minutesAgo(2).addingTimeInterval(20 * 60 + DayRollup.moveLeadSeconds),
                                toStanding: false))
    }

    func testCountdownLogEntryAnchorsNextMove() {
        // The desk announces a move about a minute before it happens (moveLeadSeconds) via a
        // COUNTDOWN log entry - trust that explicit announcement over any inferred anchor.
        let events = [ev(0.5, .countdown(toStanding: true))]
        let stats = DayRollup.compute(events: events, now: now, dayStart: minutesAgo(60),
                                      cruise: cruise, paused: false)
        XCTAssertEqual(stats.nextMove,
                       NextMove(at: minutesAgo(0.5).addingTimeInterval(DayRollup.moveLeadSeconds), toStanding: true))
    }

    func testAbortedMoveAfterCountdownDerivesPostureFromHeight() {
        // Field data: "19:54 COUNTDOWN down" then "19:55 HEIGHT 41" with no MOVE entry at
        // all - the user reversed the sit mid-countdown. Without resolving the pending
        // countdown here, the app would keep predicting "sit now" forever.
        let events = [
            ev(10, .move(toStanding: true)),      // already standing
            ev(2, .countdown(toStanding: false)), // countdown to sit
            ev(1, .heightChange(inches: 41)),     // aborted - still standing (41 >= 34)
        ]
        let stats = DayRollup.compute(events: events, now: now, dayStart: minutesAgo(60),
                                      cruise: cruise, paused: false, standingThresholdInches: 34)
        XCTAssertEqual(stats.stands, 1, "stands unchanged - the abort isn't a fresh transition")
        XCTAssertEqual(stats.isStanding, true)
        XCTAssertEqual(stats.nextMove,
                       NextMove(at: minutesAgo(1).addingTimeInterval(20 * 60 + DayRollup.moveLeadSeconds),
                                toStanding: false))
    }

    func testAbortedStandAfterCountdownStaysAtSittingHeight() {
        // Same shape, the other direction: a countdown to stand that ends back at sitting
        // height (a no-op) - the desk's own no-op "sit" on the user's return, per field data.
        let events = [
            ev(10, .move(toStanding: false)),    // already sitting
            ev(2, .countdown(toStanding: true)), // countdown to stand
            ev(1, .heightChange(inches: 26)),    // aborted - still sitting (26 < 34)
        ]
        let stats = DayRollup.compute(events: events, now: now, dayStart: minutesAgo(60),
                                      cruise: cruise, paused: false, standingThresholdInches: 34)
        XCTAssertEqual(stats.stands, 0)
        XCTAssertEqual(stats.isStanding, false)
        XCTAssertEqual(stats.nextMove,
                       NextMove(at: minutesAgo(1).addingTimeInterval(20 * 60 + DayRollup.moveLeadSeconds),
                                toStanding: true))
    }

    func testCountdownExpiresBeforeAFarLaterHeightChange() {
        // A `.heightChange` minutes after a countdown - possibly an unrelated paddle nudge,
        // maybe even after an absence in between - must not be misattributed as that
        // countdown's abort: the countdown counts as dismissed, and the height is ignored.
        let events = [
            ev(20, .move(toStanding: true)),       // an earlier, real move
            ev(10, .countdown(toStanding: false)), // never resolved by a MOVE - dismissed
            ev(1, .heightChange(inches: 41)),      // unrelated - 9 min later, outside the window
        ]
        let stats = DayRollup.compute(events: events, now: now, dayStart: minutesAgo(60),
                                      cruise: cruise, paused: false, standingThresholdInches: 34)
        XCTAssertEqual(stats.stands, 1, "stands unchanged - the far-later heightChange isn't attributed to the countdown")
        XCTAssertEqual(stats.isStanding, true)
        XCTAssertEqual(stats.nextMove,
                       NextMove(at: minutesAgo(10).addingTimeInterval(DayRollup.moveLeadSeconds + 20 * 60 + DayRollup.moveLeadSeconds),
                                toStanding: false),
                       "the desk's timer restarted at the dismissal, not at the earlier move or the unrelated heightChange")
    }

    func testDismissedCountdownRestartsTheTimer() {
        // Field data (2026-09-05): stand countdowns the user waved off recurred at 00:57,
        // 01:17, 01:38 and 01:59 - every interval plus about a minute - so a countdown with
        // nothing resolving it inside the window re-anchors the timer ~moveLeadSeconds after
        // the announcement, with the posture unchanged and no stand counted.
        let events = [
            ev(45, .move(toStanding: false)),    // sitting
            ev(25, .countdown(toStanding: true)), // announced a stand; nothing followed
        ]
        let stats = DayRollup.compute(events: events, now: now, dayStart: minutesAgo(60),
                                      cruise: cruise, paused: false, standingThresholdInches: 34)
        XCTAssertEqual(stats.stands, 0)
        XCTAssertEqual(stats.isStanding, false)
        XCTAssertEqual(stats.nextMove,
                       NextMove(at: minutesAgo(25).addingTimeInterval(DayRollup.moveLeadSeconds + 20 * 60 + DayRollup.moveLeadSeconds),
                                toStanding: true))
    }

    func testBackToBackDismissedCountdownsAnchorOnTheLatest() {
        let events = [
            ev(62, .move(toStanding: false)),
            ev(41, .countdown(toStanding: true)),   // dismissed
            ev(20, .countdown(toStanding: true)),   // dismissed again
        ]
        let stats = DayRollup.compute(events: events, now: now, dayStart: minutesAgo(90),
                                      cruise: cruise, paused: false, standingThresholdInches: 34)
        XCTAssertEqual(stats.nextMove,
                       NextMove(at: minutesAgo(20).addingTimeInterval(DayRollup.moveLeadSeconds + 20 * 60 + DayRollup.moveLeadSeconds),
                                toStanding: true))
    }

    func testLiveDismissedCountdownRestartsTheTimerAtOnce() {
        // Field data 2026-09-12: COUNTDOWN(down) read live at 13:39:44.96 and waved off - the
        // motor never started - and the next motor ran at 13:59:51.9, 1206.9 s after the
        // read: the desk restarted its 20 min interval at the dismissal. The app knew by
        // 13:40:15 (announcement grace expired, desk still) but kept the log's view of a
        // pending announcement - "sit coming up", then "waiting for the desk" - until the
        // 5 min resolution window ran out at 13:44:35. A countdown the app watched not
        // happen is dismissed the moment that is known, anchored on the accurate read time.
        let readAt = minutesAgo(1).addingTimeInterval(20)
        let events = [
            ev(45, .move(toStanding: true)),
            ev(1, .countdown(toStanding: false)),  // the log's minute-granular stamp
        ]
        let stats = DayRollup.compute(events: events, now: now, dayStart: minutesAgo(60),
                                      cruise: cruise, paused: false, standingThresholdInches: 34,
                                      dismissedCountdownAt: readAt)
        XCTAssertEqual(stats.stands, 1, "the stand at -45; the dismissed sit is not a move")
        XCTAssertEqual(stats.isStanding, true)
        XCTAssertEqual(stats.nextMove,
                       NextMove(at: readAt.addingTimeInterval(20 * 60 + DayRollup.moveLeadSeconds), toStanding: false))
    }

    func testLiveDismissalOfAnOlderCountdownDoesNotTouchAFreshOne() {
        // The live dismissal names a countdown the log has since superseded: the fresh
        // announcement still stands.
        let events = [
            ev(45, .move(toStanding: false)),
            ev(2, .countdown(toStanding: true)),
        ]
        let stats = DayRollup.compute(events: events, now: now, dayStart: minutesAgo(60),
                                      cruise: cruise, paused: false, standingThresholdInches: 34,
                                      dismissedCountdownAt: minutesAgo(23))
        XCTAssertEqual(stats.nextMove,
                       NextMove(at: minutesAgo(2).addingTimeInterval(DayRollup.moveLeadSeconds), toStanding: true))
    }

    func testDismissedCountdownDoesNotCarryAbsencesFromBeforeIt() {
        // Field data 2026-09-12: away 13:03-13:26, sit countdown at 13:39 waved off, and the
        // re-anchored estimate landed at 14:22 - the 23 min absence from *before* the
        // dismissal was still being held on top of the restarted interval. The desk actually
        // moved at 13:59, a plain interval after the dismissal.
        let events = [
            ev(70, .move(toStanding: true)),
            ev(60, .presence(present: false)),
            ev(40, .presence(present: true)),
            ev(25, .countdown(toStanding: false)),  // dismissed (nothing resolved it in 5 min)
        ]
        let stats = DayRollup.compute(events: events, now: now, dayStart: minutesAgo(90),
                                      cruise: cruise, paused: false, standingThresholdInches: 34)
        XCTAssertEqual(stats.nextMove,
                       NextMove(at: minutesAgo(25).addingTimeInterval(DayRollup.moveLeadSeconds + 20 * 60 + DayRollup.moveLeadSeconds),
                                toStanding: false))
    }

    func testFreshCountdownStillAnnouncesTheMove() {
        // Inside the window the announcement is trusted as before - only stale ones are dismissed.
        let events = [
            ev(45, .move(toStanding: false)),
            ev(2, .countdown(toStanding: true)),
        ]
        let stats = DayRollup.compute(events: events, now: now, dayStart: minutesAgo(60),
                                      cruise: cruise, paused: false, standingThresholdInches: 34)
        XCTAssertEqual(stats.nextMove,
                       NextMove(at: minutesAgo(2).addingTimeInterval(DayRollup.moveLeadSeconds), toStanding: true))
    }

    func testStaleCountdownIsDismissedAfterAnAbsence() {
        // The 2026-09-05 morning case: a stand announced at 01:59 and waved off, absent from
        // 02:21, back at 11:36 - the popover sat on "waiting for the desk" because the
        // nine-hour-old countdown was still treated as pending. Dismissed, it stands in for
        // the move it announced (see `dismissCountdown`) - until the day boundary restarts
        // the timer, which then holds through the absence from the boundary to the return.
        let events = [
            ev(600, .move(toStanding: false)),
            ev(580, .countdown(toStanding: true)),
            ev(560, .presence(present: false)),
            ev(13, .presence(present: true)),
        ]
        let stats = DayRollup.compute(events: events, now: now, dayStart: minutesAgo(400),
                                      cruise: cruise, paused: false, standingThresholdInches: 34)
        XCTAssertEqual(stats.isPresent, true)
        XCTAssertEqual(stats.nextMove,
                       NextMove(at: minutesAgo(400).addingTimeInterval((20 + 387) * 60 + DayRollup.moveLeadSeconds),
                                toStanding: true))
    }

    func testNextMoveAnchorUnaffectedWithoutAnAbsence() {
        // No absence intervened since the move - the plain move-based anchor still applies.
        let events = [ev(5, .move(toStanding: true))]
        let stats = DayRollup.compute(events: events, now: now, dayStart: minutesAgo(60),
                                      cruise: cruise, paused: false)
        XCTAssertEqual(stats.nextMove,
                       NextMove(at: minutesAgo(5).addingTimeInterval(20 * 60 + DayRollup.moveLeadSeconds),
                                toStanding: false))
    }

    func testNextMoveIsOverdueOnlyMoreThan90SecondsPastAt() {
        let next = NextMove(at: now, toStanding: true)
        XCTAssertFalse(next.isOverdue(now: now)) // exactly due, not overdue
        XCTAssertFalse(next.isOverdue(now: now.addingTimeInterval(90))) // right at the boundary
        XCTAssertTrue(next.isOverdue(now: now.addingTimeInterval(91)))
        XCTAssertFalse(next.isOverdue(now: now.addingTimeInterval(-10))) // not even due yet
    }

    func testNextMoveIsNilWhenPausedAbsentOrCruiseOff() {
        let events = [ev(30, .presence(present: true)), ev(5, .move(toStanding: true))]
        XCTAssertNil(DayRollup.compute(events: events, now: now, dayStart: minutesAgo(60),
                                       cruise: cruise, paused: true).nextMove)
        XCTAssertNil(DayRollup.compute(events: events, now: now, dayStart: minutesAgo(60),
                                       cruise: nil, paused: false).nextMove)
        let absent = events + [ev(1, .presence(present: false))]
        XCTAssertNil(DayRollup.compute(events: absent, now: now, dayStart: minutesAgo(60),
                                       cruise: cruise, paused: false).nextMove)
        XCTAssertEqual(DayRollup.compute(events: events, now: now, dayStart: minutesAgo(60),
                                         cruise: cruise, paused: false).nextMove,
                       NextMove(at: minutesAgo(5).addingTimeInterval(20 * 60 + DayRollup.moveLeadSeconds),
                                toStanding: false))
    }
}
