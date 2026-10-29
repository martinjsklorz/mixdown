import Foundation
import MixdownNotes

/// How notes are printed: a line each for people, JSON for scripts and agents.
enum NoteOutput {
    /// A note in JSON, with the frontmatter's names for its fields.
    struct Fields: Encodable, Equatable {
        var title: String
        /// The file's full path.
        var path: String
        /// The file's path in the notes folder, which `show`, `path` and `open` take too.
        var relativePath: String
        /// ISO 8601, in the Mac's time zone, like the frontmatter's.
        var created: String
        /// In seconds, without paused time.
        var duration: Int?
        var sources: [String]
        /// The subfolder of the notes folder it's in.
        var folder: String?
        var pinned: Bool
        var call: Bool
        /// `manual`, `automatic` or `imported`.
        var trigger: String?
        var template: String?
        var speakers: [String]
        /// The start of its text, on one line.
        var snippet: String
        /// For `search`: the line that matches best, or `""` if only the title or folder does.
        var match: String?
        /// For `show`: the Markdown after the frontmatter.
        var body: String?
        /// For `show`: the transcript as plain text.
        var transcript: String?

        init(_ note: NoteDocument, timeZone: TimeZone = .current) {
            title = note.title
            path = note.url.path(percentEncoded: false)
            relativePath = NoteOutput.relativePath(of: note)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            formatter.timeZone = timeZone
            created = formatter.string(from: note.createdAt)
            duration = note.duration.map { Int($0.rounded()) }
            sources = note.sources
            folder = note.folder
            pinned = note.isPinned
            call = note.isCall
            trigger = note.trigger?.rawValue
            template = note.template
            speakers = note.speakers
            snippet = note.snippet
        }
    }

    static func json(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // Only strings, numbers, booleans and arrays of them, which always encode.
        let data = (try? encoder.encode(value)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The note's path in the notes folder, like `Clients/Acme/2026-10-24 0930 Weekly Sync.md`.
    static func relativePath(of note: NoteDocument) -> String {
        [note.folder, note.url.lastPathComponent].compactMap { $0 }.joined(separator: "/")
    }

    /// One line per note: when it was recorded, for how long, its title and its file, like
    /// `2026-10-24 09:30  12 min    Weekly Sync  (Clients/Acme/2026-10-24 0930 Weekly Sync.md)`.
    /// With `matches`, from `NoteLibrary.search(_:for:)`, the matching line goes under each note.
    static func lines(
        for notes: [NoteDocument],
        matches: [NoteDocument.ID: String] = [:],
        calendar: Calendar = .current
    ) -> String {
        notes.map { note in
            let duration = note.duration.map(formatted(duration:)) ?? ""
            var line =
                "\(formatted(date: note.createdAt, calendar: calendar))  "
                + duration.padding(toLength: durationWidth, withPad: " ", startingAt: 0)
                + "  \(note.title)  (\(relativePath(of: note)))"
            if let match = matches[note.id], !match.isEmpty { line += "\n    \(match)" }
            return line
        }.joined(separator: "\n")
    }

    /// Wide enough for `10 h 05 min`.
    static let durationWidth = 11

    static func formatted(date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(
            format: "%04d-%02d-%02d %02d:%02d",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0,
            parts.hour ?? 0,
            parts.minute ?? 0
        )
    }

    /// `45 s`, `12 min` or `1 h 05 min`, rounded to the nearest second or minute.
    static func formatted(duration: TimeInterval) -> String {
        let seconds = Int(duration.rounded())
        if seconds < 60 { return "\(seconds) s" }
        let minutes = Int((duration / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        return String(format: "%d h %02d min", minutes / 60, minutes % 60)
    }

    /// The Markdown under the heading `name` in `body`, ignoring case: up to the next heading of
    /// the same level or above, so `Summary` includes its `Key Points` and `Action Items`.
    static func section(_ name: String, in body: String) throws(SectionError) -> String {
        let lines = body.replacingOccurrences(of: "\r\n", with: "\n").split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        let headings = headings(in: lines)
        let wanted = name.trimmingCharacters(in: .whitespaces)
        guard let start = headings.firstIndex(where: { $0.text.caseInsensitiveCompare(wanted) == .orderedSame }) else {
            throw SectionError(name: wanted, available: headings.filter { $0.level > 1 }.map(\.text))
        }
        let heading = headings[start]
        let end = headings[(start + 1)...].first { $0.level <= heading.level }?.line ?? lines.endIndex
        return lines[(heading.line + 1)..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The ATX headings of `lines`, outside code blocks, with the number of the line each is on.
    private static func headings(in lines: [Substring]) -> [(line: Int, level: Int, text: String)] {
        var headings: [(line: Int, level: Int, text: String)] = []
        var fence: Substring?
        for (number, line) in lines.enumerated() {
            let trimmed = line.drop { $0 == " " }
            if let open = fence {
                if trimmed.hasPrefix(open) { fence = nil }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = trimmed.prefix(3)
                continue
            }
            if let match = line.wholeMatch(of: /(#{1,6})[ \t]+(.*?)[ \t]*/) {
                // A closing run of `#`s isn't part of the text.
                let text = match.2.replacing(/[ \t]+#+$/, with: "")
                headings.append((number, match.1.count, MarkdownBlock.plainText(String(text))))
            }
        }
        return headings
    }
}

/// The note has no heading with the name `show --section` was given.
struct SectionError: Error, Equatable, CustomStringConvertible {
    var name: String
    var available: [String]

    var description: String {
        let list = available.isEmpty ? "none" : available.map { "“\($0)”" }.joined(separator: ", ")
        return "The note has no section “\(name)”. Its sections: \(list)."
    }
}
