import MixdownCore
import SwiftUI

/// Which inputs to record, and what happens when a call starts. The same input choice is in the
/// menu bar.
struct RecordingSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    private var preferences: Preferences { environment.preferences }

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
                            get: { preferences.cancelsEcho },
                            set: { preferences.cancelsEcho = $0 }
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

                Section {
                    Toggle(
                        "Measure talk time",
                        isOn: Binding(
                            get: { preferences.measuresTalkTime },
                            set: { preferences.measuresTalkTime = $0 }
                        )
                    )
                } header: {
                    Text("Talk Time")
                } footer: {
                    Caption(
                        "While your microphone and system audio both record, Mixdown times how long you "
                            + "and the others talk. The note gets a chart of each minute, and the Dynamic "
                            + "Island can show your share as a ring. Applies from the next recording."
                    )
                }
            }

            Section {
                Picker(
                    "Ask if still recording after",
                    selection: Binding(
                        get: { preferences.stillRecordingMinutes },
                        set: { preferences.stillRecordingMinutes = $0 }
                    )
                ) {
                    ForEach(AppSettings.stillRecordingMinuteChoices, id: \.self) { minutes in
                        Text("\(minutes) Minutes").tag(minutes)
                    }
                    Divider()
                    Text("Never").tag(0)
                }
            } header: {
                Text("Silence")
            } footer: {
                Caption(
                    "When no one has spoken for this long, Mixdown asks whether you're still recording, "
                        + "in a notification, on Record and in the menu bar, in case a meeting ended and the "
                        + "recording was left running. Answer Stop Recording or Keep Recording, or just "
                        + "speak. Time paused doesn't count."
                )
            }

            Section {
                Picker(
                    "Keep audio until the note is saved",
                    selection: Binding(
                        get: { preferences.keepsAudioOnDisk },
                        set: { preferences.keepsAudioOnDisk = $0 }
                    )
                ) {
                    Text("On Disk").tag(true)
                    Text("In Memory Only").tag(false)
                }
            } header: {
                Text("Audio")
            } footer: {
                Caption(
                    "On disk, the audio is written to Mixdown's container as you record and deleted once "
                        + "the note is saved, so quitting, a crash or a failed transcription doesn't lose it. "
                        + "In memory only, no audio is written: a recording that couldn't be transcribed can "
                        + "be tried again until Mixdown quits, but a crash loses it. Applies from the next "
                        + "recording."
                )
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
