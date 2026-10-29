import AppIntents

/// The phrases Siri answers to, and the tiles Shortcuts and Spotlight offer, for the intents
/// in `DeskIntents.swift`. App-only: the widget extension can't provide App Shortcuts.
struct DeskpilotShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: DeskStatusIntent(),
                    phrases: ["What's my \(.applicationName) status",
                              "Get my \(.applicationName) desk status",
                              "Am I standing in \(.applicationName)"],
                    shortTitle: "Desk Status", systemImageName: "figure.stand")
        AppShortcut(intent: PauseDeskIntent(),
                    phrases: ["Pause \(.applicationName)", "Pause my \(.applicationName) desk"],
                    shortTitle: "Pause Desk", systemImageName: "pause.circle")
        AppShortcut(intent: ResumeDeskIntent(),
                    phrases: ["Resume \(.applicationName)", "Resume my \(.applicationName) desk"],
                    shortTitle: "Resume Desk", systemImageName: "play.circle")
        AppShortcut(intent: ReconnectDeskIntent(),
                    phrases: ["Reconnect \(.applicationName)", "Reconnect my \(.applicationName) desk"],
                    shortTitle: "Reconnect Desk", systemImageName: "arrow.clockwise.circle")
    }
}
