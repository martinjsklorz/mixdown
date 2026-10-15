import AppKit
import Observation
import os

/// Owns the folder notes are written to.
///
/// The user picks the folder. It's persisted as a security-scoped bookmark (the app is sandboxed)
/// and stays accessed for the lifetime of the app. There's no default: the only folder the
/// sandbox offers unasked is hidden inside the app's container, so recording waits until one is
/// chosen.
///
/// When the folder can't be reached, e.g. because its drive isn't connected, the store reports
/// that instead of switching folders, and picks the folder up again once it's back.
@MainActor @Observable
final class NotesFolderStore {
    enum Status: Equatable {
        /// No folder chosen yet, e.g. on first run.
        case notChosen
        case available(URL)
        /// The chosen folder can't be reached. `path` is where it was last seen, if known.
        case unavailable(path: String?)

        /// The folder to read and write notes in; `nil` unless `.available`.
        var directory: URL? {
            if case .available(let url) = self { url } else { nil }
        }

        /// Where the chosen folder is, or was last seen. `nil` if none is chosen or it's unknown.
        var path: String? {
            switch self {
            case .notChosen: nil
            case .available(let url): url.path(percentEncoded: false)
            case .unavailable(let path): path
            }
        }

        /// The chosen folder's name, e.g. "Mixdown".
        var name: String? {
            path.map { URL(fileURLWithPath: $0).lastPathComponent }
        }
    }

    private(set) var status: Status = .notChosen
    /// Notes saved by earlier versions in a folder inside the container: by default, and whenever
    /// the chosen folder was missing. They're moved into the folder once it's available.
    private(set) var hasLegacyNotes = false

    var directory: URL? { status.directory }

    private let settings: AppSettings
    /// The security-scoped URL we called `startAccessingSecurityScopedResource()` on.
    @ObservationIgnored private var accessedURL: URL?

    private static let logger = Logger(subsystem: "app.mixdown", category: "NotesFolder")

    init(settings: AppSettings) {
        self.settings = settings
        hasLegacyNotes = !Self.legacyNotes().isEmpty
        refresh()
        observeChanges()
    }

    /// Lets the user pick a folder.
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory ?? Self.userDocumentsDirectory
        panel.prompt = "Use Folder"
        panel.message = "Choose where Mixdown saves your notes. Use New Folder to make one just for them."

        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            settings.notesFolderBookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            // The panel grants access for this session anyway; it just won't survive a relaunch.
            Self.logger.error("Couldn't create bookmark for notes folder: \(error.localizedDescription)")
        }

        stopAccessing()
        if url.startAccessingSecurityScopedResource() { accessedURL = url }
        status = .available(url)
        moveLegacyNotes(to: url)
    }

    /// Checks the folder again: notices it going away, and resolves the bookmark again once it's
    /// back. Runs by itself when a volume is mounted or unmounted and when the app becomes active.
    func refresh() {
        if case .available(let url) = status {
            guard !Self.isUsable(url) else { return }
            Self.logger.error("Notes folder went away")
            stopAccessing()
        }
        // A renamed or moved folder resolves to its new location right away.
        let newStatus: Status =
            if let bookmark = settings.notesFolderBookmark {
                resolve(bookmark).map(Status.available) ?? .unavailable(path: Self.path(of: bookmark))
            } else {
                .notChosen
            }
        if newStatus != status { status = newStatus }
        if let directory { moveLegacyNotes(to: directory) }
    }

    private func observeChanges() {
        // The store lives as long as the app, so the observers are never removed.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            _ = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        // Catches the folder being moved, renamed or deleted in Finder.
        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func stopAccessing() {
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
    }

    /// Resolves the bookmark and starts accessing the folder. Returns `nil` if the folder can't be
    /// reached; the bookmark is kept, so it's found again once it's back.
    private func resolve(_ bookmark: Data) -> URL? {
        var isStale = false
        let url: URL
        do {
            // Without mounting or UI: this runs on every activation, so it mustn't block on a
            // network volume. Mounting it in Finder triggers another refresh.
            url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI, .withoutMounting],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            Self.logger.error("Couldn't resolve notes folder bookmark: \(error.localizedDescription)")
            return nil
        }
        guard url.startAccessingSecurityScopedResource() else {
            Self.logger.error("Access to notes folder denied")
            return nil
        }
        guard Self.isUsable(url) else {
            Self.logger.error("Notes folder doesn't exist or is in the Trash")
            url.stopAccessingSecurityScopedResource()
            return nil
        }
        if isStale,
            let refreshed = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        {
            settings.notesFolderBookmark = refreshed
        }
        stopAccessing()
        accessedURL = url
        return url
    }

    /// The path a bookmark points to, read without resolving it, for telling the user which
    /// folder is missing.
    private static func path(of bookmark: Data) -> String? {
        URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: bookmark)?.path
    }

    /// The folder exists and isn't in the Trash, where a bookmark follows a deleted folder.
    private static func isUsable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
            && isDirectory.boolValue
            && !url.pathComponents.contains { $0 == ".Trash" || $0 == ".Trashes" }
    }

    /// `~/Documents` outside the container, where the open panel starts. Inside the sandbox,
    /// `URL.documentsDirectory` points into the container.
    private static var userDocumentsDirectory: URL? {
        guard let home = getpwuid(getuid())?.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: home), isDirectory: true)
            .appending(path: "Documents", directoryHint: .isDirectory)
    }

    // MARK: Notes from earlier versions

    /// Where earlier versions saved notes when no folder was chosen or it was missing:
    /// `~/Documents/Mixdown` inside the container.
    private static var legacyDirectory: URL {
        URL.documentsDirectory.appending(path: "Mixdown", directoryHint: .isDirectory)
    }

    private static func legacyNotes() -> [URL] {
        let files = try? FileManager.default.contentsOfDirectory(
            at: legacyDirectory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )
        return (files ?? []).filter { $0.pathExtension.lowercased() == "md" }
    }

    /// Moves notes from `legacyDirectory` into `destination`. A note whose name is taken there
    /// stays where it is.
    private func moveLegacyNotes(to destination: URL) {
        guard hasLegacyNotes,
            destination.standardizedFileURL.pathComponents != Self.legacyDirectory.standardizedFileURL.pathComponents
        else { return }
        for note in Self.legacyNotes() {
            do {
                try FileManager.default.moveItem(
                    at: note,
                    to: destination.appending(path: note.lastPathComponent, directoryHint: .notDirectory)
                )
            } catch {
                Self.logger.error("Couldn't move note from earlier version: \(error.localizedDescription)")
            }
        }
        hasLegacyNotes = !Self.legacyNotes().isEmpty
    }
}
