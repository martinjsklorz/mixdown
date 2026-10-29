import AppKit
import MixdownCore
import MixdownNotes
import SwiftUI

/// The main window: search, Chat, Import and Record at the top of the sidebar, the notes folder below it
/// (pinned notes, then by date), and the recorder, the chat or the selected note on the right.
/// Above the sidebar are Open Notes Folder and Settings.
struct MainView: View {
    static let windowID = "main"

    @Environment(AppEnvironment.self) private var environment
    @Environment(MainNavigation.self) private var navigation
    @Environment(\.openSettings) private var openSettings
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic
    @State private var noteToRename: NoteDocument?
    /// The speaker to rename and their note, while asking for the new name.
    @State private var speakerToRename: SpeakerToRename?
    @State private var speakerDraft = ""
    @State private var noteToTrash: NoteDocument?
    /// What to fill in as heard when adding to the vocabulary, while its sheet is open.
    @State private var vocabularyDraft: VocabularyDraft?
    @AppStorage(AppSettings.Key.suppressesTrashConfirmation) private var suppressesTrashConfirmation = false
    @AppStorage(AppSettings.Key.collapsesPinnedNotes) private var collapsesPinnedNotes = false
    @State private var titleDraft = ""
    @FocusState private var isChatFieldFocused: Bool

    private struct VocabularyDraft: Identifiable {
        let id = UUID()
        var soundsLike: String
    }

