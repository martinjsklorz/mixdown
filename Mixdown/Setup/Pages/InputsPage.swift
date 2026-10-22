import MixdownAudio
import SwiftUI

/// The setup assistant's page for the inputs to record and their permissions.
struct InputsPage: View {
    @State private var microphoneAccess = AudioPermissions.microphoneStatus()

    var body: some View {
        SetupPage(
            title: "What to Record",
            systemImage: "mic",
            detail: "Record your microphone for voice notes and meetings in the room. Add system audio "
                + "to hear the other people on a call too."
        ) {
            Form {
                Section {
                    MicrophonePicker()
                    SystemAudioToggle()
                } footer: {
                    Caption(
                        "System Default follows the Mac's input, so connecting AirPods switches to them. "
                            + "Change inputs any time in the Recording menu."
                    )
                }

                Section("Permissions") {
                    LabeledContent("Microphone") {
                        microphoneAccessControl
                    }
                    if microphoneAccess == .denied {
                        Caption(
                            "Turned off for Mixdown. Turn it on in System Settings › Privacy & Security "
                                + "› Microphone.",
                            isWarning: true
                        )
                    }
                    LabeledContent("System audio") {
                        Text("Asked the first time")
                            .foregroundStyle(.secondary)
                    }
                    Caption(
                        "macOS asks the first time you record system audio. Choose Allow, or Mixdown "
                            + "records silence."
                    )
                }
            }
            .formStyle(.grouped)
        }
        // The user can change it in System Settings, so re-read on coming back from there.
        .onWindowBecomesKey { microphoneAccess = AudioPermissions.microphoneStatus() }
    }

    @ViewBuilder
    private var microphoneAccessControl: some View {
        switch microphoneAccess {
        case .granted:
            DoneLabel("Allowed")
        case .notDetermined:
            Button("Allow…") {
                Task {
                    _ = await AudioPermissions.requestMicrophoneAccess()
                    microphoneAccess = AudioPermissions.microphoneStatus()
                }
            }
        case .denied:
            Button("Open System Settings") { SystemSettings.open(.microphone) }
        }
    }
}
