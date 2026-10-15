import Foundation

/// A Markdown note read back from disk: its frontmatter metadata and Markdown body.
///
/// Parsing is lenient, so notes edited by hand or by other apps still show up. A missing title
/// falls back to the first `#` heading, then the file name; a missing `created` date falls back
/// to the date the caller got from the file system.
public struct NoteDocument: Sendable, Equatable, Identifiable {
    public var url: URL
    public var title: String
    public var createdAt: Date
    /// In seconds. `nil` unless the frontmatter has a `duration`.
    public var duration: TimeInterval?
    /// Name of the recorded input, from the frontmatter.
    public var source: String?
    /// The Markdown after the frontmatter.
    public var body: String
    /// The first text of the body as a single line of plain text. Empty if there is none.
    public var snippet: String

    public var id: URL { url }

    static let maxSnippetLength = 200

    public init(url: URL, contents: String, fileDate: Date) {
        let (fields, body) = Self.splitFrontmatter(contents)
        let blocks = MarkdownBlock.parse(body)

        self.url = url
        self.body = body
        self.title = Self.title(fields: fields, blocks: blocks, url: url)
        self.createdAt = fields["created"].flatMap(Self.date(fromYAML:)) ?? fileDate
        self.duration = fields["duration"].flatMap(TimeInterval.init)
        self.source = fields["source"].flatMap { $0.isEmpty ? nil : $0 }
        self.snippet = Self.snippet(from: blocks)
    }

    /// The body's blocks without a leading `# Title` that repeats `title`, which the window
    /// already shows. A first heading with different text is kept.
    public func displayBlocks() -> [MarkdownBlock] {
        let blocks = MarkdownBlock.parse(body)
        guard case .heading(1, let text) = blocks.first, MarkdownBlock.plainText(text) == title else {
            return blocks
        }
        return Array(blocks.dropFirst())
    }

    private static func title(fields: [String: String], blocks: [MarkdownBlock], url: URL) -> String {
        if let title = fields["title"]?.trimmingCharacters(in: .whitespaces), !title.isEmpty { return title }
        let heading = blocks.lazy.compactMap { block -> String? in
            guard case .heading(1, let text) = block else { return nil }
            return MarkdownBlock.plainText(text)
        }.first(where: { !$0.isEmpty })
        return heading ?? url.deletingPathExtension().lastPathComponent
    }

    private static func snippet(from blocks: [MarkdownBlock]) -> String {
        let text = blocks.lazy.compactMap { block -> String? in
            switch block {
            case .paragraph(let text), .listItem(_, _, let text), .quote(let text):
                MarkdownBlock.plainText(text)
            case .heading, .code, .rule:
                nil
            }
        }.first(where: { !$0.isEmpty })
        return String((text ?? "").prefix(maxSnippetLength))
    }

    // MARK: - Transcript

    /// The `## Transcript` section as plain text, or the whole body if there is none. Blocks are
    /// separated by a blank line, list items by a line break.
    public var transcriptText: String {
        let blocks = MarkdownBlock.parse(body)
        var section = blocks[...]
        if let heading = blocks.firstIndex(where: { block in
            guard case .heading(2, let text) = block else { return false }
            return MarkdownBlock.plainText(text) == "Transcript"
        }) {
            let rest = blocks[(heading + 1)...]
            let end = rest.firstIndex { block in
                guard case .heading(let level, _) = block else { return false }
                return level <= 2
            }
            section = rest[..<(end ?? rest.endIndex)]
        }

        var text = ""
        var previous: MarkdownBlock?
        for block in section {
            let line: String
            switch block {
            case .heading(_, let markdown), .paragraph(let markdown), .quote(let markdown):
                line = MarkdownBlock.plainText(markdown)
            case .listItem(let number, let depth, let markdown):
                let marker = number.map { "\($0)." } ?? "•"
                line = String(repeating: "  ", count: depth) + "\(marker) \(MarkdownBlock.plainText(markdown))"
            case .code(_, let code):
                line = code
            case .rule:
                continue
            }
            if !text.isEmpty {
                if case .listItem = previous, case .listItem = block {
                    text += "\n"
                } else {
                    text += "\n\n"
                }
            }
            text += line
            previous = block
        }
        return text
    }

    // MARK: - Renaming

