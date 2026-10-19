import AppKit
import MixdownCore
import SwiftUI

/// Notifications and the sounds that mark recording starting, pausing, stopping and finishing.
struct NotificationsSettingsView: View {
    @AppStorage(AppSettings.Key.showsNotifications) private var showsNotifications = true
    @AppStorage(AppSettings.Key.playsSounds) private var playsSounds = true
    @State private var notificationsDeniedBySystem = false

    var body: some View {
        Form {
            Section {
                Toggle("Show notifications", isOn: $showsNotifications)
                if showsNotifications, notificationsDeniedBySystem {
                    HStack {
                        Text("Turned off for Mixdown in System Settings.")
                            .font(.caption)
                            .foregroundStyle(.red)
                        Spacer()
                        Button("Open System Settings") { Notifications.openSystemSettings() }
                    }
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text("Confirm copying a transcript, and offer Restore after deleting a note.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Play sounds", isOn: $playsSounds)
                ForEach(AudioCue.allCases) { cue in
                    AudioCuePicker(cue: cue)
                        .disabled(!playsSounds)
                }
            } header: {
                Text("Sounds")
            } footer: {
                Text("Choosing a sound plays it. Without headphones, the microphone can pick up the start sound.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // The user can turn notifications off in System Settings › Notifications, so re-read on
        // switching to this tab, and whenever a window of ours comes back to the front: on reopening
        // Settings (which keeps this view alive) and on returning from System Settings.
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            refresh()
        }
    }

    private func refresh() {
        Task { notificationsDeniedBySystem = await Notifications.isDeniedBySystem() }
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
