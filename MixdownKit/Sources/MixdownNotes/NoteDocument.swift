import Foundation
import MixdownCore

/// A Markdown note read back from disk: its frontmatter metadata and Markdown body.
///
/// Parsing is lenient, so notes edited by hand or by other apps still show up. A missing title
/// falls back to the first `#` heading, then the file name; a missing `created` date falls back
/// to the date the caller got from the file system.
public struct NoteDocument: Sendable, Equatable, Identifiable {
    public var url: URL
    public var title: String
    public var createdAt: Date
    /// In seconds. `nil` unless the frontmatter has a usable `duration`.
    public var duration: TimeInterval?
    /// Names of the recorded inputs, from the frontmatter's `sources` list or single `source`.
    public var sources: [String]
    /// How the recording was started. `nil` for notes from before Mixdown recorded it, and ones
    /// edited to something else.
    public var trigger: RecordingTrigger?
    /// Whether the recording was of a call: from the frontmatter's `call: true` or `trigger:
    /// automatic`, or for notes from before Mixdown recorded that, a title worded as a call's.
    public var isCall: Bool
    /// The summary template the recording was summarized with, from the frontmatter's `template`:
    /// a built-in template's id, such as `oneOnOne`, or the name of one of the user's. `nil` for
    /// `general`, which Mixdown doesn't write, and for notes from before it did.
    public var template: String?
    /// The Markdown after the frontmatter.
    public var body: String
    /// The first text of the body as a single line of plain text. Empty if there is none.
    public var snippet: String
    /// The subfolder of the notes folder the note is in, like `Clients/Acme`, or `nil` if it's
    /// directly inside. Set by `NoteLibrary`.
    public var folder: String?
    /// Whether the note is listed above the others, from the frontmatter's `pinned: true`.
    public var isPinned: Bool
    /// How long each side talked, minute by minute, from the frontmatter's `talk_microphone` and
    /// `talk_system_audio` lists. `nil` if they're missing or unusable.
    public var talkTimeline: TalkTimeline?

    public var id: URL { url }

    static let maxSnippetLength = 200
    /// About 31 years. Larger values, like `inf` or `1e30`, would overflow `Duration`.
    static let maxDuration: TimeInterval = 1_000_000_000

    public init(url: URL, contents: String, fileDate: Date) {
        let (fields, body) = Self.splitFrontmatter(contents)
        let scalars = fields.mapValues(Self.yamlScalar)
        let blocks = MarkdownBlock.parse(body)

        self.url = url
        self.body = body
        self.title = Self.title(fields: scalars, blocks: blocks, url: url)
        self.createdAt = scalars["created"].flatMap(Self.date(fromYAML:)) ?? fileDate
        // `nan` fails the range check too.
        self.duration = scalars["duration"].flatMap(TimeInterval.init).flatMap {
            (0...Self.maxDuration).contains($0) ? $0 : nil
        }
        let sources = fields["sources"].flatMap(Self.yamlFlowSequence) ?? scalars["source"].map { [$0] } ?? []
        self.sources = sources.filter { !$0.isEmpty }
        self.trigger = scalars["trigger"].flatMap(RecordingTrigger.init(rawValue:))
        self.template = scalars["template"].flatMap { $0.isEmpty ? nil : $0 }
        // YAML's `true`, `True` and `TRUE`.
        self.isPinned = scalars["pinned"]?.lowercased() == "true"
        self.talkTimeline = Self.talkTimeline(fields: fields)
        self.snippet = Self.snippet(from: blocks)
        self.isCall =
            scalars["call"]?.lowercased() == "true" || trigger == .automatic || template == SummaryTemplate.clientCall.id
            || NoteTitle.isWordedAsCall(title)
    }

    /// The body's blocks without a leading `# Title` that repeats `title`, which the window
    /// already shows. A first heading with different text is kept. With a `talkTimeline`, which
    /// the window shows as a chart, the `## Talk Time` section is left out too.
    public func displayBlocks() -> [MarkdownBlock] {
        var blocks = MarkdownBlock.parse(body)
        if case .heading(1, let text) = blocks.first, MarkdownBlock.plainText(text) == title {
            blocks.removeFirst()
        }
        if talkTimeline != nil, let section = Self.section(MarkdownNoteRenderer.talkTimeHeading, in: blocks) {
            blocks.removeSubrange(section)
        }
        return blocks
    }

    /// The `##` section headed `heading`, from the heading to the next of level 2 or above.
    private static func section(_ heading: String, in blocks: [MarkdownBlock]) -> Range<Int>? {
        guard
            let start = blocks.firstIndex(where: { block in
                guard case .heading(2, let text) = block else { return false }
                return MarkdownBlock.plainText(text) == heading
            })
        else { return nil }
        let end = blocks[(start + 1)...].firstIndex { block in
            guard case .heading(let level, _) = block else { return false }
            return level <= 2
        }
        return start..<(end ?? blocks.endIndex)
    }

