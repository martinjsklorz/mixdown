import KeyboardShortcuts
import SwiftUI

struct GeneralSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    private var preferences: Preferences { environment.preferences }
    @AppStorage(AppSettings.Key.suppressesTrashConfirmation) private var suppressesTrashConfirmation = false

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
                    isOn: Binding(
                        get: { preferences.indexesNotesInSpotlight },
                        set: { preferences.indexesNotesInSpotlight = $0 }
                    )
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
                    selection: Binding(
                        get: { preferences.catchUpMinutes },
                        set: { preferences.catchUpMinutes = $0 }
                    )
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
        }
        .formStyle(.grouped)
    }
}
