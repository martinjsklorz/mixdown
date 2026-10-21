import AppKit
import KeyboardShortcuts
import SwiftUI

struct GeneralSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var launchAtLogin = LaunchAtLogin()
    @AppStorage(AppSettings.Key.suppressesTrashConfirmation) private var suppressesTrashConfirmation = false

    var body: some View {
        let notesFolder = environment.notesFolder

        Form {
            Section("Notes") {
                LabeledContent("Folder") {
                    Text(notesFolder.status.path ?? "Not chosen")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(notesFolder.status.path ?? "")
                }
                if let warning = NotesFolderWarning.message(
                    for: notesFolder.status,
                    hasLegacyNotes: notesFolder.hasLegacyNotes
                ) {
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(notesFolder.status == .notChosen ? Color.secondary : Color.red)
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
                        get: { environment.indexesNotesInSpotlight },
                        set: { environment.setIndexesNotesInSpotlight($0) }
                    )
                )
                Text("Search for any line of a note with Spotlight (⌘Space). The index stays on this Mac.")
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
                KeyboardShortcuts.Recorder("Mark moment while recording", name: .markMoment)
            } header: {
                Text("Global Shortcuts")
            } footer: {
                Text(
                    "Work while Mixdown is in the background. If recording can't start yet, Mixdown "
                        + "opens to show why. Marking a moment opens a field under the notch for a "
                        + "note on it; clear the shortcut to turn it off."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle(
                    "Launch Mixdown at login",
                    isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.setEnabled($0) }
                    )
                )
                if launchAtLogin.requiresApproval {
                    Text("Allow Mixdown in System Settings › General › Login Items.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = launchAtLogin.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        // The user can change it in System Settings › General › Login Items, so re-read on switching
        // to this tab, and whenever a window of ours comes back to the front: on reopening Settings
        // (which keeps this view alive) and on returning from System Settings.
        .onAppear { launchAtLogin.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            launchAtLogin.refresh()
        }
    }
}
