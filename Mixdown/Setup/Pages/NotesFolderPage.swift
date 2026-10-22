import SwiftUI

/// The setup assistant's page for choosing the notes folder, which recording needs.
struct NotesFolderPage: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let notesFolder = environment.notesFolder

        SetupPage(
            title: "Choose a Notes Folder",
            systemImage: "folder",
            detail: "Mixdown saves each recording as a Markdown file, which any editor and Obsidian "
                + "can open. Pick a folder of its own, such as Documents › Mixdown, or one in your vault."
        ) {
            Form {
                Section {
                    NotesFolderPathRow(marksChoice: true)
                    if case .unavailable = notesFolder.status,
                        let warning = NotesFolderWarning.message(
                            for: notesFolder.status,
                            hasLegacyNotes: notesFolder.hasLegacyNotes
                        )
                    {
                        Caption(warning, isWarning: true)
                    }
                    HStack {
                        Spacer()
                        Button(
                            notesFolder.directory == nil ? "Choose Folder…" : "Choose Another Folder…",
                            systemImage: "folder"
                        ) {
                            environment.chooseNotesFolder()
                        }
                    }
                } footer: {
                    Caption(
                        "Use New Folder in the dialog to make one just for your notes. You can change "
                            + "it later under Settings → General."
                            + (notesFolder.hasLegacyNotes
                                ? " The notes you've already recorded move there too." : "")
                    )
                }
            }
            .formStyle(.grouped)
        }
    }
}
