import MixdownCore
import SwiftUI

/// Which inputs to record, and what happens when a call starts. The same input choice is in the
/// menu bar.
struct RecordingSettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let hasSystemAudio = environment.coordinator.devices.contains { $0.kind == .systemAudio }

        Form {
            Section {
                MicrophonePicker()
                SystemAudioToggle()
            } header: {
                Text("Inputs")
            } footer: {
                Caption(
                    "Record your microphone and system audio together to capture both sides of a call. "
                        + "At least one input stays on. Changes apply right away, even while recording, "
                        + "and if the microphone is disconnected, recording continues with the default one. "
                        + "System Default always uses the Mac's input, so connecting AirPods switches to them."
                )
            }

            if hasSystemAudio {
                Section {
                    Toggle(
                        "Remove echo from the microphone",
                        isOn: Binding(
                            get: { environment.cancelsEcho },
                            set: { environment.cancelsEcho = $0 }
                        )
                    )
                } header: {
                    Text("Echo")
                } footer: {
                    Caption(
                        "Without headphones, your microphone also hears the system audio from your speakers. "
                            + "While both record, Mixdown takes that echo out of the microphone, so the others "
                            + "aren't transcribed twice. Applies from the next recording."
                    )
                }
            }

            Section {
                CallsToggles()
            } header: {
                Text("Calls")
            } footer: {
                Caption(
                    "A call is a call app such as Zoom, Teams, FaceTime or Discord, or a browser, using a "
                        + "microphone. Without automatic recording, the notifications ask whether to record and "
                        + "whether to stop; with it, they say that recording started and stopped. Recording "
                        + "turns on system audio."
                )
            }
        }
        .formStyle(.grouped)
    }
}
