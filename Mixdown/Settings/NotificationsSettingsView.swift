import MixdownCore
import SwiftUI

/// Notifications and the sounds that mark recording starting, pausing, stopping and finishing.
struct NotificationsSettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        @Bindable var preferences = environment.preferences
        Form {
            Section {
                NotificationsToggle()
            } header: {
                Text("Notifications")
            } footer: {
                Caption(NotificationsToggle.footer)
            }

            Section {
                Toggle("Play sounds", isOn: $preferences.playsSounds)
                ForEach(AudioCue.allCases) { cue in
                    AudioCuePicker(cue: cue)
                        .disabled(!preferences.playsSounds)
                }
            } header: {
                Text("Sounds")
            } footer: {
                Caption("Choosing a sound plays it. Without headphones, the microphone can pick up the start sound.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Picks the sound for one cue, playing it on choosing.
private struct AudioCuePicker: View {
    let cue: AudioCue
    @AppStorage private var sound: String

    init(cue: AudioCue) {
        self.cue = cue
        _sound = AppStorage(wrappedValue: cue.defaultSound, AppSettings.Key.sound(for: cue))
    }

    var body: some View {
        Picker(cue.title, selection: $sound) {
            Text("None").tag("")
            Divider()
            ForEach(AudioCues.availableSounds, id: \.self) { name in
                Text(name).tag(name)
            }
        }
        .onChange(of: sound) { _, name in AudioCues.play(named: name) }
    }
}
