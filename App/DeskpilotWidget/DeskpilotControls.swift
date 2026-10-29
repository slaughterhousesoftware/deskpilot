import AppIntents
import SwiftUI
import DeskpilotKit
import WidgetKit

/// Control Center (macOS 26+): a cruise-control switch and a reconnect button, both acting
/// through the command queue like every other intent in `DeskIntents.swift`.
@available(macOS 26, *)
struct CruiseControlControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.kevinpatel.tempo.control.cruise") {
            ControlWidgetToggle(isOn: DeskIntents.cruiseIsOn, action: SetCruiseControlIntent()) {
                Label("Cruise Control", systemImage: "figure.stand")
            } valueLabel: { isOn in
                Text(isOn ? "On" : "Paused")
            }
        }
        .displayName("Deskpilot Cruise Control")
        .description("Turns the desk's automatic sit-stand rhythm on or off.")
    }
}

@available(macOS 26, *)
struct ReconnectControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.kevinpatel.tempo.control.reconnect") {
            ControlWidgetButton(action: ReconnectDeskIntent()) {
                Label("Reconnect Desk", systemImage: "arrow.clockwise")
            }
        }
        .displayName("Reconnect Deskpilot")
        .description("Drops the Bluetooth connection to the desk and connects again.")
    }
}
