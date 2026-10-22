import SwiftUI

/// Where the notes folder is, or that none is chosen. Shared by Settings and the setup assistant.
struct NotesFolderPathRow: View {
    @Environment(AppEnvironment.self) private var environment
    /// Whether to dim "Not chosen" and check a chosen folder, as the setup assistant does. Otherwise
    /// the path can be selected, to copy it.
    var marksChoice = false

    var body: some View {
        let notesFolder = environment.notesFolder

        LabeledContent("Folder") {
            if marksChoice {
                HStack {
                    path
                        .foregroundStyle(notesFolder.directory == nil ? Color.secondary : Color.primary)
                    if notesFolder.directory != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .accessibilityLabel("Chosen")
                    }
                }
            } else {
                path
                    .textSelection(.enabled)
            }
        }
    }

    private var path: some View {
        let path = environment.notesFolder.status.path
        return Text(path ?? "Not chosen")
            .lineLimit(1)
            .truncationMode(.middle)
            .help(path ?? "")
    }
}
