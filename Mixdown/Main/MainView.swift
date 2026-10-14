import AppKit
import Combine
import MixdownCore
import MixdownNotes
import SwiftUI

/// The main window: Record at the top of the sidebar, the notes folder by day below it, and the
/// recorder or the selected note on the right. The cog above the sidebar opens Settings.
struct MainView: View {
    static let windowID = "main"

    @Environment(AppEnvironment.self) private var environment
    @Environment(MainNavigation.self) private var navigation
    @Environment(\.openSettings) private var openSettings
    @State private var library = NoteLibraryModel()
    @State private var searchText = ""

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 420)
        } detail: {
            detail
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
            showsSelection: navigation.destination == .notes
        ) {
            SidebarRow("Record", systemImage: "record.circle", destination: .recorder) {
                RecorderStatusBadge(coordinator: environment.coordinator)
            }
        } footer: {
            notesPlaceholder(isEmptyAfterSearch: notes.isEmpty)
        }
        // Toolbar items on the sidebar sit above it, next to the sidebar toggle.
        .toolbar {
            ToolbarItem {
                Button("Settings", systemImage: "gearshape") { navigation.showSettings(using: openSettings) }
                    .help("Settings (⌘,)")
            }
        }
    }

    /// Shown under the section rows when there's no note to list.
    private func notesPlaceholder(isEmptyAfterSearch: Bool) -> some View {
        Group {
            if let error = library.errorMessage {
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
            if let note = library.notes.first(where: { $0.id == navigation.selectedNoteID }) {
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