    private static func talkTimeline(fields: [String: String]) -> TalkTimeline? {
        let seconds = { (key: String) -> [TimeInterval]? in
            guard let items = fields[key].flatMap(Self.yamlFlowSequence), !items.isEmpty else { return nil }
            let values = items.compactMap(TimeInterval.init)
            // `nan` fails the range check too.
            guard values.count == items.count, values.allSatisfy({ (0...TalkTimeline.interval).contains($0) })
            else { return nil }
            return values
        }
        guard let microphone = seconds("talk_microphone"), let systemAudio = seconds("talk_system_audio") else {
            return nil
        }
        let labels = fields["talk_labels"].flatMap(Self.yamlFlowSequence) ?? []
        return TalkTimeline(
            microphoneLabel: labels.count == 2 ? labels[0] : SourceLabels.defaultMicrophone,
            systemAudioLabel: labels.count == 2 ? labels[1] : SourceLabels.defaultSystemAudio,
            microphone: microphone,
            systemAudio: systemAudio
        )
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
        // Without its heading.
        let section =
            Self.section("Transcript", in: blocks).map { blocks[($0.lowerBound + 1)..<$0.upperBound] } ?? blocks[...]

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

    /// `contents` of the note at `url` with its title changed to `title`, a single line with no
    /// runs of whitespace.
    ///
    /// Sets the frontmatter `title`, adding it if missing, and the first `#` heading if it shows
    /// the current title, escaping Markdown so the heading reads as `title`. A note with neither
    /// frontmatter nor such a heading gets frontmatter.
    /// Line endings become `\n`.
    static func retitled(_ contents: String, url: URL, to title: String) -> String {
        // Collapsed like the heading's plain text, so a title with runs of spaces still matches.
        let currentTitle = NoteDocument(url: url, contents: contents, fileDate: .distantPast).title
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var lines = normalizedLines(contents)
        let titleLine = "title: \(MarkdownNoteRenderer.yamlQuoted(title))"

        var bodyStart = 0
        let frontmatter = frontmatterEnd(lines)
        if let end = frontmatter {
            if let field = fieldLines("title", in: lines, frontmatterEnd: end) {
                lines.replaceSubrange(field, with: [titleLine])
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
                lines[index] = "# \(MarkdownNoteRenderer.headingText(title))"
                renamedHeading = true
                break
            }
        }

        if frontmatter == nil && !renamedHeading {
            lines.insert(contentsOf: ["---", titleLine, "---", ""], at: 0)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Pinning

    /// `contents` with the frontmatter's `pinned` field set to `true`, or removed when unpinning.
    /// A note without frontmatter gets some when pinned, and loses frontmatter that held nothing
    /// else when unpinned. Line endings become `\n`.
    static func pinned(_ contents: String, _ isPinned: Bool) -> String {
        var lines = normalizedLines(contents)
        let pinnedLines = isPinned ? ["pinned: true"] : []

        guard let end = frontmatterEnd(lines) else {
            if isPinned { lines.insert(contentsOf: ["---"] + pinnedLines + ["---", ""], at: 0) }
            return lines.joined(separator: "\n")
        }
        if let field = fieldLines("pinned", in: lines, frontmatterEnd: end) {
            lines.replaceSubrange(field, with: pinnedLines)
        } else {
            lines.insert(contentsOf: pinnedLines, at: end)
        }
        // Frontmatter left empty goes, with the blank line pinning added after it.
        if !isPinned, frontmatterEnd(lines) == 1 {
            lines.removeFirst(lines.count > 2 && lines[2].isEmpty ? 3 : 2)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Vocabulary

    /// What `corrected(_:by:)` replaces with, made once for many notes: one replacer for the
    /// frontmatter's title, one for Markdown, where both what's matched and what's put in are
    /// escaped the way `MarkdownNoteRenderer` escapes the transcript.
    struct VocabularyCorrection {
        let plain: Vocabulary.Replacer
        let markdown: Vocabulary.Replacer

        init(_ vocabulary: Vocabulary) {
            plain = Vocabulary.Replacer(vocabulary)
            markdown = Vocabulary.Replacer(vocabulary, escaping: MarkdownNoteRenderer.escapedMarkdown)
        }

        var isEmpty: Bool { plain.isEmpty }
    }

    /// `contents` with the vocabulary applied to the frontmatter's `title` and to the body, or
    /// `nil` if nothing changes. Headings of level 2 and below are left alone, as they name the
    /// sections Mixdown and other apps look for, like `## Transcript`; so are code blocks. Line
    /// endings become `\n`.
    static func corrected(_ contents: String, by correction: VocabularyCorrection) -> String? {
        var lines = normalizedLines(contents)
        var isChanged = false
        let replace = { (index: Int, line: String) in
            guard line != lines[index] else { return }
            lines[index] = line
            isChanged = true
        }

        var bodyStart = 0
        if let end = frontmatterEnd(lines) {
            if let field = fieldLines("title", in: lines, frontmatterEnd: end), field.count == 1,
                let colon = lines[field.lowerBound].firstIndex(of: ":")
            {
                let raw = lines[field.lowerBound][lines[field.lowerBound].index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
                let title = yamlScalar(raw)
                let corrected = correction.plain.replace(in: title)
                if corrected != title {
                    replace(field.lowerBound, "title: \(MarkdownNoteRenderer.yamlQuoted(corrected))")
                }
            }
            bodyStart = end + 1
        }

        var fence: Substring?
        for index in lines.indices.dropFirst(bodyStart) {
            if let open = fence {
                if Parser.isClosingFence(lines[index], for: open) { fence = nil }
                continue
            }
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if let (open, _) = Parser.openingFence(trimmed) {
                fence = open
            } else if let (level, _) = Parser.atxHeading(trimmed), level > 1 {
                continue
            } else {
                replace(index, correction.markdown.replace(in: lines[index]))
            }
        }
        return isChanged ? lines.joined(separator: "\n") : nil
    }

    // MARK: - Frontmatter

    /// Splits off a leading `---` … `---` block and reads its top-level `key: value` lines.
    /// Values are kept as written; decode them with `yamlScalar(_:)` or `yamlFlowSequence(_:)`.
    static func splitFrontmatter(_ contents: String) -> (fields: [String: String], body: String) {
        let text = normalized(contents)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let end = frontmatterEnd(lines) else { return ([:], text) }

        var fields: [String: String] = [:]
        for line in lines[1..<end] {
            guard let key = frontmatterKey(line), let colon = line.firstIndex(of: ":") else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }
        return (fields, lines[(end + 1)...].joined(separator: "\n"))
    }

    /// `contents` with `\n` line endings and without a byte order mark.
    private static func normalized(_ contents: String) -> String {
        var text = contents.replacingOccurrences(of: "\r\n", with: "\n")
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text
    }

    private static func normalizedLines(_ contents: String) -> [String] {
        normalized(contents).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// The lines of the top-level `key` field in the frontmatter closed at `end`, including the
    /// lines a multi-line value continues on, up to the next key.
    private static func fieldLines(_ key: String, in lines: [String], frontmatterEnd end: Int) -> Range<Int>? {
        guard let index = lines[1..<end].firstIndex(where: { frontmatterKey($0) == key }) else { return nil }
        let next = lines[(index + 1)..<end].firstIndex { $0.first.map { !$0.isWhitespace } ?? false }
        return index..<(next ?? end)
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
        if raw.first == "\"" || raw.first == "'" {
            return quotedScalar(raw[...])?.value ?? raw
        }
        guard let comment = raw.range(of: " #") else { return raw }
        return raw[..<comment.lowerBound].trimmingCharacters(in: .whitespaces)
    }

    /// The items of a YAML flow sequence like `["a", 'b', c]`, or `nil` if `raw` isn't a
    /// complete one. Empty items are dropped.
    static func yamlFlowSequence(_ raw: String) -> [String]? {
        guard raw.first == "[" else { return nil }
        var items: [String] = []
        var rest = raw.dropFirst()
        while true {
            rest = rest.drop(while: \.isWhitespace)
            guard let first = rest.first else { return nil }
            // Also ends `[]` and a trailing comma.
            if first == "]" { return items }
            let item: String
            if first == "\"" || first == "'" {
                guard let quoted = quotedScalar(rest) else { return nil }
                item = quoted.value
                rest = rest[quoted.end...]
            } else {
                let end = rest.firstIndex { $0 == "," || $0 == "]" } ?? rest.endIndex
                item = rest[..<end].trimmingCharacters(in: .whitespaces)
                rest = rest[end...]
            }
            if !item.isEmpty { items.append(item) }
            rest = rest.drop(while: \.isWhitespace)
            if rest.first == "," {
                rest = rest.dropFirst()
            } else if rest.first != "]" {
                return nil
            }
        }
    }

    /// The value of the single- or double-quoted scalar `raw` starts with, and the index after
    /// its closing quote. `nil` if `raw` doesn't start with a quote or it's unterminated.
    private static func quotedScalar(_ raw: Substring) -> (value: String, end: Substring.Index)? {
        switch raw.first {
        case "\"":
            var isEscaped = false
            for index in raw.indices.dropFirst() {
                if isEscaped {
                    isEscaped = false
                } else if raw[index] == "\\" {
                    isEscaped = true
                } else if raw[index] == "\"" {
                    let value = unescapeDoubleQuoted(raw[raw.index(after: raw.startIndex)..<index])
                    return (value, raw.index(after: index))
                }
            }
            return nil
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
                guard index < raw.endIndex, raw[index] == "'" else { return (value, index) }
                value.append("'")
                index = raw.index(after: index)
            }
            return nil
        default:
            return nil
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
