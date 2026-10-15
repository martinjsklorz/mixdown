import AppKit
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
                    "Ask before moving a note to the Trash",
                    isOn: Binding(
                        get: { !suppressesTrashConfirmation },
                        set: { suppressesTrashConfirmation = !$0 }
                    )
                )
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