    /// `contents` of the note at `url` with its title changed to `title`, a single line.
    ///
    /// Sets the frontmatter `title`, adding it if missing, and the first `#` heading if it shows
    /// the current title. A note with neither frontmatter nor such a heading gets frontmatter.
    /// Line endings become `\n`.
    static func retitled(_ contents: String, url: URL, to title: String) -> String {
        let currentTitle = NoteDocument(url: url, contents: contents, fileDate: .distantPast).title
        var text = contents.replacingOccurrences(of: "\r\n", with: "\n")
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let titleLine = "title: \(MarkdownNoteRenderer.yamlQuoted(title))"

        var bodyStart = 0
        let frontmatter = frontmatterEnd(lines)
        if let end = frontmatter {
            if let index = lines[1..<end].firstIndex(where: { frontmatterKey($0) == "title" }) {
                // Also drop the lines a multi-line value continues on, up to the next key.
                let next = lines[(index + 1)..<end].firstIndex { $0.first.map { !$0.isWhitespace } ?? false }
                lines.replaceSubrange(index..<(next ?? end), with: [titleLine])
            } else {
                lines.insert(titleLine, at: 1)
            }
            bodyStart = (frontmatterEnd(lines) ?? 0) + 1
        }

        var renamedHeading = false
        var fence: Substring?
        for index in lines.indices.dropFirst(bodyStart) {
            if let open = fence {
                if Parser.isClosingFence(lines[index], for: open) { fence = nil }
                continue
            }
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if let (open, _) = Parser.openingFence(trimmed) {
                fence = open
            } else if let (level, text) = Parser.atxHeading(trimmed), level == 1 {
                guard MarkdownBlock.plainText(text) == currentTitle else { continue }
                lines[index] = "# \(title)"
                renamedHeading = true
                break
            }
        }

        if frontmatter == nil && !renamedHeading {
            lines.insert(contentsOf: ["---", titleLine, "---", ""], at: 0)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Frontmatter

    /// Splits off a leading `---` … `---` block and reads its top-level `key: value` lines.
    /// Values that aren't simple scalars (lists, nested maps) are kept as written.
    static func splitFrontmatter(_ contents: String) -> (fields: [String: String], body: String) {
        var text = contents.replacingOccurrences(of: "\r\n", with: "\n")
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let end = frontmatterEnd(lines) else { return ([:], text) }

        var fields: [String: String] = [:]
        for line in lines[1..<end] {
            guard let key = frontmatterKey(line), let colon = line.firstIndex(of: ":") else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields[key] = yamlScalar(value)
        }
        return (fields, lines[(end + 1)...].joined(separator: "\n"))
    }

    /// The index of the line closing the frontmatter, if `lines` start with frontmatter.
    static func frontmatterEnd<Line: StringProtocol>(_ lines: [Line]) -> Int? {
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        return lines.dropFirst().firstIndex {
            let line = $0.trimmingCharacters(in: .whitespaces)
            return line == "---" || line == "..."
        }
    }

    /// The key of a top-level `key: value` frontmatter line.
    static func frontmatterKey<Line: StringProtocol>(_ line: Line) -> String? {
        guard let first = line.first, !first.isWhitespace, first != "#",
            let colon = line.firstIndex(of: ":")
        else { return nil }
        return line[..<colon].trimmingCharacters(in: .whitespaces)
    }

    /// The value of a YAML scalar: quotes removed and escapes resolved, comments dropped.
    /// An unterminated quoted value is kept as written.
    static func yamlScalar(_ raw: String) -> String {
        switch raw.first {
        case "\"":
            var isEscaped = false
            for index in raw.indices.dropFirst() {
                if isEscaped {
                    isEscaped = false
                } else if raw[index] == "\\" {
                    isEscaped = true
                } else if raw[index] == "\"" {
                    return unescapeDoubleQuoted(raw[raw.index(after: raw.startIndex)..<index])
                }
            }
            return raw
        case "'":
            // The only escape in single quotes is `''` for a quote.
            var value = ""
            var index = raw.index(after: raw.startIndex)
            while index < raw.endIndex {
                let character = raw[index]
                index = raw.index(after: index)
                guard character == "'" else {
                    value.append(character)
                    continue
                }
                guard index < raw.endIndex, raw[index] == "'" else { return value }
                value.append("'")
                index = raw.index(after: index)
            }
            return raw
        default:
            guard let comment = raw.range(of: " #") else { return raw }
            return raw[..<comment.lowerBound].trimmingCharacters(in: .whitespaces)
        }
    }

    /// Resolves the escapes `MarkdownNoteRenderer.yamlQuoted(_:)` writes, plus the other common
    /// YAML ones. Unknown escapes keep the escaped character.
    static func unescapeDoubleQuoted(_ value: Substring) -> String {
        var result = String.UnicodeScalarView()
        var scalars = value.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            guard scalar == "\\", let escaped = scalars.next() else {
                result.append(scalar)
                continue
            }
            switch escaped {
            case "n": result.append("\n")
            case "r": result.append("\r")
            case "t": result.append("\t")
            case "0": result.append("\0")
            case "x", "u", "U":
                let length = escaped == "x" ? 2 : escaped == "u" ? 4 : 8
                var hex = String.UnicodeScalarView()
                for _ in 0..<length {
                    if let digit = scalars.next() { hex.append(digit) }
                }
                if let code = UInt32(String(hex), radix: 16), let decoded = Unicode.Scalar(code) {
                    result.append(decoded)
                }
            default:
                result.append(escaped)
            }
        }
        return String(result)
    }

    /// An ISO 8601 date-time, with or without fractional seconds, or a plain `yyyy-MM-dd` date.
    static func date(fromYAML value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        // Only matters for date-only values: midnight local time, not UTC.
        formatter.timeZone = .current
        let variants: [ISO8601DateFormatter.Options] = [
            [.withInternetDateTime],
            [.withInternetDateTime, .withFractionalSeconds],
            [.withFullDate],
        ]
        for options in variants {
            formatter.formatOptions = options
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}
