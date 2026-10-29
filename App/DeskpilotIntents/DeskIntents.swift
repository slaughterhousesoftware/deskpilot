import AppIntents
import DeskpilotKit

/// What Siri, Shortcuts and Control Center can do with the desk. Compiled into both the menu
/// bar app (Siri and Shortcuts run intents there) and the widget extension (Control Center
/// runs them there), so neither copy talks to the desk itself: reads come from the widget's
/// snapshot file and writes go through the dashboard's command queue, which the menu bar
/// app - the only Bluetooth client - executes. Siri launches the app in the background if it
/// isn't running, so a command sent then can still fail while the desk is connecting.
enum DeskIntents {
    static func sendOrThrow(_ command: DeskCommand) async throws {
        guard let result = await CommandQueue().send(command) else {
            throw DeskIntentError.noAnswer(appRunning: SnapshotStore().read().map {
                Date().timeIntervalSince($0.updatedAt) < DeskSnapshot.staleAfter
            } ?? false)
        }
        guard result.success else { throw DeskIntentError.failed(result.message ?? "That didn't work.") }
    }

    /// True when cruise control is on: the desk will move on its own.
    static var cruiseIsOn: Bool {
        guard let s = SnapshotStore().read(), s.connected else { return false }
        return !s.paused && s.cruise != nil
    }
}

enum DeskIntentError: Error, CustomLocalizedStringResourceConvertible {
    case noAnswer(appRunning: Bool)
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noAnswer(true): return "The desk didn't answer. Try again in a moment."
        case .noAnswer(false): return "Deskpilot isn't running. Open it and try again."
        case .failed(let message): return LocalizedStringResource(stringLiteral: message)
        }
    }
}

struct DeskStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Desk Status"
    static let description = IntentDescription("Whether you're sitting or standing, today's totals, and when the desk moves next.")

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let sentence = DeskStatusSummary.sentence(SnapshotStore().read())
        return .result(value: sentence, dialog: IntentDialog(stringLiteral: sentence))
    }
}

struct PauseDeskIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Desk"
    static let description = IntentDescription("Pauses cruise control so the desk stays where it is.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await DeskIntents.sendOrThrow(.setPaused(true))
        return .result(dialog: "Paused. The desk will stay where it is.")
    }
}

struct ResumeDeskIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Desk"
    static let description = IntentDescription("Resumes cruise control so the desk moves on its rhythm again.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await DeskIntents.sendOrThrow(.setPaused(false))
        return .result(dialog: "Resumed. The desk is back on its rhythm.")
    }
}

struct ReconnectDeskIntent: AppIntent {
    static let title: LocalizedStringResource = "Reconnect Desk"
    static let description = IntentDescription("Drops the Bluetooth connection to the desk and connects again.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await DeskIntents.sendOrThrow(.reconnect)
        return .result(dialog: "Reconnecting to the desk.")
    }
}

/// The Control Center toggle's intent: on means cruise control is running.
@available(macOS 15, *)
struct SetCruiseControlIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Set Cruise Control"
    static let description = IntentDescription("Turns the desk's automatic sit-stand rhythm on or off.")

    @Parameter(title: "Cruise control") var value: Bool

    func perform() async throws -> some IntentResult {
        try await DeskIntents.sendOrThrow(.setPaused(!value))
        return .result()
    }
}
