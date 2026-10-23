import Foundation

/// What Spotlight gets of each note: an item for the note as a whole, and one per line of it (a
/// transcript paragraph, a summary point), so a search shows the line that matched right in the
/// results, without opening Mixdown.
///
/// Free of Core Spotlight, so it can be tested; the app turns `Item`s into `CSSearchableItem`s.
public enum NoteSearchIndex {
    /// One entry in Spotlight.
    public struct Item: Sendable, Equatable {
        /// Unique in the index: the note's file URL, with `#` and the line number for a line. See
        /// `location(ofItemID:)`.
        public var id: String
        /// The result's name: the note's title, or the line.
        public var title: String
        /// Shown with the title: the note's first text, or the note's title, section and time a
        /// line is from.
        public var description: String
        /// What else a search matches: the whole note, or the line.
        public var text: String
        public var date: Date
        public var keywords: [String]
    }

    /// A line of a note that gets its own item.
    public struct Line: Sendable, Equatable {
        /// Where it is in the note's `displayBlocks()`, to scroll to.
        public var block: Int
        /// The line as plain text, without its transcript timestamp or task checkbox.
        public var text: String
        /// The heading of the section it's in, like "Action Items" or "Transcript".
        public var section: String?
        /// When it was said, like `00:12:34`, for a transcript line.
        public var time: String?
    }

    /// Bumped when items are built differently, so notes indexed by an older version are indexed
    /// again.
    static let formatVersion = 1
    /// Spotlight only shows the start of a long title anyway.
    static let maxTitleLength = 300
    /// The placeholders `MarkdownNoteRenderer` writes where there's nothing to show, as plain text.
    static let placeholders = Set(
        [MarkdownNoteRenderer.emptyTranscriptPlaceholder, MarkdownNoteRenderer.emptySectionPlaceholder]
            .map(MarkdownBlock.plainText)
    )

    // MARK: Items

    /// The note's item, then an item per line in `lines(of:)`, numbered in that order.
    public static func items(for note: NoteDocument) -> [Item] {
        let lines = lines(of: note)
        let noteID = itemID(for: note.url)
        var keywords = note.sources
        if let folder = note.folder { keywords.append(folder) }

        let noteItem = Item(
            id: noteID,
            title: note.title,
            description: note.snippet,
            text: lines.map(\.text).joined(separator: "\n"),
            date: note.createdAt,
            keywords: keywords
        )
        return [noteItem]
            + lines.enumerated().map { number, line in
                // The time says it's from the transcript; a translation's lines still say so.
                let section =
                    line.time != nil && line.section == MarkdownNoteRenderer.transcriptHeading ? nil : line.section
                return Item(
                    id: itemID(for: note.url, line: number),
                    title: String(line.text.prefix(maxTitleLength)),
                    description: [note.title, section, line.time].compactMap { $0 }.joined(separator: " · "),
                    text: line.text,
                    date: note.createdAt,
                    keywords: keywords
                )
            }
    }

    /// The text blocks of the note as shown, each as a single line of plain text. Headings,
    /// rules, empty blocks and Mixdown's "nothing here" placeholders are left out.
    public static func lines(of note: NoteDocument) -> [Line] {
        var lines: [Line] = []
        var section: String?
        for (index, block) in note.displayBlocks().enumerated() {
            var text: String
            switch block {
            case .heading(_, let markdown):
                section = MarkdownBlock.plainText(markdown)
                continue
            case .paragraph(let markdown), .quote(let markdown):
                text = MarkdownBlock.plainText(markdown)
            case .listItem(_, _, let markdown):
                text = MarkdownBlock.plainText(markdown)
                for checkbox in ["[ ] ", "[x] ", "[X] "] where text.hasPrefix(checkbox) {
                    text.removeFirst(checkbox.count)
                }
            case .code(_, let code):
                text = code.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            case .rule:
                continue
            }
            var time: String?
            if let match = text.firstMatch(of: /^\[(\d+:\d{2}:\d{2})\]\s*/) {
                time = String(match.1)
                text.removeSubrange(match.range)
            }
            guard !text.isEmpty, !placeholders.contains(text) else { continue }
            lines.append(Line(block: index, text: text, section: section, time: time))
        }
        return lines
    }

