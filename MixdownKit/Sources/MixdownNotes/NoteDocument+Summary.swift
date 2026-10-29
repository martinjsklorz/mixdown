import Foundation
import MixdownCore

/// Summarizing a saved note again, e.g. with another template, or after its summary failed: what
/// the summary is made from, read back from the note, and the note with a new summary.
extension NoteDocument {
    /// What a note's summary is made from.
    public struct SummarySource: Sendable, Equatable {
        /// The note's transcript, or its translation if it has one, as the summary is in the
        /// translation's language then. Each line lasts until the next one starts, the last until
        /// the end of the recording.
        public var transcript: Transcript
        /// The moments the user marked, with what they wrote about them.
        public var moments: [Moment]
    }

    /// What the summary of the note with `contents` is made from, read the way
    /// `MarkdownNoteRenderer` writes it: the lines of `## Translation`, or else `## Transcript`,
    /// and the moments under `### Moments` in the summary or in `## Moments`. `nil` if there are no
    /// transcript lines. Lines edited by hand that don't start with a time are taken to continue
    /// the line before.
    public static func summarySource(of contents: String) -> SummarySource? {
        let lines = Frontmatter.normalizedLines(contents)
        let fields = Frontmatter.split(contents).fields.mapValues(Frontmatter.yamlScalar)
        let duration = fields["duration"].flatMap(TimeInterval.init).flatMap { $0.isFinite ? $0 : nil }
        let headings = Self.headings(in: lines)

        let transcript = [
            (MarkdownNoteRenderer.translationHeading, fields["translation_language"]),
            (MarkdownNoteRenderer.transcriptHeading, fields["language"]),
        ]
        .lazy
        .compactMap { heading, language -> Transcript? in
            guard let section = Self.section(heading, level: 2, in: lines, headings: headings) else { return nil }
            let segments = Self.transcriptSegments(lines[section.dropFirst()], duration: duration)
            return segments.isEmpty
                ? nil : Transcript(segments: segments, language: language.flatMap { $0.isEmpty ? nil : $0 })
        }
        .first
        guard let transcript else { return nil }

        let moments = Self.momentLines(in: lines, headings: headings).map { Self.moments(in: lines[$0]) } ?? []
        return SummarySource(transcript: transcript, moments: moments)
    }

