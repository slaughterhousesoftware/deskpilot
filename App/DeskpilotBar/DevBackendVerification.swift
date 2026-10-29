import AppKit
import Foundation
import DeskpilotKit

/// Opt-in integration check using exactly the model methods called by the menu controls.
/// No work runs without DESKPILOT_DEV_BACKEND_VERIFY. The original pause state is restored.
@MainActor
enum DevBackendVerification {
    static func run(model: DeskModel) {
        guard let path = ProcessInfo.processInfo.environment["DESKPILOT_DEV_BACKEND_VERIFY"] else { return }
        Task {
            var results: [String: Any] = [:]
            do {
                try await wait { model.state.status == .connected && model.state.settings != nil && model.state.today != nil }
                results["initialConnected"] = true
                let original = model.state.settings!.paused
                guard await model.setPaused(!original) else { throw Failure(message: model.lastActionError ?? "Pause command failed") }
                do {
                    try await wait { model.state.settings?.paused == !original }
                    results["pauseRoundTrip"] = true
                } catch {
                    _ = await model.setPaused(original)
                    throw error
                }
                guard await model.setPaused(original) else { throw Failure(message: model.lastActionError ?? "Pause restoration failed") }
                try await wait { model.state.settings?.paused == original }
                results["originalPauseRestored"] = true
                model.reconnect()
                try await wait { model.state.status != .connected }
                try await wait { model.state.status == .connected && model.state.today != nil }
                results["reconnectRoundTrip"] = true
                results["heightTenths"] = model.state.heightTenths
                results["timelineSegments"] = model.todaySegments.count
                results["atDeskSeconds"] = model.today?.atDeskSeconds
                results["success"] = true
            } catch {
                results["success"] = false
                results["error"] = error.localizedDescription
            }
            if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
        }
    }

    private static func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(40)
        while !predicate() {
            guard Date() < deadline else { throw Failure(message: "Timed out waiting for backend state") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
