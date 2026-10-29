import AppKit
import MixdownCore
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
    /// Summarizes the note again with the template, replacing its summary.
    var summarizeAgain: @MainActor (NoteDocument, SummaryTemplate) -> Void

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

/// A menu of the summary templates, each summarizing the note again with it; the note's own is
/// checked. Disabled while summaries can't be made, or a note is being summarized again.
struct SummarizeAgainMenu<Label: View>: View {
    @Environment(AppEnvironment.self) private var environment
    let note: NoteDocument
    let actions: NoteActions
    @ViewBuilder let label: () -> Label

    var body: some View {
        Menu {
            ForEach(templates) { template in
                Toggle(
                    template.displayName,
                    isOn: Binding(
                        get: { template.id == currentTemplate.id },
                        set: { _ in actions.summarizeAgain(note, template) }
                    )
                )
            }
        } label: {
            label()
        }
        .disabled(unavailableReason != nil || environment.library.summarizingNoteID != nil)
        .help(unavailableReason ?? "Summarize the note again, with this template or another")
    }

    private var templates: [SummaryTemplate] { environment.preferences.summaryTemplates.templates }

    /// The note's template: its `template` field is a built-in's id or the name of one of the
    /// user's. General without one.
    private var currentTemplate: SummaryTemplate {
        templates.first { $0.id == note.template || (!$0.isBuiltIn && $0.displayName == note.template) }
            ?? environment.preferences.summaryTemplates.template(id: nil)
    }

    private var unavailableReason: String? {
        guard environment.preferences.summarizesNotes else { return "Summaries are turned off in Settings" }
        if case .unavailable(let reason) = environment.summaryAvailability { return reason }
        return nil
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