    /// `contents` with the summary replaced by `summary`, laid out like a new note's, and the
    /// frontmatter's `template` set to `summary.template`. The moments stay as they are, last in the
    /// summary. A note without a summary gets one before its translation or transcript. Returns
    /// `nil` if the summary has nothing to show. Line endings become `\n`.
    public static func replacingSummary(in contents: String, with summary: NoteSummary) -> String? {
        guard let summaryBody = MarkdownNoteRenderer.summaryBody(summary) else { return nil }
        var lines = Frontmatter.normalizedLines(contents)

        if let end = Frontmatter.end(of: lines) {
            let field = MarkdownNoteRenderer.templateField(for: summary.template).map { ["template: \($0)"] } ?? []
            if let existing = Frontmatter.fieldLines("template", in: lines, end: end) {
                lines.replaceSubrange(existing, with: field)
            } else {
                // Where a new note has it: before the fields that follow it there.
                let later = ["language", "translation_language", "speakers", "talk_labels", "tags"]
                let index = lines[1..<end].firstIndex { Frontmatter.key(of: $0).map(later.contains) ?? false } ?? end
                lines.insert(contentsOf: field, at: index)
            }
        }

        let headings = Self.headings(in: lines)
        let momentLines = Self.momentLines(in: lines, headings: headings).map { Array(lines[$0]) }
        var section = ["## Summary", "", summaryBody]
        if let momentLines, !momentLines.isEmpty {
            section += ["", "### Moments", ""] + momentLines
        }

        let summary = Self.section("Summary", level: 2, in: lines, headings: headings)
        let moments = Self.section("Moments", level: 2, in: lines, headings: headings)
        if let replaced = summary ?? moments {
            // Followed by a blank line, unless it's the end of the note.
            let followed = replaced.upperBound < lines.endIndex
            lines.replaceSubrange(replaced, with: section + (followed ? [""] : []))
        } else {
            let before =
                [MarkdownNoteRenderer.translationHeading, MarkdownNoteRenderer.transcriptHeading].lazy
                .compactMap { heading in headings.first { $0.level == 2 && $0.text == heading } }.first
                ?? headings.first { $0.level == 2 }
            if let before {
                lines.insert(contentsOf: section + [""], at: before.index)
            } else {
                if lines.last?.isEmpty == true { lines.removeLast() }
                lines += [""] + section + [""]
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Sections

    private struct Heading {
        var index: Int
        var level: Int
        /// As plain text.
        var text: String
    }

    /// The ATX headings of the body, outside code blocks.
    private static func headings(in lines: [String]) -> [Heading] {
        let bodyStart = Frontmatter.end(of: lines).map { $0 + 1 } ?? 0
        return linesOutsideCode(lines, from: bodyStart).compactMap { index in
            guard let (level, text) = Parser.atxHeading(lines[index].trimmingCharacters(in: .whitespaces)) else {
                return nil
            }
            return Heading(index: index, level: level, text: unescaped(text).trimmingCharacters(in: .whitespaces))
        }
    }

    /// The lines of the first section headed `title` at `level`, from its heading to the next
    /// heading of that level or above.
    private static func section(_ title: String, level: Int, in lines: [String], headings: [Heading]) -> Range<Int>? {
        guard let start = headings.firstIndex(where: { $0.level == level && $0.text == title }) else { return nil }
        let end = headings[(start + 1)...].first { $0.level <= level }?.index ?? lines.endIndex
        return headings[start].index..<end
    }

    /// The lines listing the moments, without their heading or blank lines around them: under
    /// `### Moments` in the summary, or in `## Moments` for a note without a summary.
    private static func momentLines(in lines: [String], headings: [Heading]) -> Range<Int>? {
        var range: Range<Int>?
        if let summary = section("Summary", level: 2, in: lines, headings: headings),
            let heading = headings.first(where: { summary.contains($0.index) && $0.level == 3 && $0.text == "Moments" })
        {
            let end = headings.first { $0.index > heading.index && $0.level <= 3 }?.index ?? summary.upperBound
            range = (heading.index + 1)..<min(end, summary.upperBound)
        } else if let section = section("Moments", level: 2, in: lines, headings: headings) {
            range = (section.lowerBound + 1)..<section.upperBound
        }
        guard var range else { return nil }
        while let first = range.first, lines[first].allSatisfy(\.isWhitespace) { range = range.dropFirst() }
        while let last = range.last, lines[last].allSatisfy(\.isWhitespace) { range = range.dropLast() }
        return range
    }

    // MARK: - Lines

    /// `**[00:01:02] Speaker:** text` or `**[00:01:02]** text`.
    private static let transcriptLine = try? NSRegularExpression(
        pattern: #"^\*\*\[(\d+):(\d{2}):(\d{2})\](?: (.+?):)?\*\*\s*(.*)$"#
    )
    /// `- **[00:01:02]** text`.
    private static let momentLine = try? NSRegularExpression(
        pattern: #"^- \*\*\[(\d+):(\d{2}):(\d{2})\]\*\*\s*(.*)$"#
    )

    private static func transcriptSegments(_ lines: ArraySlice<String>, duration: TimeInterval?) -> [TranscriptSegment]
    {
        var segments: [TranscriptSegment] = []
        for line in lines {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let match = match(transcriptLine, in: line), let time = seconds(match, in: line) {
                let speaker = group(4, of: match, in: line).map(unescaped)
                let text = unescaped(group(5, of: match, in: line) ?? "")
                segments.append(TranscriptSegment(start: time, end: time, text: text, speaker: speaker))
            } else if !segments.isEmpty, line != MarkdownNoteRenderer.emptyTranscriptPlaceholder {
                segments[segments.count - 1].text += " " + unescaped(line)
            }
        }
        segments.removeAll { $0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        for index in segments.indices {
            let next = index + 1 < segments.count ? segments[index + 1].start : duration
            segments[index].end = max(next ?? segments[index].start, segments[index].start)
        }
        return segments
    }

    /// The moments in `lines`, with what the user wrote: the text before the quote of what was
    /// being said.
    private static func moments(in lines: ArraySlice<String>) -> [Moment] {
        lines.compactMap { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard let match = match(momentLine, in: line), let time = seconds(match, in: line) else { return nil }
            let rest = group(4, of: match, in: line) ?? ""
            // The quote, or the placeholder, is in italics; what the user wrote is escaped.
            let written = rest.components(separatedBy: " — ").first ?? ""
            let text = written.hasPrefix("_") ? "" : unescaped(written)
            return Moment(time: time, text: text)
        }
    }

    private static func match(_ expression: NSRegularExpression?, in line: String) -> NSTextCheckingResult? {
        expression?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
    }

    private static func group(_ index: Int, of match: NSTextCheckingResult, in line: String) -> String? {
        Range(match.range(at: index), in: line).map { String(line[$0]) }
    }

    /// The `HH:MM:SS` in the first three groups, in seconds.
    private static func seconds(_ match: NSTextCheckingResult, in line: String) -> TimeInterval? {
        guard let hours = group(1, of: match, in: line).flatMap(Int.init),
            let minutes = group(2, of: match, in: line).flatMap(Int.init), minutes < 60,
            let seconds = group(3, of: match, in: line).flatMap(Int.init), seconds < 60
        else { return nil }
        return TimeInterval(hours * 3600 + minutes * 60 + seconds)
    }

    private static let escape = try? NSRegularExpression(pattern: #"\\([!-/:-@\[-`{-~])"#)

    /// `text` without the backslashes `MarkdownNoteRenderer.escapedMarkdown(_:)` puts before
    /// Markdown's punctuation.
    static func unescaped(_ text: String) -> String {
        guard let escape else { return text }
        return escape.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: "$1"
        )
    }
}
