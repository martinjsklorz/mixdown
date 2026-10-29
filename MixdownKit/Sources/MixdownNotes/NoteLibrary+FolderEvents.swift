import Foundation

extension NoteLibrary {
    /// One change a folder watcher reports, such as FSEvents' per-file events, by its path and flags.
    public struct FolderEvent: Sendable, Equatable {
        public var path: String
        public var isDirectory: Bool
        /// Events were dropped or coalesced, so the folder has to be read again whatever the path.
        public var mustRescan: Bool
        /// The watched folder itself was renamed, moved or deleted, or one of the folders it's in.
        public var rootChanged: Bool

        public init(path: String, isDirectory: Bool = false, mustRescan: Bool = false, rootChanged: Bool = false) {
            self.path = path
            self.isDirectory = isDirectory
            self.mustRescan = mustRescan
            self.rootChanged = rootChanged
        }
    }

    /// What a batch of `FolderEvent`s means for the notes listed for a folder.
    public enum FolderChange: Sendable, Equatable {
        /// Notes may have been added, removed, renamed or edited: the folder has to be read again.
        case notes
        /// The folder is no longer where it was watched, so its new location has to be found.
        case rootChanged
    }

    /// What `events` in `directory` mean for its notes, or `nil` if they can't change them, such
    /// as `.DS_Store` or a hidden folder like `.obsidian` changing. A root change counts over the
    /// rest, as reading the old path again would find nothing.
    public static func change(from events: [FolderEvent], in directory: URL) -> FolderChange? {
        if events.contains(where: \.rootChanged) { return .rootChanged }
        let changesNotes = events.contains { event in
            event.mustRescan
                || affectsNotes(URL(fileURLWithPath: event.path), isDirectory: event.isDirectory, in: directory)
        }
        return changesNotes ? .notes : nil
    }
}
