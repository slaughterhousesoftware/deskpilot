import XCTest
import Observation
@testable import DeskpilotKit

final class DeskpilotDisplayPreferencesTests: XCTestCase {
    func testDefaultFollowsSystemAndPersistsEveryMode() throws {
        let suite = "DeskpilotDisplayPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dashboard = DeskpilotDisplayPreferences(defaults: defaults)
        XCTAssertEqual(dashboard.mode, .system)
        XCTAssertNil(dashboard.mode.colorScheme)
        for mode in DeskpilotDisplayMode.allCases {
            dashboard.select(mode)
            let otherApp = DeskpilotDisplayPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
            XCTAssertEqual(otherApp.mode, mode)
        }
    }

    func testNotificationUpdatesAlreadyOpenReader() throws {
        let suite = "DeskpilotDisplayPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dashboard = DeskpilotDisplayPreferences(defaults: defaults)
        let secondWindow = DeskpilotDisplayPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        let changed = expectation(description: "Another window observes appearance change")
        withObservationTracking { _ = secondWindow.mode } onChange: { changed.fulfill() }
        dashboard.select(.light)
        wait(for: [changed], timeout: 3)
        XCTAssertEqual(secondWindow.mode, .light)
    }

    func testInvalidPreferenceFollowsSystem() throws {
        let suite = "DeskpilotDisplayPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("old-value", forKey: "tempoDisplayMode")
        XCTAssertEqual(DeskpilotDisplayPreferences(defaults: defaults).mode, .system)
    }
}
