import KeyboardShortcuts
import SwiftUI

struct GeneralSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    private var preferences: Preferences { environment.preferences }
    @AppStorage(.suppressesTrashConfirmation) private var suppressesTrashConfirmation: Bool

    var body: some View {
        let notesFolder = environment.notesFolder

        Form {
            Section("Notes") {
                NotesFolderPathRow()
                if let warning = NotesFolderWarning.message(
                    for: notesFolder.status,
                    hasLegacyNotes: notesFolder.hasLegacyNotes
                ) {
                    Caption(warning, isWarning: notesFolder.status != .notChosen)
                }
                HStack {
                    Button("Choose…") { environment.chooseNotesFolder() }
                    if case .unavailable = notesFolder.status {
                        Button("Try Again") { notesFolder.refresh() }
                    }
                    Spacer()
                    Button("Show in Finder") { environment.openNotesFolder() }
                        .disabled(notesFolder.directory == nil)
                }
                Toggle(
                    "Ask before deleting a note",
                    isOn: Binding(
                        get: { !suppressesTrashConfirmation },
                        set: { suppressesTrashConfirmation = !$0 }
                    )
                )
                Toggle(
                    "Show notes in Spotlight",
                    isOn: Bindable(preferences).indexesNotesInSpotlight
                )
                Caption("Search for any line of a note with Spotlight (⌘Space). The index stays on this Mac.")
            }

            Section("Chat") {
                Toggle(
                    "Chat with your notes",
                    isOn: Binding(
                        get: { preferences.isChatEnabled },
                        set: { environment.setChatEnabled($0) }
                    )
                )
                Caption(
                    "Ask questions across all your notes under Chat (⌘3). Apple Intelligence answers "
                        + "on this Mac from the lines that match best. Off, Chat leaves the sidebar "
                        + "and Mixdown stops reading your notes for it."
                )
            }

            Section {
                RecordingShortcutToggle()
                KeyboardShortcuts.Recorder("Mark moment while recording", name: .markMoment)
                KeyboardShortcuts.Recorder("Catch me up while recording", name: .catchUp)
                Picker(
                    "Catch up on the last",
                    selection: Bindable(preferences).catchUpMinutes
                ) {
                    ForEach(AppSettings.catchUpMinuteChoices, id: \.self) { minutes in
                        Text(minutes == 1 ? "Minute" : "\(minutes) Minutes").tag(minutes)
                    }
                }
            } header: {
                Text("Global Shortcuts")
            } footer: {
                Caption(
                    "Work while Mixdown is in the background. If recording can't start yet, Mixdown "
                        + "opens to show why. Marking a moment opens a field under the notch for a "
                        + "note on it. Catching up has Apple Intelligence sum up what was just said, "
                        + "on this Mac, with a live speech model. Clear a shortcut to turn it off."
                )
            }

            Section("Startup") {
                LaunchAtLoginToggle()
            }

            UpdatesSection()
        }
        .formStyle(.grouped)
    }
}

/// Only in release builds, which have an updater. Sparkle asks on the second launch whether to
/// check automatically; these change the answer.
private struct UpdatesSection: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        @Bindable var updater = environment.updater
        if updater.isAvailable {
            Section {
                Toggle("Check for updates automatically", isOn: $updater.automaticallyChecksForUpdates)
                Toggle("Download and install updates automatically", isOn: $updater.automaticallyDownloadsUpdates)
                    .disabled(!updater.automaticallyChecksForUpdates)
                HStack {
                    Caption("Mixdown \(Bundle.main.versionDescription)")
                    Spacer()
                    Button("Check Now") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                }
            } header: {
                Text("Updates")
            } footer: {
                Caption(
                    "Mixdown looks for new versions on GitHub once a day, sending only its version, "
                        + "nothing about you or your notes. Updates downloaded automatically are installed when you quit."
                )
            }
        }
    }
}

extension Bundle {
    /// “0.2.0 (318)”, from the version and build in Info.plist.
    fileprivate var versionDescription: String {
        let version = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }
}
