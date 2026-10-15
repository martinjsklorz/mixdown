import SwiftUI

struct GeneralSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var launchAtLogin = LaunchAtLogin()

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
        .onAppear { launchAtLogin.refresh() }
    }
}
