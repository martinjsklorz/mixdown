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
            let path = comparablePath(of: url)
            let paths = [path] + fileExtensions.sorted().map { "\(path).\($0)" }
            if let note = notes.first(where: { paths.contains(comparablePath(of: $0.url)) }) {
                return note
            }
        }

        if let note = notes.first(where: { $0.title.caseInsensitiveCompare(reference) == .orderedSame }) {
            return note
        }
        return reference.lowercased() == "latest" ? notes.first : nil
    }

    private static func comparablePath(of url: URL) -> String {
        url.standardizedFileURL.path(percentEncoded: false).lowercased()
    }
}
