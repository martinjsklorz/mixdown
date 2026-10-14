import MixdownCore
import SwiftUI

/// Which inputs to record and how to label them. The same choice is in the menu bar; this tab adds
/// the speaker names and explains how multi-source recordings are transcribed.
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
        }
        .formStyle(.grouped)
    }
}
