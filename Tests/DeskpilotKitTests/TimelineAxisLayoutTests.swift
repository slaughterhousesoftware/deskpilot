import AppKit
import XCTest
@testable import DeskpilotKit

final class TimelineAxisLayoutTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/Toronto")!
        return value
    }

    private func date(_ hour: Int, _ minute: Int = 0, day: Int = 21, month: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private func plan(_ sessions: [TimelineAxisLayout.Session] = [], width: Double = 585,
                      domain: ClosedRange<Date>? = nil, locale: String = "en_US",
                      contentInset: Double = 30) -> TimelineAxisLayout.Plan? {
        TimelineAxisLayout.plan(in: domain ?? date(7)...date(19), width: width,
                                sessions: sessions, calendar: calendar, locale: Locale(identifier: locale),
                                contentInset: contentInset) { text, isSession in
            let font = NSFont.systemFont(ofSize: 10, weight: isSession ? .medium : .regular)
            return Double((text as NSString).size(withAttributes: [.font: font]).width + 2)
        }
    }

    private func assertValid(_ plan: TimelineAxisLayout.Plan, width: Double, domain: ClosedRange<Date>,
                             file: StaticString = #filePath, line: UInt = #line) {
        for label in plan.labels {
            XCTAssertTrue(label.left.isFinite && label.width.isFinite, file: file, line: line)
            XCTAssertGreaterThanOrEqual(label.left, 2 - 0.001, file: file, line: line)
            XCTAssertLessThanOrEqual(label.right, width - 2 + 0.001, file: file, line: line)
            XCTAssertTrue(domain.contains(label.date), file: file, line: line)
            XCTAssertTrue(domain.contains(label.positionDate), file: file, line: line)
        }
        XCTAssertEqual(Set(plan.labels.map(\.positionDate)).count, plan.labels.count, file: file, line: line)
        XCTAssertEqual(plan.labels.map(\.positionDate), plan.labels.map(\.positionDate).sorted(), file: file, line: line)
    }

    func testExactStartIsCenteredAndOutranksTheClockTicks() throws {
        let start = date(7, 9)
        let result = try XCTUnwrap(plan([.init(start: start)]))
        let marker = try XCTUnwrap(result.labels.first { $0.kind == .start })
        XCTAssertTrue(marker.text.contains("7:09"))
        XCTAssertEqual(marker.tickX, 30 + 525 * 9 / 720, accuracy: 0.001)
        XCTAssertEqual(marker.left + marker.width / 2, marker.tickX, accuracy: 0.001)
        XCTAssertEqual(marker.positionDate, start)
        XCTAssertTrue(result.labels.contains { $0.kind == .hour })
        XCTAssertTrue(result.labels.filter { !$0.isSession }.allSatisfy { $0.priority < marker.priority })
        assertValid(result, width: 585, domain: date(7)...date(19))
    }

    func testDensityAdaptsToWidthUsingCalendarIntervals() throws {
        for (width, expectedHours) in [(320.0, 6), (585.0, 3), (900.0, 2)] {
            let result = try XCTUnwrap(plan(width: width))
            XCTAssertEqual(result.interval.component, .hour)
            XCTAssertEqual(result.interval.count, expectedHours)
            XCTAssertTrue(result.labels.allSatisfy {
                calendar.component(.hour, from: $0.date).isMultiple(of: expectedHours)
            })
        }
    }

    func testZoomedInRangeUsesMinuteTicks() throws {
        let result = try XCTUnwrap(plan(domain: date(7)...date(9)))
        XCTAssertEqual(result.interval.component, .minute)
        XCTAssertEqual(result.interval.count, 30)
        XCTAssertTrue(result.labels.contains { calendar.component(.minute, from: $0.date) == 30 })
        assertValid(result, width: 585, domain: date(7)...date(9))
    }

    func testPanningKeepsTheSameTickFamilyAsSessionsEnterAndLeave() throws {
        let session = TimelineAxisLayout.Session(start: date(7, 9), end: date(18, 59))
        let baseline = try XCTUnwrap(plan([session]))
        for minutes in stride(from: -240, through: 240, by: 7) {
            let shift = Double(minutes) * 60
            let domain = date(7).addingTimeInterval(shift)...date(19).addingTimeInterval(shift)
            let result = try XCTUnwrap(plan([session], domain: domain))
            XCTAssertEqual(result.interval, baseline.interval)
            for label in result.labels where !label.isSession {
                XCTAssertEqual(calendar.component(.minute, from: label.date), 0)
                XCTAssertTrue(calendar.component(.hour, from: label.date).isMultiple(of: 3))
            }
        }
    }

    func testNativeEngineReceivesBothPrioritiesForTheReportedCrowdedCase() throws {
        let result = try XCTUnwrap(plan([.init(start: date(7, 9))], domain: date(5, 45)...date(17, 45)))
        let start = try XCTUnwrap(result.labels.first { $0.kind == .start })
        let six = try XCTUnwrap(result.labels.first { $0.date == date(6) })
        // Both candidates reach the native collision engine; the start time wins when
        // Apple's measured text bounds plus minimum spacing don't fit side by side.
        XCTAssertGreaterThan(start.priority, six.priority)
        XCTAssertLessThan(start.left - six.right, TimelineAxisLayout.minimumLabelSpacing)
        XCTAssertTrue(result.labels.contains { $0.date == date(9) })
        XCTAssertFalse(result.labels.contains { $0.date == date(10) })
    }

    func testExactTimesAtBothEdgesRemainCenteredOnTheirGuides() throws {
        for width in [180.0, 320, 585] {
            for (start, end) in [(date(7), date(19)), (date(7, 9), date(18, 59))] {
                let result = try XCTUnwrap(plan([.init(start: start, end: end)], width: width))
                for kind in [TimelineAxisLayout.Kind.start, .end] {
                    let label = try XCTUnwrap(result.labels.first { $0.kind == kind })
                    let expectedX = 30 + label.date.timeIntervalSince(date(7)) / (12 * 3600) * (width - 60)
                    XCTAssertEqual(label.tickX, expectedX, accuracy: 0.001)
                    XCTAssertEqual(label.left + label.width / 2, label.tickX, accuracy: 0.001)
                    XCTAssertEqual(label.positionDate, label.date)
                }
                assertValid(result, width: width, domain: date(7)...date(19))
            }
        }
    }

    func testCloseEndpointsBecomeOneCompleteRangeThatFitsTheEdge() throws {
        for (start, end) in [(date(7, 9), date(7, 24)), (date(18, 40), date(18, 59))] {
            let result = try XCTUnwrap(plan([.init(start: start, end: end)]))
            let range = try XCTUnwrap(result.labels.first { $0.kind == .range })
            XCTAssertEqual(range.date, start)
            XCTAssertEqual(range.end, end)
            XCTAssertFalse(result.labels.contains { $0.kind == .start || $0.kind == .end })
            let position = 30 + range.positionDate.timeIntervalSince(date(7)) / (12 * 3600) * 525
            XCTAssertEqual(position, range.left + range.width / 2, accuracy: 0.001)
            assertValid(result, width: 585, domain: date(7)...date(19))
        }
    }

    func testSessionExactlyOnAnHourDoesNotProduceDuplicateNativeMarks() throws {
        let result = try XCTUnwrap(plan([.init(start: date(12))]))
        XCTAssertEqual(result.labels.filter { $0.positionDate == date(12) }.count, 1)
        XCTAssertTrue(result.labels.contains { $0.kind == .start && $0.date == date(12) })
        assertValid(result, width: 585, domain: date(7)...date(19))
    }

    func testContinuousDeskTimeAcrossDayBoundaryGetsOneNativeLabel() throws {
        let result = try XCTUnwrap(plan([.init(start: date(0), end: date(4)), .init(start: date(4), end: date(10))],
                                        domain: date(0)...date(12)))
        XCTAssertEqual(result.labels.filter { $0.positionDate == date(4) }.count, 1)
        XCTAssertEqual(result.labels.first { $0.positionDate == date(4) }?.kind, .start)
        assertValid(result, width: 585, domain: date(0)...date(12))
    }

    func testOffscreenStartDoesNotPullItsLabelIntoView() throws {
        let result = try XCTUnwrap(plan([.init(start: date(6), end: date(17, 23))]))
        XCTAssertFalse(result.labels.contains { $0.kind == .start })
        XCTAssertTrue(result.labels.contains { $0.kind == .end })
        assertValid(result, width: 585, domain: date(7)...date(19))
    }

    func testLocalesWidthsAndFractionalScrollsKeepExactTimesAndValidGeometry() throws {
        let session = TimelineAxisLayout.Session(start: date(7, 9), end: date(18, 59))
        for locale in ["en_US", "en_GB", "fr_FR", "ar_EG"] {
            for width in [180.0, 240, 320, 585, 900] {
                for minutes in stride(from: -120, through: 120, by: 7) {
                    let shift = Double(minutes) * 60
                    let domain = date(7).addingTimeInterval(shift)...date(19).addingTimeInterval(shift)
                    let result = try XCTUnwrap(plan([session], width: width, domain: domain, locale: locale))
                    if domain.contains(session.start) {
                        XCTAssertTrue(result.labels.contains { $0.kind == .start || $0.kind == .range })
                    }
                    if domain.contains(session.end!) {
                        XCTAssertTrue(result.labels.contains { $0.kind == .end || $0.kind == .range })
                    }
                    assertValid(result, width: width, domain: domain)
                }
            }
        }
    }

    func testCalendarTicksAcrossMidnightAndDaylightSaving() throws {
        for (month, day) in [(3, 8), (11, 1), (10, 21)] {
            let lower = date(0, day: day, month: month)
            let upper = date(12, day: day, month: month)
            let result = try XCTUnwrap(plan(domain: lower...upper))
            XCTAssertFalse(result.labels.isEmpty)
            XCTAssertTrue(result.labels.allSatisfy { calendar.component(.minute, from: $0.date) == 0 })
            assertValid(result, width: 585, domain: lower...upper)
        }
        let overnight = try XCTUnwrap(plan(domain: date(20)...date(8, day: 22)))
        let midnight = try XCTUnwrap(overnight.labels.first { $0.date == date(0, day: 22) })
        XCTAssertGreaterThan(midnight.priority, 0)
        assertValid(overnight, width: 585, domain: date(20)...date(8, day: 22))
    }

    func testFallBackRetainsBothDistinctOneOClockInstants() throws {
        let lower = date(0, day: 1, month: 11), upper = date(4, day: 1, month: 11)
        let result = try XCTUnwrap(plan(domain: lower...upper))
        let repeated = result.labels.filter { calendar.component(.hour, from: $0.date) == 1 }
        XCTAssertEqual(repeated.count, 2)
        XCTAssertEqual(repeated[1].date.timeIntervalSince(repeated[0].date), 3600)
        assertValid(result, width: 585, domain: lower...upper)
    }

    func testInvalidGeometryOrMeasurementsDoNotProduceABrokenPlan() {
        for width in [0, -1, Double.nan, Double.infinity] {
            XCTAssertNil(plan(width: width))
        }
        XCTAssertNil(TimelineAxisLayout.plan(in: date(7)...date(19), width: 100, sessions: [],
                                              calendar: calendar) { _, _ in .nan })
        for inset in [-1, 50, Double.nan, Double.infinity] {
            XCTAssertNil(plan(width: 100, contentInset: inset))
        }
    }

    func testFullDayWindowBoundsRemainAvailableWithoutDisplacingSessionTimes() throws {
        for (month, day) in [(10, 22), (3, 7), (10, 31)] {
            let lower = date(4, day: day, month: month)
            let upper = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: lower))
            let result = try XCTUnwrap(TimelineAxisLayout.plan(
                in: lower...upper, width: 585, sessions: [.init(start: lower)],
                calendar: calendar, locale: Locale(identifier: "en_US"), contentInset: 30,
                showWindowBounds: true, measure: { text, _ in Double(text.count * 6) }))
            XCTAssertEqual(result.labels.filter { $0.positionDate == lower }.count, 1)
            XCTAssertEqual(result.labels.first { $0.positionDate == lower }?.kind, .start)
            XCTAssertNotNil(result.labels.first { $0.positionDate == upper })
            assertValid(result, width: 585, domain: lower...upper)
        }
    }

    func testWindowBoundOffTheHourIsPositionedInsideTheLeadingEdge() throws {
        let lower = date(4).addingTimeInterval(54 * 60)
        let upper = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: lower))
        let result = try XCTUnwrap(TimelineAxisLayout.plan(
            in: lower...upper, width: 568, sessions: [], calendar: calendar,
            locale: Locale(identifier: "en_US"), edgeInset: 0, showWindowBounds: true,
            measure: { text, _ in Double(text.count * 6) }))
        let first = try XCTUnwrap(result.labels.first { $0.date == lower })
        XCTAssertEqual(first.left, 0)
        // Centred on its position by the native axis, it starts at the plot's edge.
        let middle = first.positionDate.timeIntervalSince(lower) / upper.timeIntervalSince(lower) * 568
        XCTAssertEqual(middle - first.width / 2, 0, accuracy: 0.001)
        let last = try XCTUnwrap(result.labels.first { $0.date == upper })
        let lastMiddle = last.positionDate.timeIntervalSince(lower) / upper.timeIntervalSince(lower) * 568
        XCTAssertEqual(lastMiddle + last.width / 2, 568, accuracy: 0.001)
    }
}
