import AppKit
import Combine
import MixdownCore
import MixdownNotes
import SwiftUI

/// The main window: Record at the top of the sidebar, the notes folder by day below it, and the
/// recorder or the selected note on the right. Above the sidebar are the notes folder and Settings.
struct MainView: View {
    static let windowID = "main"

    @Environment(AppEnvironment.self) private var environment
    @Environment(MainNavigation.self) private var navigation
    @Environment(\.openSettings) private var openSettings
    @State private var library = NoteLibraryModel()
    @State private var searchText = ""
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic
    @State private var noteToRename: NoteDocument?
    @State private var noteToTrash: NoteDocument?
    @AppStorage(AppSettings.Key.suppressesTrashConfirmation) private var suppressesTrashConfirmation = false
    @AppStorage(AppSettings.Key.showsNotifications) private var showsNotifications = true
    @State private var titleDraft = ""
    @State private var failure: Failure?

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
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search Recordings")
        .frame(minWidth: 720, minHeight: 480)
        .task(id: environment.notesFolder.directory) { await reload() }
        .onChange(of: environment.coordinator.lastNoteURL) { _, url in
            Task {
                await reload(selecting: url)
                // Show the note that was just recorded, unless the user moved on to something else.
                if url != nil, navigation.destination == .recorder { navigation.destination = .notes }
            }
        }
        // Picks up notes edited, added or removed in other apps when the user comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await reload() }
        }
        .focusedSceneValue(\.shownNote, shownNote.map { ShownNote(note: $0, actions: noteActions) })
        .confirmationDialog(
            "Move “\(noteToTrash?.title ?? "")” to the Trash?",
            isPresented: isPresent($noteToTrash),
            presenting: noteToTrash
        ) { note in
            Button("Move to Trash", role: .destructive) { moveToTrash(note) }
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
    }

    /// Whether `item` is set; setting it to `false` clears `item`.
    private func isPresent<Item>(_ item: Binding<Item?>) -> Binding<Bool> {
        Binding(
            get: { item.wrappedValue != nil },
            set: { if !$0 { item.wrappedValue = nil } }
        )
    }

    // MARK: Sidebar

    private var sidebar: some View {
        let notes = filteredNotes

        return NoteListView(
            sections: NoteSection.sections(for: notes),
            selection: Binding(
                get: { navigation.selectedNoteID },
                set: { id in
                    navigation.selectedNoteID = id
                    navigation.destination = .notes
                }
            ),
            showsSelection: navigation.destination == .notes,
            actions: noteActions
        ) {
            SidebarRow("Record", systemImage: "record.circle", destination: .recorder) {
                RecorderStatusBadge(coordinator: environment.coordinator)
            }
        } footer: {
            notesPlaceholder(isEmptyAfterSearch: notes.isEmpty)
        }
        // Toolbar items on the sidebar sit above it, next to the sidebar toggle.
        .toolbar {
            if !isSidebarCollapsed {
                ToolbarItemGroup { folderAndSettingsButtons }
            }
        }
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

    @ViewBuilder
    private var detail: some View {
        switch navigation.destination {
        case .recorder:
            RecorderView()
        case .notes:
            if let note = shownNote {
                NoteDetailView(note: note, actions: noteActions)
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
            rename: { note in
                titleDraft = note.title
                noteToRename = note
            },
            moveToTrash: { note in
                if suppressesTrashConfirmation {
                    moveToTrash(note)
                } else {
                    noteToTrash = note
                }
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

    /// Moves the note to the Trash and, if it was selected, selects the one below it in the
    /// sidebar, or the one above if it was the last.
    private func moveToTrash(_ note: NoteDocument) {
        let index = filteredNotes.firstIndex { $0.id == note.id }
        do {
            try environment.noteTrash.moveToTrash(note)
            library.didRemove(note)
        } catch {
            failure = Failure(title: "Couldn't Move Note to Trash", message: error.localizedDescription)
            return
        }
        if navigation.selectedNoteID == note.id, let index {
            let remaining = filteredNotes
            navigation.selectedNoteID = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
        }
        Task { await reload() }
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
            navigation.selectedNoteID = note.id
        } else if !notes.contains(where: { $0.id == navigation.selectedNoteID }) {
            navigation.selectedNoteID = notes.first?.id
        }
    }
}

/// A section row at the top of the sidebar, highlighted like a selected note.
private struct SidebarRow<Accessory: View>: View {
    @Environment(MainNavigation.self) private var navigation
    let title: String
    let systemImage: String
    let destination: MainNavigation.Destination
    let accessory: Accessory

    init(
        _ title: String,
        systemImage: String,
        destination: MainNavigation.Destination,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.systemImage = systemImage
        self.destination = destination
        self.accessory = accessory()
    }

    var body: some View {
        let isSelected = navigation.destination == destination
        HStack {
            Label(title, systemImage: systemImage)
                .font(.headline)
            Spacer()
            accessory
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color("NoteSelection") : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { navigation.destination = destination }
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// What the recorder is doing, next to its sidebar row: the time while recording, progress
/// while downloading or transcribing.
private struct RecorderStatusBadge: View {
    let coordinator: RecordingCoordinator

    var body: some View {
        switch coordinator.phase {
        case .recording(let startedAt):
            Text(startedAt, style: .timer)
                .monospacedDigit()
                .foregroundStyle(.red)
        case .preparingModel(let progress):
            Text(progress.formatted(.percent.precision(.fractionLength(0))))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        case .transcribing:
            ProgressView()
                .controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
        case .idle:
            EmptyView()
        }
    }
}
