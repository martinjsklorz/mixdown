import AppKit
import MixdownNotes
import Observation
import os

/// Owns the folder notes are written to.
///
/// A user-chosen folder is persisted as a security-scoped bookmark (the app is sandboxed) and
/// stays accessed for the lifetime of the app. Without one, notes go to
/// `MarkdownNoteWriter.defaultDirectory`.
@MainActor @Observable
final class NotesFolderStore {
    private(set) var directory: URL
    private(set) var isCustom: Bool

    private let settings: AppSettings
    /// The security-scoped URL we called `startAccessingSecurityScopedResource()` on.
    @ObservationIgnored private var accessedURL: URL?

    private static let logger = Logger(subsystem: "app.mixdown", category: "NotesFolder")

    init(settings: AppSettings) {
        self.settings = settings
        let resolved = Self.resolveBookmark(in: settings)
        directory = resolved ?? MarkdownNoteWriter.defaultDirectory
        isCustom = resolved != nil
        accessedURL = resolved
    }

    /// Lets the user pick a folder. Returns `true` if the folder changed.
    @discardableResult
    func chooseFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory
        panel.prompt = "Use Folder"
        panel.message = "Choose where Mixdown saves your notes."

        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return false }

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
        directory = url
        isCustom = true
        return true
    }

    func resetToDefault() {
        stopAccessing()
        settings.notesFolderBookmark = nil
        directory = MarkdownNoteWriter.defaultDirectory
        isCustom = false
    }

    private func stopAccessing() {
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
    }

    /// Resolves the stored bookmark and starts accessing it. Keeps the bookmark on failure so a
    /// temporarily missing volume doesn't silently discard the user's choice.
    private static func resolveBookmark(in settings: AppSettings) -> URL? {
        guard let data = settings.notesFolderBookmark else { return nil }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            guard url.startAccessingSecurityScopedResource() else {
                logger.error("Access to notes folder denied; falling back to default")
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
            return url
        } catch {
            logger.error("Couldn't resolve notes folder bookmark: \(error.localizedDescription)")
            return nil
        }
    }
}
