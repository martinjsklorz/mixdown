import Foundation
import MixdownCore

/// Changes to a note's file contents: its title, whether it's pinned, its speakers' names, and
/// vocabulary corrections.
extension NoteDocument {
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
        var lines = Frontmatter.normalizedLines(contents)
        let titleLine = "title: \(MarkdownNoteRenderer.yamlQuoted(title))"

        var bodyStart = 0
        let frontmatter = Frontmatter.end(of: lines)
        if let end = frontmatter {
            if let field = Frontmatter.fieldLines("title", in: lines, end: end) {
                lines.replaceSubrange(field, with: [titleLine])
            } else {
                lines.insert(titleLine, at: 1)
            }
            bodyStart = (Frontmatter.end(of: lines) ?? 0) + 1
        }

        var renamedHeading = false
        for index in linesOutsideCode(lines, from: bodyStart) {
            guard let (level, text) = Parser.atxHeading(lines[index].trimmingCharacters(in: .whitespaces)),
                level == 1, MarkdownBlock.plainText(text) == currentTitle
            else { continue }
            lines[index] = "# \(MarkdownNoteRenderer.headingText(title))"
            renamedHeading = true
            break
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
        var lines = Frontmatter.normalizedLines(contents)
        let pinnedLines = isPinned ? ["pinned: true"] : []

        guard let end = Frontmatter.end(of: lines) else {
            if isPinned { lines.insert(contentsOf: ["---"] + pinnedLines + ["---", ""], at: 0) }
            return lines.joined(separator: "\n")
        }
        if let field = Frontmatter.fieldLines("pinned", in: lines, end: end) {
            lines.replaceSubrange(field, with: pinnedLines)
        } else {
            lines.insert(contentsOf: pinnedLines, at: end)
        }
        // Frontmatter left empty goes, with the blank line pinning added after it.
        if !isPinned, Frontmatter.end(of: lines) == 1 {
            lines.removeFirst(lines.count > 2 && lines[2].isEmpty ? 3 : 2)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Speakers

    /// `contents` with the speaker `old` renamed `new`, or `nil` if the note has no such speaker
    /// or nothing changes. `new` is a single line with no runs of whitespace. Renaming a speaker
    /// to the name of another merges the two.
    ///
    /// Changes the frontmatter's `speakers` and `talk_labels`, and in the body, where
    /// `MarkdownNoteRenderer` writes the speaker: before each of their lines in the transcript and
    /// translation, before quotes in the moments, and in the Talk Time section. A label with a
    /// number in it, such as "Others (Speaker 2)", which can't be mistaken for a word, is replaced
    /// wherever else the body has it too, as summaries may name speakers by their labels. Code
    /// blocks and headings of level 2 and below are left alone. Line endings become `\n`.
    static func renamingSpeaker(_ contents: String, from old: String, to new: String) -> String? {
        guard !old.isEmpty, !new.isEmpty, old != new else { return nil }
        var lines = Frontmatter.normalizedLines(contents)
        let original = lines

        var bodyStart = 0
        if let end = Frontmatter.end(of: lines) {
            for key in ["speakers", "talk_labels"] {
                guard let field = Frontmatter.fieldLines(key, in: lines, end: end) else { continue }
                let value = Frontmatter.value(of: lines[field])
                guard let items = Frontmatter.yamlSequence(value), items.contains(old) else { continue }
                var renamed = items.map { $0 == old ? new : $0 }
                // Two speakers merged into one. Talk Time's labels stay two, for its two sides.
                if key == "speakers" {
                    var seen = Set<String>()
                    renamed = renamed.filter { seen.insert($0).inserted }
                }
                let quoted = renamed.map(MarkdownNoteRenderer.yamlQuoted)
                // Written the way it was: Obsidian writes lists an item per line.
                lines.replaceSubrange(
                    field,
                    with: value.first == "["
                        ? ["\(key): [\(quoted.joined(separator: ", "))]"] : ["\(key):"] + quoted.map { "  - \($0)" }
                )
            }
            bodyStart = (Frontmatter.end(of: lines) ?? 0) + 1
        }

        let escapedOld = MarkdownNoteRenderer.escapedMarkdown(old)
        let escapedNew = MarkdownNoteRenderer.escapedMarkdown(new)
        // Matched only as a whole label, so "Speaker 1" isn't found in "Speaker 12".
        let isDistinctive = old.contains(where: \.isNumber)
        let elsewhere = try? NSRegularExpression(
            pattern: "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: escapedOld) + "(?![\\p{L}\\p{N}])"
        )
        for index in linesOutsideCode(lines, from: bodyStart) {
            var line = lines[index]
            if let (level, _) = Parser.atxHeading(line.trimmingCharacters(in: .whitespaces)), level > 1 { continue }
            if isDistinctive, let elsewhere {
                lines[index] = elsewhere.stringByReplacingMatches(
                    in: line,
                    range: NSRange(line.startIndex..., in: line),
                    withTemplate: NSRegularExpression.escapedTemplate(for: escapedNew)
                )
                continue
            }
            // A transcript line: `**[00:01:02] Speaker:** text`.
            if line.hasPrefix("**["), let close = line.range(of: "] "),
                line[close.upperBound...].hasPrefix(escapedOld + ":**")
            {
                let label = close.upperBound..<line.index(close.upperBound, offsetBy: escapedOld.count)
                line.replaceSubrange(label, with: escapedNew)
            }
            // A moment: `- **[00:01:02]** Note — _Speaker: “words”_`.
            if line.hasPrefix("- **["), let quote = line.range(of: " _\(escapedOld): “") {
                line.replaceSubrange(quote, with: " _\(escapedNew): “")
            }
            // Talk Time's share of each side, `**Me** 40 % (…) · **Others** 60 % (…)`, and its table.
            if line.hasPrefix("**") || line.hasPrefix("| Minute |") {
                line = line.replacingOccurrences(of: "**\(escapedOld)** ", with: "**\(escapedNew)** ")
                let cell = { (text: String) in text.replacingOccurrences(of: "|", with: "\\|") }
                line = line.replacingOccurrences(of: "| \(cell(escapedOld)) |", with: "| \(cell(escapedNew)) |")
            }
            lines[index] = line
        }
        return lines == original ? nil : lines.joined(separator: "\n")
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
        var lines = Frontmatter.normalizedLines(contents)
        var isChanged = false
        let replace = { (index: Int, line: String) in
            guard line != lines[index] else { return }
            lines[index] = line
            isChanged = true
        }

        var bodyStart = 0
        if let end = Frontmatter.end(of: lines) {
            if let field = Frontmatter.fieldLines("title", in: lines, end: end), field.count == 1,
                let colon = lines[field.lowerBound].firstIndex(of: ":")
            {
                let raw = lines[field.lowerBound][lines[field.lowerBound].index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
                let title = Frontmatter.yamlScalar(raw)
                let corrected = correction.plain.replace(in: title)
                if corrected != title {
                    replace(field.lowerBound, "title: \(MarkdownNoteRenderer.yamlQuoted(corrected))")
                }
            }
            bodyStart = end + 1
        }

        for index in linesOutsideCode(lines, from: bodyStart) {
            if let (level, _) = Parser.atxHeading(lines[index].trimmingCharacters(in: .whitespaces)), level > 1 {
                continue
            }
            replace(index, correction.markdown.replace(in: lines[index]))
        }
        return isChanged ? lines.joined(separator: "\n") : nil
    }

    /// The indices of `lines` from `start` on that are outside fenced code blocks, without the
    /// fences themselves.
    private static func linesOutsideCode(_ lines: [String], from start: Int) -> [Int] {
        var indices: [Int] = []
        var fence: Substring?
        for index in lines.indices.dropFirst(start) {
            if let open = fence {
                if Parser.isClosingFence(lines[index], for: open) { fence = nil }
                continue
            }
            if let (open, _) = Parser.openingFence(lines[index].trimmingCharacters(in: .whitespaces)) {
                fence = open
            } else {
                indices.append(index)
            }
        }
        return indices
    }
}