    private struct SpeakerToRename {
        var note: NoteDocument
        var speaker: String
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 420)
        } detail: {
            detail
                // With the sidebar collapsed, macOS keeps only one of its toolbar items next to
                // the sidebar toggle and moves the rest into the overflow menu, so they move here.
                .toolbar {
                    if isSidebarCollapsed {
                        ToolbarItemGroup(placement: .navigation) { folderAndSettingsButtons }
                    }
                }
        }
        .frame(minWidth: 720, minHeight: 480)
        .toolbar(id: "detail") { detailToolbar }
        // Selects a note once the folder is read; again for each folder the user chooses.
        // `AppEnvironment` keeps the notes up to date as the folder changes.
        .task(id: environment.notesFolder.directory) {
            let shown = navigation.takeNoteToShow()
            await browser.reload(selecting: shown?.url, line: shown?.line)
        }
        // A note removed by another app takes the selection with it.
        .onChange(of: library.notes) { browser.notesChanged() }
        // Searches off the main thread, as long transcripts take a while to look through. A new
        // search or a change to the notes cancels the running one.
        .task(id: SearchRequest(query: browser.searchQuery, notes: library.notes)) {
            await browser.search(browser.searchQuery, in: library.notes)
        }
        .onChange(of: environment.coordinator.lastNoteURL) { _, url in
            Task { await browser.showSavedNote(at: url) }
        }
        // In case the watcher missed a change. FSEvents doesn't see changes made by other
        // computers on a network volume, for one.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await browser.reload() }
        }
        .focusedSceneValue(\.shownNote, shownNote.map { ShownNote(note: $0, actions: noteActions) })
        .confirmationDialog(
            "Delete “\(noteToTrash?.title ?? "")”?",
            isPresented: isPresent($noteToTrash),
            presenting: noteToTrash
        ) { note in
            Button("Delete", role: .destructive) { moveToTrash(note) }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(
                environment.preferences.showsNotifications
                    ? "You can restore it from the notification or the Trash."
                    : "You can restore it from the Trash."
            )
        }
        // Before the other dialogs, which would get its "Do not ask again" checkbox too.
        .dialogSuppressionToggle(isSuppressed: $suppressesTrashConfirmation)
        .alert("Rename Note", isPresented: isPresent($noteToRename), presenting: noteToRename) { note in
            TextField("Title", text: $titleDraft)
            Button("Rename") {
                Task { await browser.rename(note, to: titleDraft) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "Rename “\(speakerToRename?.speaker ?? "")”",
            isPresented: isPresent($speakerToRename),
            presenting: speakerToRename
        ) { rename in
            TextField("Name", text: $speakerDraft)
            Button("Rename") {
                Task { await browser.renameSpeaker(rename.speaker, to: speakerDraft, in: rename.note) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Renames the speaker throughout this note. Give two speakers the same name to merge them.")
        }
        // Shows a note opened from outside the window while it's open, e.g. from its notification.
        // If the window was closed, the `.task` above takes the note when it opens.
        .onChange(of: navigation.noteToShow) { _, url in
            guard url != nil else { return }
            let shown = navigation.takeNoteToShow()
            Task { await browser.reload(selecting: shown?.url, line: shown?.line) }
        }
        // Shows a note put back with Restore in its notification.
        .onChange(of: environment.noteTrash.lastRestored) { _, restored in
            guard let restored else { return }
            Task {
                await browser.reload(selecting: restored.url)
                navigation.destination = .notes
            }
        }
        .alert(
            browser.failure?.title ?? "",
            isPresented: isPresent(Bindable(browser).failure),
            presenting: browser.failure
        ) { _ in
            Button("OK") {}
        } message: { failure in
            Text(failure.message)
        }
        .sheet(item: $vocabularyDraft) { draft in
            AddToVocabularySheet(soundsLike: draft.soundsLike)
                .environment(environment)
        }
        .sheet(
            isPresented: Binding(
                get: { navigation.isShowingSetup },
                set: { navigation.isShowingSetup = $0 }
            )
        ) {
            SetupAssistantView()
                .environment(environment)
                .environment(navigation)
        }
    }

    /// Whether `item` is set; setting it to `false` clears `item`.
    private func isPresent<Item>(_ item: Binding<Item?>) -> Binding<Bool> {
        Binding(
            get: { item.wrappedValue != nil },
            set: { if !$0 { item.wrappedValue = nil } }
        )
    }

    // MARK: Sidebar

    /// The notes `library` has, for the sidebar, Chat and the detail column.
    private var library: NoteLibraryModel { environment.library }

    /// Searches, selects and changes the notes for the sidebar and the detail column.
    private var browser: NoteBrowserModel { environment.noteBrowser }

    private var sidebar: some View {
        let notes = browser.filteredNotes

        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                SidebarSearchField(text: Bindable(browser).searchText)
                if environment.preferences.isChatEnabled {
                    SidebarSectionButton(
                        "Chat",
                        systemImage: "bubble.left.and.text.bubble.right",
                        destination: .chat,
                        help: "Chat with Your Notes (⌘3)"
                    )
                }
                SidebarImportButton()
                SidebarRecordButton(coordinator: environment.coordinator)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 2)

            if !library.notes.isEmpty {
                noteCount(shown: notes.count)
            }
            noteList(notes)
        }
        // Toolbar items on the sidebar sit above it, next to the sidebar toggle.
        .toolbar {
            if !isSidebarCollapsed {
                ToolbarItemGroup { folderAndSettingsButtons }
            }
        }
    }

    private func noteList(_ notes: [NoteDocument]) -> some View {
        NoteListView(
            sections: NoteSection.sections(for: notes),
            selection: Binding(
                get: { navigation.selectedNoteID },
                set: { id in
                    navigation.selectedNoteID = id
                    navigation.destination = .notes
                }
            ),
            showsSelection: navigation.destination == .notes,
            collapsesPinned: $collapsesPinnedNotes,
            excerpts: browser.searchQuery.isEmpty ? [:] : browser.searchMatches ?? [:],
            actions: noteActions
        ) {
            notesPlaceholder(isEmptyAfterSearch: notes.isEmpty)
        }
    }

    /// "49 notes", or "3 of 49 notes" while searching.
    private func noteCount(shown: Int) -> some View {
        let total = library.notes.count
        return Group {
            if browser.searchQuery.isEmpty {
                Text("^[\(total) note](inflect: true)")
            } else {
                Text("\(shown) of ^[\(total) note](inflect: true)")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 6)
    }

    private var isSidebarCollapsed: Bool { columnVisibility == .detailOnly }

    @ViewBuilder
    private var folderAndSettingsButtons: some View {
        Button("Open Notes Folder", systemImage: "folder") { environment.openNotesFolder() }
            .help("Open Notes Folder (⇧⌘O)")
            .disabled(environment.notesFolder.directory == nil)
        Button("Settings", systemImage: "gearshape") { navigation.showSettings(using: openSettings) }
            .help("Settings (⌘,)")
    }

    /// Shown under the section rows when there's no note to list.
    private func notesPlaceholder(isEmptyAfterSearch: Bool) -> some View {
        Group {
            if environment.notesFolder.directory == nil {
                Text(
                    environment.notesFolder.status == .notChosen
                        ? "Notes you record appear here once you choose a folder for them."
                        : "Your notes folder can't be reached."
                )
            } else if let error = library.errorMessage {
                Label("Can't read notes: \(error)", systemImage: "exclamationmark.triangle")
            } else if library.hasLoaded && library.notes.isEmpty {
                Text("Notes you record appear here.")
            } else if isEmptyAfterSearch && !browser.searchText.isEmpty {
                Text("No recordings match “\(browser.searchText)”.")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.top, 16)
    }

    // MARK: Detail

    private var detailToolbar: DetailToolbar {
        DetailToolbar(
            destination: navigation.destination,
            note: shownNote,
            actions: noteActions,
            chat: environment.noteChat,
            isChatFieldFocused: $isChatFieldFocused
        )
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.destination {
        case .recorder:
            RecorderView()
        case .chat:
            ChatView(chat: environment.noteChat, notes: library.notes, isFieldFocused: $isChatFieldFocused)
        case .notes:
            if let note = shownNote {
                NoteDetailView(note: note)
            } else if library.notes.isEmpty {
                ContentUnavailableView(
                    "No Notes",
                    systemImage: "note.text",
                    description: Text("Notes you record appear here.")
                )
            } else {
                ContentUnavailableView("No Note Selected", systemImage: "note.text")
            }
        }
    }

    // MARK: Notes

    /// The note the detail column shows, if any.
    private var shownNote: NoteDocument? {
        guard navigation.destination == .notes else { return nil }
        return library.notes.first { $0.id == navigation.selectedNoteID }
    }

    private var noteActions: NoteActions {
        NoteActions(
            togglePinned: { note in
                Task { await browser.setPinned(!note.isPinned, note) }
            },
            rename: { note in
                titleDraft = note.title
                noteToRename = note
            },
            renameSpeaker: { note, speaker in
                speakerDraft = ""
                speakerToRename = SpeakerToRename(note: note, speaker: speaker)
            },
            moveToTrash: { note in
                if suppressesTrashConfirmation {
                    moveToTrash(note)
                } else {
                    noteToTrash = note
                }
            },
            addToVocabulary: {
                vocabularyDraft = VocabularyDraft(soundsLike: SelectedText.current() ?? "")
            }
        )
    }

    private func moveToTrash(_ note: NoteDocument) {
        Task { await browser.moveToTrash(note, collapsesPinned: collapsesPinnedNotes) }
    }

    private struct SearchRequest: Equatable {
        var query: String
        var notes: [NoteDocument]
    }
}
