import MixdownNotes
import SwiftUI

/// The detail column's toolbar for every destination: the note's buttons and Share, or New Chat.
///
/// Its items stay the same whichever is shown; only what they hold changes, and they draw their
/// own glass. Whenever the toolbar's items change, even just by hiding one, macOS redraws the whole
/// toolbar, so Open Notes Folder, Settings and the sidebar toggle would flicker on every switch
/// between the recorder, a note and the chat. The fixed IDs keep SwiftUI from making new items
/// whenever what they hold changes, and `hidden(_:)` and `sharedBackgroundVisibility(_:)` keep
/// whatever they're first set to in a toolbar with IDs.
struct DetailToolbar: CustomizableToolbarContent {
    let destination: MainNavigation.Destination
    /// The note shown, if any.
    let note: NoteDocument?
    let actions: NoteActions
    let chat: NoteChat
    let isChatFieldFocused: FocusState<Bool>.Binding

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "noteActions") {
            HStack(spacing: 0) {
                if let note {
                    Button(
                        note.isPinned ? "Unpin" : "Pin",
                        systemImage: note.isPinned ? "pin.slash" : "pin"
                    ) { actions.togglePinned(note) }
                    Button("Copy Transcript", systemImage: "doc.on.doc") { NoteActions.copyTranscript(of: note) }
                    Button("Rename", systemImage: "pencil") { actions.rename(note) }
                    RenameSpeakerMenu(note: note, actions: actions) {
                        Label("Rename Speaker", systemImage: "person.2")
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .help("Rename a speaker")
                    Button("Add to Vocabulary", systemImage: "character.book.closed") { actions.addToVocabulary() }
                        .help("Add the selected word to the vocabulary")
                    SummarizeAgainMenu(note: note, actions: actions) {
                        Label("Summarize Again", systemImage: "sparkles")
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    Button("Delete", systemImage: "trash") { actions.moveToTrash(note) }
                }
            }
            .toolbarGlass(isVisible: note != nil, padding: 3)
        }
        .sharedBackgroundVisibility(.hidden)
        // Editing and sharing apart; otherwise they'd all share one glass background.
        ToolbarSpacer(.fixed)
        // Share for a note, New Chat for the chat.
        ToolbarItem(id: "trailing") {
            HStack(spacing: 0) {
                if let note {
                    ShareLink(item: note.url, preview: SharePreview(note.title))
                } else if destination == .chat {
                    Button("New Chat", systemImage: "square.and.pencil") {
                        chat.clear()
                        isChatFieldFocused.wrappedValue = true
                    }
                    .help("New Chat")
                    .disabled(chat.messages.isEmpty)
                }
            }
            .toolbarGlass(isVisible: note != nil || destination == .chat, padding: 0.5)
        }
        .sharedBackgroundVisibility(.hidden)
    }
}

extension View {
    /// The glass toolbar items get from the toolbar, drawn here so it can come and go without
    /// changing the toolbar itself. `padding` matches the toolbar's: a few points around a
    /// group, a circle around one button.
    fileprivate func toolbarGlass(isVisible: Bool, padding: CGFloat) -> some View {
        labelStyle(ToolbarIconLabelStyle())
            .buttonStyle(.borderless)
            .padding(.horizontal, padding)
            .glassEffect(isVisible ? .regular.interactive() : .identity, in: .capsule)
    }
}

/// The icon alone, sized like a toolbar button's.
private struct ToolbarIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.icon
            .font(.system(size: 15))
            .frame(width: 35, height: 36)
            .contentShape(.rect)
    }
}
