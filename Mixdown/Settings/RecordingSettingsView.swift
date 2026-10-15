import KeyboardShortcuts
import MixdownCore
import SwiftUI

/// Which inputs to record and how to label them. The same choice is in the menu bar; this tab adds
/// the speaker names, explains how multi-source recordings are transcribed, sets the global
/// shortcut, and decides what happens when a call starts.
struct RecordingSettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let coordinator = environment.coordinator
        let microphones = coordinator.devices.filter { $0.kind == .microphone }
        let hasSystemAudio = coordinator.devices.contains { $0.kind == .systemAudio }

        Form {
            Section {
                Picker(
                    "Microphone",
                    selection: Binding(
                        get: { environment.selectedMicrophone?.id },
                        set: { id in environment.selectMicrophone(microphones.first { $0.id == id }) }
                    )
                ) {
                    Text("None").tag(String?.none)
                    Divider()
                    ForEach(microphones) { device in
                        Text(DevicePicker.title(for: device)).tag(Optional(device.id))
                    }
                }

                if hasSystemAudio {
                    Toggle(
                        "Record system audio",
                        isOn: Binding(
                            get: { environment.recordsSystemAudio },
                            set: { environment.setRecordsSystemAudio($0) }
                        )
                    )
                }
            } header: {
                Text("Inputs")
            } footer: {
                Text(
                    "Record your microphone and system audio together to capture both sides of a call. "
                        + "At least one input stays on. Inputs can't change while recording."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .disabled(coordinator.isRecording)

            Section {
                Toggle(
                    "Notify when calls start and end",
                    isOn: Binding(
                        get: { environment.notifiesAboutCalls },
                        set: { environment.setNotifiesAboutCalls($0) }
                    )
                )
                Toggle(
                    "Record calls automatically",
                    isOn: Binding(
                        get: { environment.recordsCallsAutomatically },
                        set: { environment.setRecordsCallsAutomatically($0) }
                    )
                )
            } header: {
                Text("Calls")
            } footer: {
                Text(
                    "A call is a call app such as Zoom, Teams, FaceTime or Discord, or a browser, using a "
                        + "microphone. Without automatic recording, the notifications ask whether to record and "
                        + "whether to stop; with it, they say that recording started and stopped. Recording "
                        + "turns on system audio."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                TextField(
                    "Microphone",
                    text: Binding(
                        get: { environment.sourceLabels.microphone },
                        set: { environment.sourceLabels.microphone = $0 }
                    ),
                    prompt: Text(SourceLabels.defaultMicrophone)
                )
                TextField(
                    "System audio",
                    text: Binding(
                        get: { environment.sourceLabels.systemAudio },
                        set: { environment.sourceLabels.systemAudio = $0 }
                    ),
                    prompt: Text(SourceLabels.defaultSystemAudio)
                )
            } header: {
                Text("Speaker Names")
            } footer: {
                Text(
                    "With more than one input, each is transcribed on its own and its lines are labeled "
                        + "with these names. Use headphones so your microphone doesn't pick up the other "
                        + "people; otherwise Mixdown drops lines your microphone only heard from the speakers."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle(
                    "Start and stop recording from any app",
                    isOn: Binding(
                        get: { environment.isRecordingShortcutEnabled },
                        set: { environment.setRecordingShortcutEnabled($0) }
                    )
                )
                // Hidden rather than disabled: the recorder is an AppKit field that ignores
                // SwiftUI's `disabled`.
                if environment.isRecordingShortcutEnabled {
                    KeyboardShortcuts.Recorder("Shortcut", name: .toggleRecording)
                }
            } header: {
                Text("Global Shortcut")
            } footer: {
                Text(
                    "Works while Mixdown is in the background. If recording can't start yet, Mixdown "
                        + "opens to show why."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
