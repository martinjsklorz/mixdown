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
    @State private var searchText = ""
    /// The notes the latest finished search matched, which the sidebar shows while the next one
    /// runs. `nil` while not searching.
    @State private var searchMatches: Set<NoteDocument.ID>?
    /// Calls to `reload(selecting:line:)` still running, which pick the selection themselves.
    @State private var pendingReloads = 0
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic
    @State private var noteToRename: NoteDocument?
    /// The speaker to rename and their note, while asking for the new name.
    @State private var speakerToRename: SpeakerToRename?
    @State private var speakerDraft = ""
    @State private var noteToTrash: NoteDocument?
    /// What to fill in as heard when adding to the vocabulary, while its sheet is open.
    @State private var vocabularyDraft: VocabularyDraft?
    @AppStorage(AppSettings.Key.suppressesTrashConfirmation) private var suppressesTrashConfirmation = false
    @AppStorage(AppSettings.Key.showsNotifications) private var showsNotifications = true
    @AppStorage(AppSettings.Key.collapsesPinnedNotes) private var collapsesPinnedNotes = false
    @State private var titleDraft = ""
    @FocusState private var isChatFieldFocused: Bool
    @State private var failure: Failure?

    private struct VocabularyDraft: Identifiable {
        let id = UUID()
        var soundsLike: String
    }

    private struct SpeakerToRename {
        var note: NoteDocument
        var speaker: String
    }

    /// An action on a note that didn't work, for an alert.
    private struct Failure {
        var title: String
        var message: String
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
            await reload(selecting: shown?.url, line: shown?.line)
        }
        // A note removed by another app takes the selection with it.
        .onChange(of: library.notes) {
            if pendingReloads == 0 { keepSelection() }
        }
        // Searches off the main thread, as long transcripts take a while to look through. A new
        // search or a change to the notes cancels the running one.
        .task(id: SearchRequest(query: searchQuery, notes: library.notes)) {
            await search(searchQuery, in: library.notes)
        }
        .onChange(of: environment.coordinator.lastNoteURL) { _, url in
            Task {
                await reload(selecting: url)
                // Show the note that was just recorded, unless the user moved on to something else.
                if url != nil, navigation.destination == .recorder { navigation.destination = .notes }
            }
        }
        // In case the watcher missed a change. FSEvents doesn't see changes made by other
        // computers on a network volume, for one.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await reload() }
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
                showsNotifications
                    ? "You can restore it from the notification or the Trash."
                    : "You can restore it from the Trash."
            )
        }
        // Before the other dialogs, which would get its "Do not ask again" checkbox too.
        .dialogSuppressionToggle(isSuppressed: $suppressesTrashConfirmation)
        .alert("Rename Note", isPresented: isPresent($noteToRename), presenting: noteToRename) { note in
            TextField("Title", text: $titleDraft)
            Button("Rename") {
                Task { await rename(note, to: titleDraft) }
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
                Task { await renameSpeaker(rename.speaker, to: speakerDraft, in: rename.note) }
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
            Task { await reload(selecting: shown?.url, line: shown?.line) }
        }
        // Shows a note put back with Restore in its notification.
        .onChange(of: environment.noteTrash.lastRestored) { _, restored in
            guard let restored else { return }
            Task {
                await reload(selecting: restored.url)
                navigation.destination = .notes
            }
        }
        .alert(failure?.title ?? "", isPresented: isPresent($failure), presenting: failure) { _ in
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

    private var sidebar: some View {
        let notes = filteredNotes

        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                SidebarSearchField(text: $searchText)
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
            actions: noteActions
        ) {
            notesPlaceholder(isEmptyAfterSearch: notes.isEmpty)
        }
    }

    /// "49 notes", or "3 of 49 notes" while searching.
    private func noteCount(shown: Int) -> some View {
        let total = library.notes.count
        return Group {
            if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
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
            } else if isEmptyAfterSearch && !searchText.isEmpty {
                Text("No recordings match “\(searchText)”.")
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
                Task { await setPinned(!note.isPinned, note) }
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

    private func rename(_ note: NoteDocument, to title: String) async {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title != note.title else { return }
        let wasSelected = navigation.selectedNoteID == note.id
        do {
            let url = try await library.rename(note, to: title)
            await reload(selecting: wasSelected ? url : nil)
        } catch {
            failure = Failure(title: "Couldn't Rename Note", message: error.localizedDescription)
            // The title may have changed even if the file name couldn't.
            await reload()
        }
    }

    private func renameSpeaker(_ speaker: String, to name: String, in note: NoteDocument) async {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try await library.renameSpeaker(speaker, to: name, in: note)
        } catch {
            failure = Failure(title: "Couldn't Rename Speaker", message: error.localizedDescription)
        }
        await reload()
    }

    private func setPinned(_ isPinned: Bool, _ note: NoteDocument) async {
        do {
            try await library.setPinned(isPinned, note)
        } catch {
            failure = Failure(
                title: isPinned ? "Couldn't Pin Note" : "Couldn't Unpin Note",
                message: error.localizedDescription
            )
            return
        }
        await reload()
    }

    /// Moves the note to the Trash and, if it was selected, selects the one below it in the
    /// sidebar, or the one above if it was the last.
    private func moveToTrash(_ note: NoteDocument) {
        let index = sidebarNotes.firstIndex { $0.id == note.id }
        do {
            try environment.noteTrash.moveToTrash(note)
            library.didRemove(note)
        } catch {
            failure = Failure(title: "Couldn't Delete Note", message: error.localizedDescription)
            return
        }
        if navigation.selectedNoteID == note.id, let index {
            let remaining = sidebarNotes
            navigation.selectedNoteID = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
        }
        Task { await reload() }
    }

    /// The `filteredNotes` the sidebar shows, in its order: pinned ones first, unless they're
    /// folded away.
    private var sidebarNotes: [NoteDocument] {
        NoteSection.sections(for: filteredNotes)
            .filter { !(collapsesPinnedNotes && $0.group == .pinned) }
            .flatMap(\.notes)
    }

    /// The notes that match the search, from the latest search that finished. All of them until
    /// the first one has.
    private var filteredNotes: [NoteDocument] {
        guard !searchQuery.isEmpty, let searchMatches else { return library.notes }
        return library.notes.filter { searchMatches.contains($0.id) }
    }

    private var searchQuery: String { searchText.trimmingCharacters(in: .whitespaces) }

    private struct SearchRequest: Equatable {
        var query: String
        var notes: [NoteDocument]
    }

    /// Sets `searchMatches` to the notes of `notes` that match `query`, unless cancelled first.
    private func search(_ query: String, in notes: [NoteDocument]) async {
        guard !query.isEmpty else {
            searchMatches = nil
            return
        }
        let search = Task.detached(priority: .userInitiated) { try NoteLibrary.search(notes, for: query) }
        let matches = await withTaskCancellationHandler {
            try? await search.value
        } onCancel: {
            search.cancel()
        }
        guard let matches, !Task.isCancelled else { return }
        searchMatches = matches
    }

    /// Reloads the folder, then selects the note at `url` if given, else keeps the selection if
    /// that note still exists, else selects the newest note. With a `line` of the note at `url`
    /// (see `MainNavigation.noteLineToShow`), has its view scroll to it.
    private func reload(selecting url: URL? = nil, line: Int? = nil) async {
        pendingReloads += 1
        await library.reload(from: environment.notesFolder.directory)
        pendingReloads -= 1
        let notes = library.notes
        // By name: the writer's URL and the directory listing's can differ in form. Notes in
        // different subfolders can share a name, so then by resolved path.
        let named = url.map { url in notes.filter { $0.url.lastPathComponent == url.lastPathComponent } } ?? []
        let resolvedPath = { (url: URL) in url.resolvingSymlinksInPath().path(percentEncoded: false) }
        if let url,
            let note = named.count > 1
                ? named.first(where: { resolvedPath($0.url) == resolvedPath(url) }) ?? named.first : named.first
        {
            navigation.selectedNoteID = note.id
            if let line, let block = NoteSearchIndex.lines(of: note).dropFirst(line).first?.block {
                navigation.blockToShow = MainNavigation.NoteBlock(noteID: note.id, index: block)
            }
        } else {
            keepSelection()
        }
    }

    /// Selects the newest note if the selected one is gone.
    private func keepSelection() {
        if !library.notes.contains(where: { $0.id == navigation.selectedNoteID }) {
            navigation.selectedNoteID = library.notes.first?.id
        }
    }
}
