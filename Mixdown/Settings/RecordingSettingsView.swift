import MixdownCore
import SwiftUI

/// Which inputs to record, and what happens when a call starts. The same input choice is in the
/// menu bar.
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
        }
        .formStyle(.grouped)
    }
}
