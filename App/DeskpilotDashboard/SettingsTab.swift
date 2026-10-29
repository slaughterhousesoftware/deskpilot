import SwiftUI
import DeskpilotKit

/// The Settings tab: the desk's rhythm and presets, sent to the menu bar app as commands
/// through the App Group queue, and the Dashboard's appearance. Help links live in the Help
/// menu and the acknowledgements in the About window, as on any Mac app.
///
/// Each group has its own in-flight state and its own result line, and is repopulated from the
/// snapshot only when *its* values change - so a poll landing mid-edit can't yank a slider out
/// from under the user's cursor. Explanations live in tooltips; a line appears under a group
/// only when a command fails.
struct SettingsTab: View {
    @Environment(DashboardModel.self) private var model

    @State private var cruiseOn = false
    @State private var customStanding = 20
    @State private var customSitting = 40

    @State private var presetsBusy = false
    /// Which preset row's button is waiting on the desk.
    @State private var savingPreset: String?
    @State private var rhythmBusy = false
    @State private var presetsResult: CommandOutcome?
    @State private var rhythmResult: CommandOutcome?

    var body: some View {
        Form {
            rhythmSection
            presetsSection
            Section("Appearance") {
                Picker("Colour mode", selection: Binding(
                    get: { DeskpilotDisplayPreferences.shared.mode },
                    set: { DeskpilotDisplayPreferences.shared.select($0) })) {
                    ForEach(DeskpilotDisplayMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                .help("System follows your Mac. The menu bar always follows macOS.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        // As tall as the settings and no taller: the window sizes to its content, so there's
        // no empty run under the last group.
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .clipped()
        .onAppear(perform: loadRhythm)
        .onChange(of: model.snapshot?.cruise) { _, _ in loadRhythm() }
    }

    // MARK: - Rhythm

    private var rhythmSection: some View {
        Section {
            // Always the desk's custom slot (its controller calls it "Bluetooth custom"):
            // the desk's own hourly presets are just points on these two sliders.
            Toggle("Cruise control", isOn: $cruiseOn)
                .tint(.blue)
                .help("The desk moves itself between standing and sitting on this rhythm.")
            minutesRow("Stand for", value: $customStanding)
                .disabled(!cruiseOn)
            minutesRow("Sit for", value: $customSitting)
                .disabled(!cruiseOn)
            LabeledContent("") {
                HStack(spacing: 8) {
                    if rhythmBusy {
                        ProgressView().controlSize(.small)
                    }
                    Button("Save") { saveRhythm() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(rhythmBusy || !model.deskIsConnected || !rhythmChanged)
                        .help(model.deskIsConnected ? "Send this rhythm to the desk." : "Connect to the desk to save.")
                }
            }
        } header: {
            Text("Rhythm")
        } footer: {
            failure(rhythmResult)
        }
    }

    /// Label left; a native slider with a tick stop every 5 minutes, and the value beside it.
    /// 5-60 minutes covers every rhythm the desk's own presets offer and keeps the pair well
    /// inside `CruiseSlot.make`'s 240-minute cycle cap.
    private func minutesRow(_ title: String, value: Binding<Int>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 12) {
                Slider(value: Binding(get: { Double(value.wrappedValue) },
                                      set: { value.wrappedValue = Int($0.rounded()) }),
                       in: 5...60, step: 5)
                    .frame(minWidth: 80, maxWidth: .infinity)
                Text("\(value.wrappedValue) min")
                    .monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
            }
        }
    }

    /// Whether the switch or sliders differ from the rhythm the desk has, so Save is only
    /// lit when there's something to save.
    private var rhythmChanged: Bool {
        guard let cruise = model.snapshot?.cruise else { return cruiseOn }
        return !cruiseOn
            || customStanding != max(5, cruise.standingSeconds / 60)
            || customSitting != max(5, cruise.sittingSeconds / 60)
    }

    private func loadRhythm() {
        guard let cruise = model.snapshot?.cruise else {
            cruiseOn = false
            return
        }
        cruiseOn = true
        customStanding = max(5, cruise.standingSeconds / 60)
        customSitting = max(5, cruise.sittingSeconds / 60)
    }

    private func saveRhythm() {
        guard cruiseOn else {
            run(.setCruise(nil), busy: $rhythmBusy, result: $rhythmResult)
            return
        }
        do {
            let slot = try CruiseSlot.make(standingMinutes: customStanding,
                                           cycleMinutes: customStanding + customSitting)
            run(.setCruise(slot), busy: $rhythmBusy, result: $rhythmResult)
        } catch {
            rhythmResult = CommandOutcome(success: false,
                                          message: "Stand and sit must total between 2 and 240 minutes.")
        }
    }

    // MARK: - Presets

    private var presetsSection: some View {
        Section {
            LabeledContent("Current height", value: Formatting.height(tenths: model.snapshot?.heightTenths))
            presetRow("Sitting", tenths: model.snapshot?.sittingHeightTenths, command: .captureSittingPreset)
            presetRow("Standing", tenths: model.snapshot?.standingHeightTenths, command: .captureStandingPreset)
        } header: {
            Text("Presets")
        } footer: {
            failure(presetsResult)
        }
    }

    /// A preset's height, with the button that replaces it with the desk's height now beside
    /// it, as Settings puts an action next to the value it changes. Dimmed when the desk is
    /// already at that height, since there's nothing to save.
    private func presetRow(_ title: String, tenths: Int?, command: DeskCommand) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Text(Formatting.height(tenths: tenths))
                    .monospacedDigit()
                if savingPreset == title {
                    ProgressView().controlSize(.small)
                }
                Button("Use Current") {
                    savingPreset = title
                    run(command, busy: $presetsBusy, result: $presetsResult)
                }
                .controlSize(.small)
                .disabled(presetsBusy || !model.canEditPresets
                          || model.snapshot?.heightTenths == nil || model.snapshot?.heightTenths == tenths)
                .help("Save the desk's height now as your \(title.lowercased()) height.")
            }
        }
        .onChange(of: presetsBusy) { _, busy in if !busy { savingPreset = nil } }
    }

    // MARK: - Plumbing

    private func run(_ command: DeskCommand, busy: Binding<Bool>, result: Binding<CommandOutcome?>) {
        busy.wrappedValue = true
        result.wrappedValue = nil
        Task {
            let outcome = await model.send(command)
            busy.wrappedValue = false
            result.wrappedValue = outcome
        }
    }

    /// The last command's error, in red; nothing when it worked.
    @ViewBuilder
    private func failure(_ result: CommandOutcome?) -> some View {
        if let result, !result.success {
            Text(result.message).foregroundStyle(.red)
        }
    }
}
