import XCTest
@testable import DeskpilotKit

final class StripAxisLayoutTests: XCTestCase {
    /// A 316-point axis from 6 AM to midnight: 17 points an hour, labels 33 points wide.
    private let width = 316.0
    private let labelWidth = 33.0
    private func x(_ hour: Double) -> Double { (hour - 6) / 18 * width }

    private func option(_ step: Int) -> StripAxisLayout.Option {
        let hours = stride(from: 6 + step, to: 24, by: step)
        return .init(step: step, labels: hours.map { .init(left: x(Double($0)) + 3, width: labelWidth) })
    }

    private var ends: [StripAxisLayout.Span] {
        [.init(left: 0, width: labelWidth), .init(left: width - 38, right: width)]
    }

    func testDropsAnIntervalWhoseLabelsCollide() {
        let choice = StripAxisLayout.choose([option(1), option(2)], fixed: ends)
        XCTAssertNil(choice, "hourly and two-hourly labels can't fit at 17 points an hour")
    }

    func testPrefersTheIntervalWithoutBigHoles() {
        let choice = StripAxisLayout.choose([option(1), option(2), option(3), option(6)], fixed: ends)
        XCTAssertEqual(choice?.step, 3)
        // 9 PM steps aside for the day's last hour at the right edge.
        XCTAssertEqual(choice?.shown, [0, 1, 2, 3])
    }

    func testLabelsTouchingNowStepAside() {
        let now = StripAxisLayout.Span(left: x(17.78) - 28, width: 56)
        let choice = StripAxisLayout.plan([option(2), option(3), option(6)], ends: ends, now: now)
        XCTAssertEqual(choice?.step, 3)
        // 9 AM and 12 PM stay; 3 PM and 6 PM give way to 5:47 PM; 9 PM to the last hour.
        XCTAssertEqual(choice?.shown, [0, 1])
    }

    func testIntervalHoldsStillAsNowMoves() {
        let options = [option(1), option(2), option(3), option(6)]
        let steps = stride(from: 6.5, to: 23.5, by: 0.25).map { hour in
            StripAxisLayout.plan(options, ends: ends, now: .init(left: x(hour) - 28, width: 56))?.step
        }
        XCTAssertEqual(Set(steps), [3])
    }

    func testNearTieGoesToTheWiderInterval() {
        // Every three hours leaves at most 85 points empty, every six 92: within tolerance.
        let options = [StripAxisLayout.Option(step: 3, labels: [.init(left: 105, width: 30)]),
                       StripAxisLayout.Option(step: 6, labels: [.init(left: 98, width: 30)])]
        let choice = StripAxisLayout.choose(options, fixed: [.init(left: 0, width: 30), .init(left: 220, width: 30)])
        XCTAssertEqual(choice?.step, 6)
    }

    private func label(_ left: Double, _ right: Double) -> StripAxisLayout.Span { .init(left: left, right: right) }

    func testNowCentreStaysOnNowWhenNothingIsInTheWay() {
        XCTAssertEqual(StripAxisLayout.nowCentre(now: 100, half: 20, maxShift: 10, labels: [label(20, 50), label(150, 180)], gap: 4), 100)
    }

    func testNowCentreSlidesBackToClearTheNextLabel() {
        // The next label starts at 120: centred, the capsule would reach 125.
        XCTAssertEqual(StripAxisLayout.nowCentre(now: 105, half: 20, maxShift: 10, labels: [label(120, 150)], gap: 4), 96)
    }

    func testNowCentreMovesNoFurtherThanAllowed() {
        XCTAssertEqual(StripAxisLayout.nowCentre(now: 115, half: 20, maxShift: 10, labels: [label(120, 150)], gap: 4), 115)
    }

    func testNowCentreWontUncoverOneLabelByCoveringAnother() {
        // Sliding back to clear the label at 120 would run into the one ending at 74.
        XCTAssertEqual(StripAxisLayout.nowCentre(now: 100, half: 20, maxShift: 10, labels: [label(40, 74), label(120, 150)], gap: 4), 100)
    }

    func testNowCentreClearsBothWhenItCan() {
        XCTAssertEqual(StripAxisLayout.nowCentre(now: 100, half: 7.5, maxShift: 4, labels: [label(85, 92), label(120, 127)], gap: 2), 101.5)
    }
}