    // MARK: Identifiers

    static func itemID(for url: URL, line: Int? = nil) -> String {
        url.absoluteString + (line.map { "#\($0)" } ?? "")
    }

    /// The note an item is for, and the number of the line it's for in `lines(of:)`, if any.
    /// `nil` for an ID that isn't one of ours.
    public static func location(ofItemID id: String) -> (noteURL: URL, line: Int?)? {
        guard var components = URLComponents(string: id), components.scheme == "file" else { return nil }
        let line = components.fragment.flatMap { Int($0) }.flatMap { $0 >= 0 ? $0 : nil }
        components.fragment = nil
        return components.url.map { ($0, line) }
    }

    // MARK: Updating

    /// What the index has of each note, by the note item's ID, so an update only touches notes
    /// that changed. Kept between launches.
    public struct State: Codable, Sendable, Equatable {
        struct Entry: Codable, Sendable, Equatable {
            /// `fingerprint(of:)` of the note when it was indexed.
            var fingerprint: String
            /// How many line items it got, numbered from 0.
            var lineCount: Int
        }

        var notes: [String: Entry] = [:]

        public init() {}

        public var isEmpty: Bool { notes.isEmpty }
    }

    /// The changes that bring an index holding `state` in line with `notes`.
    public struct Update: Sendable {
        /// New and changed items. Spotlight replaces an item with the same ID.
        public var items: [Item] = []
        /// Items of notes that are gone, and lines a changed note no longer has.
        public var deletedIDs: [String] = []
        /// What the index holds once the update is applied.
        public var state: State

        public var isEmpty: Bool { items.isEmpty && deletedIDs.isEmpty }
    }

    /// What has to change for an index holding `state` to have the items of `notes` and nothing
    /// else. Notes whose `fingerprint(of:)` is unchanged are left alone.
    public static func update(from state: State, to notes: [NoteDocument]) -> Update {
        var update = Update(state: State())
        for note in notes {
            let id = itemID(for: note.url)
            // Listed twice (it can't be, but the index must not get stale lines from it).
            guard update.state.notes[id] == nil else { continue }
            let fingerprint = fingerprint(of: note)
            if let entry = state.notes[id], entry.fingerprint == fingerprint {
                update.state.notes[id] = entry
                continue
            }
            let items = items(for: note)
            let lineCount = items.count - 1
            update.items += items
            if let old = state.notes[id], old.lineCount > lineCount {
                update.deletedIDs += (lineCount..<old.lineCount).map { itemID(for: note.url, line: $0) }
            }
            update.state.notes[id] = State.Entry(fingerprint: fingerprint, lineCount: lineCount)
        }
        for (id, entry) in state.notes where update.state.notes[id] == nil {
            update.deletedIDs.append(id)
            update.deletedIDs += (0..<entry.lineCount).map { "\(id)#\($0)" }
        }
        return update
    }

    /// Tells notes apart that would get different items: a hash of what the items are made from.
    /// `NoteLibrary` works it out once as it reads a note, so updates don't hash every note again.
    static func fingerprint(of note: NoteDocument) -> String {
        if let fingerprint = note.cachedFingerprint.value { return fingerprint }
        return hash(
            [
                "\(formatVersion)", note.url.absoluteString, note.title, "\(note.createdAt.timeIntervalSince1970)",
                note.folder ?? "", note.body,
            ] + note.sources
        )
    }

    /// A 64-bit FNV-1a hash of `fields`, in hex. Stable between launches, unlike `Hasher`.
    static func hash(_ fields: [String]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func add(_ byte: UInt8) {
            hash ^= UInt64(byte)
            hash &*= 0x100_0000_01b3
        }
        for field in fields {
            field.utf8.forEach(add)
            // A separator no field contains, so moving text between fields changes the hash.
            add(0)
        }
        return String(hash, radix: 16)
    }
}
