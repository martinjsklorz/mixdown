import AppKit
import Combine
import MixdownNotes
import SwiftUI

/// The Notes window: the notes folder as a list on the left, the selected note on the right.
/// Read-only for now.
struct NotesView: View {
    static let windowID = "notes"

    @Environment(AppEnvironment.self) private var environment
    @State private var library = NoteLibraryModel()
    @State private var selection: NoteDocument.ID?
    @State private var searchText = ""

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 420)
        } detail: {
            if let note = library.notes.first(where: { $0.id == selection }) {
                NoteDetailView(note: note)
            } else if !library.notes.isEmpty {
                ContentUnavailableView("No Note Selected", systemImage: "note.text")
            }
        }
        .searchable(text: $searchText, placement: .sidebar)
        .frame(minWidth: 640, minHeight: 360)
        .task(id: environment.notesFolder.directory) { await reload() }
        .onChange(of: environment.coordinator.lastNoteURL) { _, url in
            Task { await reload(selecting: url) }
        }
        // Picks up notes edited, added or removed in other apps when the user comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await reload() }
        }
        // Menu bar agents aren't active when the menu is used, so bring the window forward.
        .onAppear { NSApp.activate() }
    }

    @ViewBuilder private var sidebar: some View {
        let notes = filteredNotes
        if let error = library.errorMessage {
            ContentUnavailableView(
                "Can't Read Notes",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else if library.hasLoaded && library.notes.isEmpty {
            ContentUnavailableView(
                "No Notes",
                systemImage: "note.text",
                description: Text("Notes you record appear here.")
            )
        } else if notes.isEmpty && !searchText.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            NoteListView(sections: NoteSection.sections(for: notes), selection: $selection)
        }
    }

    private var filteredNotes: [NoteDocument] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return library.notes }
        return library.notes.filter {
            $0.title.localizedStandardContains(query) || $0.body.localizedStandardContains(query)
        }
    }

    /// Reloads the folder, then selects the note at `url` if given, else keeps the selection if
    /// that note still exists, else selects the newest note.
    private func reload(selecting url: URL? = nil) async {
        await library.reload(from: environment.notesFolder.directory)
        let notes = library.notes
        // By name: the writer's URL and the directory listing's can differ in form.
        if let url, let note = notes.first(where: { $0.url.lastPathComponent == url.lastPathComponent }) {
            selection = note.id
        } else if !notes.contains(where: { $0.id == selection }) {
            selection = notes.first?.id
        }
    }
}
