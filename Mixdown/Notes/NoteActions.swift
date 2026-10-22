import AppKit
import MixdownNotes
import SwiftUI

/// What can be done to a note from the sidebar, the note's toolbar and the menu bar. `MainView`
/// supplies the actions that change the notes folder, so it can reload and keep a selection.
struct NoteActions {
    /// Pins the note if it isn't, listing it above the others, and unpins it if it is.
    var togglePinned: @MainActor (NoteDocument) -> Void
    /// Asks for a new title, then renames the note and its file.
    var rename: @MainActor (NoteDocument) -> Void
    /// Asks for a new name for one of the note's `speakers`, then renames them throughout it.
    var renameSpeaker: @MainActor (NoteDocument, String) -> Void
    /// Asks for confirmation unless the user turned that off, then moves the note to the Trash.
    var moveToTrash: @MainActor (NoteDocument) -> Void
    /// Asks how to write the text selected in the note, if any, and adds it to the vocabulary.
    var addToVocabulary: @MainActor () -> Void

    /// Puts the note's transcript on the clipboard as plain text, and confirms with a
    /// notification.
    @MainActor
    static func copyTranscript(of note: NoteDocument) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(note.transcriptText, forType: .string)
        Task { await Notifications.post(title: "Transcript Copied", body: note.title) }
    }
}

/// A menu of the note's speakers, each renaming that speaker; disabled for a note without any.
struct RenameSpeakerMenu<Label: View>: View {
    let note: NoteDocument
    let actions: NoteActions
    @ViewBuilder let label: () -> Label

    var body: some View {
        Menu {
            ForEach(note.speakers, id: \.self) { speaker in
                Button("\(speaker)…") { actions.renameSpeaker(note, speaker) }
            }
        } label: {
            label()
        }
        .disabled(note.speakers.isEmpty)
    }
}

/// The note the main window shows and what can be done to it, for the menu bar's commands.
struct ShownNote {
    let note: NoteDocument
    let actions: NoteActions
}

extension FocusedValues {
    /// `nil` unless the main window is key and shows a note.
    @Entry var shownNote: ShownNote?
}
