import Foundation
import MixdownNotes
import Observation

/// What the main window's note browser does with the notes: searching them, picking the
/// selection as they change, and renaming, pinning and trashing them. One for the whole app (see
/// `AppEnvironment.noteBrowser`), next to the `library` it shows; `MainView` only lays it out and
/// asks for what it needs.
@MainActor @Observable
final class NoteBrowserModel {
    /// An action on a note that didn't work, for an alert.
    struct Failure {
        var title: String
        var message: String
    }

    var searchText = ""
    /// The notes the latest finished search matched, with the line of each that matches, which
    /// the sidebar shows while the next one runs. `nil` while not searching.
    private(set) var searchMatches: [NoteDocument.ID: String]?
    /// Set when an action on a note fails; the main window shows it and clears it.
    var failure: Failure?

    private let library: NoteLibraryModel
    private let notesFolder: NotesFolderStore
    private let noteTrash: NoteTrash
    private let navigation: MainNavigation
    /// Flows still running that pick the selection themselves, such as `reload(selecting:line:)`,
    /// so `notesChanged()` leaves it alone meanwhile.
    @ObservationIgnored private var pendingSelections = 0

    init(library: NoteLibraryModel, notesFolder: NotesFolderStore, noteTrash: NoteTrash, navigation: MainNavigation) {
        self.library = library
        self.notesFolder = notesFolder
        self.noteTrash = noteTrash
        self.navigation = navigation
    }

    // MARK: Search

    /// `searchText` without the spaces around it; empty while not searching.
    var searchQuery: String { searchText.trimmingCharacters(in: .whitespaces) }

    /// The notes that match the search, from the latest search that finished. All of them until
    /// the first one has.
    var filteredNotes: [NoteDocument] {
        guard !searchQuery.isEmpty, let searchMatches else { return library.notes }
        return library.notes.filter { searchMatches[$0.id] != nil }
    }

    /// The `filteredNotes` the sidebar shows, in its order: pinned ones first, unless they're
    /// folded away.
    func sidebarNotes(collapsesPinned: Bool) -> [NoteDocument] {
        NoteSection.sections(for: filteredNotes)
            .filter { !(collapsesPinned && $0.group == .pinned) }
            .flatMap(\.notes)
    }

    /// Sets `searchMatches` to the notes of `notes` that match `query`, unless cancelled first.
    /// Off the main thread, as long transcripts take a while to look through.
    func search(_ query: String, in notes: [NoteDocument]) async {
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

    // MARK: Selection

    /// Reloads the folder, then selects the note at `url` if given, else keeps the selection if
    /// that note still exists, else selects the newest note. With a `line` of the note at `url`
    /// (see `MainNavigation.noteLineToShow`), has its view scroll to it.
    func reload(selecting url: URL? = nil, line: Int? = nil) async {
        pendingSelections += 1
        await library.reload(from: notesFolder.directory)
        pendingSelections -= 1
        if let url, let note = NoteLibrary.note(at: url, in: library.notes) {
            navigation.selectedNoteID = note.id
            if let line, let block = NoteSearchIndex.lines(of: note).dropFirst(line).first?.block {
                navigation.blockToShow = MainNavigation.NoteBlock(noteID: note.id, index: block)
            }
        } else {
            keepSelection()
        }
    }

    /// For changes to `library.notes` from elsewhere: a note removed by another app takes the
    /// selection with it.
    func notesChanged() {
        if pendingSelections == 0 { keepSelection() }
    }

    /// Shows the note just recorded or imported at `url`, unless the user moved on to something
    /// else: it's selected from Record, or if no note is, but not over a note being read, nor
    /// over the one Notes would go back to from Chat.
    func showSavedNote(at url: URL?) async {
        let follows = navigation.destination == .recorder || navigation.selectedNoteID == nil
        await reload(selecting: follows ? url : nil)
        if url != nil, navigation.destination == .recorder { navigation.destination = .notes }
    }

    /// Selects the newest note if the selected one is gone.
    private func keepSelection() {
        if !library.notes.contains(where: { $0.id == navigation.selectedNoteID }) {
            navigation.selectedNoteID = library.notes.first?.id
        }
    }

    // MARK: Actions

    func rename(_ note: NoteDocument, to title: String) async {
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

    func renameSpeaker(_ speaker: String, to name: String, in note: NoteDocument) async {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try await library.renameSpeaker(speaker, to: name, in: note)
        } catch {
            failure = Failure(title: "Couldn't Rename Speaker", message: error.localizedDescription)
        }
        await reload()
    }

    func setPinned(_ isPinned: Bool, _ note: NoteDocument) async {
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
    /// sidebar, or the one above if it was the last. `collapsesPinned` is whether the sidebar
    /// folds the pinned notes away, which leaves them out of that.
    func moveToTrash(_ note: NoteDocument, collapsesPinned: Bool) async {
        let sidebarNotes = sidebarNotes(collapsesPinned: collapsesPinned)
        pendingSelections += 1
        defer { pendingSelections -= 1 }
        do {
            try await noteTrash.moveToTrash(note)
            library.didRemove(note)
        } catch {
            failure = Failure(title: "Couldn't Delete Note", message: error.localizedDescription)
            return
        }
        if navigation.selectedNoteID == note.id {
            navigation.selectedNoteID = NoteSection.selectionAfterRemoving(note.id, from: sidebarNotes)
        }
        await reload()
    }
}
