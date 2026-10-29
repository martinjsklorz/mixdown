import Foundation

extension NoteLibrary {
    /// The note of `notes`, listed from `directory`, that `reference` names, for a
    /// `mixdown://open?note=…` link (see `URLCommand`). Tried in this order:
    ///
    /// - A path: absolute, a `file://` URL, or relative to `directory`. The `.md` can be left off,
    ///   and case doesn't matter, as on the Mac's disks.
    /// - A title, ignoring case. The newest note of several with it.
    /// - `latest`: the newest note.
    ///
    /// `notes` are newest first, as `loadNotes(in:cache:)` lists them. Only they can be found, so
    /// a link can't open a file outside the notes folder.
    public static func note(for reference: String, in notes: [NoteDocument], directory: URL) -> NoteDocument? {
        let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty else { return nil }

        let url: URL? =
            if reference.lowercased().hasPrefix("file:") {
                URL(string: reference)
            } else if reference.hasPrefix("/") {
                URL(filePath: reference, directoryHint: .notDirectory)
            } else {
                directory.appending(path: reference, directoryHint: .notDirectory)
            }
        if let url {
            let urls = [url] + fileExtensions.sorted().map { url.appendingPathExtension($0) }
            if let note = urls.lazy.compactMap({ named(notes, like: $0).first(where: isAt($0)) }).first {
                return note
            }
        }

        if let note = notes.first(where: { $0.title.caseInsensitiveCompare(reference) == .orderedSame }) {
            return note
        }
        return reference.lowercased() == "latest" ? notes.first : nil
    }

    /// The note of `notes` whose file is at `url`, such as the one a note was just written to or
    /// renamed to. The writer's URL and the directory listing's can differ in form, like
    /// `/var/…` and `/private/var/…`, and case doesn't matter, as on the Mac's disks. Failing
    /// that, the only note with the file's name; `nil` if several have it, as notes in different
    /// subfolders can share a name.
    public static func note(at url: URL, in notes: [NoteDocument]) -> NoteDocument? {
        let named = named(notes, like: url)
        return named.count == 1 ? named[0] : named.first(where: isAt(url))
    }

    /// The notes of `notes` whose file has `url`'s name, ignoring case. Only these can be at
    /// `url`, so only their paths are resolved, which reads the disk.
    private static func named(_ notes: [NoteDocument], like url: URL) -> [NoteDocument] {
        let name = url.lastPathComponent.lowercased()
        return notes.filter { $0.url.lastPathComponent.lowercased() == name }
    }

    /// Whether a note's file is at `url`, whatever form either path is in.
    private static func isAt(_ url: URL) -> (NoteDocument) -> Bool {
        let path = comparablePath(of: url)
        return { comparablePath(of: $0.url) == path }
    }

    /// The path in one form whatever the URL's: standardized, without symbolic links, lowercased.
    private static func comparablePath(of url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false).lowercased()
    }
}
