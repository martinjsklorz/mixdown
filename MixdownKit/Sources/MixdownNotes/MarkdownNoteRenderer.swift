import Foundation
import MixdownCore

/// Renders a `Note` as Markdown with YAML frontmatter.
///
/// Layout: frontmatter, `# Title`, then one `##` section per body part: `## Summary` if the
/// note has one, `## Translation` if it has one, `## Transcript`, then `## Talk Time` if the note
/// has a talk timeline. Sections are added in `bodySections(for:)`.
public enum MarkdownNoteRenderer {
    /// Shown instead of transcript paragraphs when nothing was recognized.
    static let emptyTranscriptPlaceholder = "_No speech detected._"
    /// Shown under a fixed summary section the summary has nothing for.
    static let emptySectionPlaceholder = "_None._"
    /// The heading of the talk timeline's section, which the app shows as a chart instead.
    public static let talkTimeHeading = "Talk Time"
    /// The talk timeline's bars are this many blocks long for a minute of talking.
    static let talkBarLength = 10

    public static func render(_ note: Note) -> String {
        let title = singleLine(note.title)
        let blocks =
            [frontmatter(for: note), "# \(title.isEmpty ? "Untitled" : headingText(title))"]
            + bodySections(for: note)
        return blocks.joined(separator: "\n\n") + "\n"
    }

    // MARK: - Sections

    static func frontmatter(for note: Note) -> String {
        var lines = ["---"]
        lines.append("title: \(yamlQuoted(singleLine(note.title)))")
        lines.append("created: \(iso8601(note.createdAt))")
        lines.append("duration: \(wholeSeconds(note.duration))")
        if let source = note.sources.first, note.sources.count == 1 {
            lines.append("source: \(yamlQuoted(source.name))")
            lines.append("source_kind: \(source.kind.rawValue)")
        } else if !note.sources.isEmpty {
            lines.append("sources: [\(note.sources.map { yamlQuoted($0.name) }.joined(separator: ", "))]")
            lines.append("source_kinds: [\(note.sources.map(\.kind.rawValue).joined(separator: ", "))]")
        }
        lines.append("engine: \(yamlQuoted(note.engine.displayName))")
        lines.append("trigger: \(note.trigger.rawValue)")
        if let language = note.transcript.language, !language.isEmpty {
            // Quoted so codes like `no` (Norwegian) aren't read as YAML booleans.
            lines.append("language: \(yamlQuoted(language))")
        }
        if let language = note.translation?.language, !language.isEmpty {
            lines.append("translation_language: \(yamlQuoted(language))")
        }
        let speakers = note.transcript.speakers.map { singleLine($0) }.filter { !$0.isEmpty }
        if !speakers.isEmpty {
            lines.append("speakers: [\(speakers.map(yamlQuoted).joined(separator: ", "))]")
        }
        if let timeline = note.talkTimeline {
            let labels = [timeline.microphoneLabel, timeline.systemAudioLabel].map { yamlQuoted(singleLine($0)) }
            let seconds = { (minutes: [TimeInterval]) in
                minutes.map { String(wholeSeconds($0)) }.joined(separator: ", ")
            }
            lines.append("talk_labels: [\(labels.joined(separator: ", "))]")
            lines.append("talk_microphone: [\(seconds(timeline.microphone))]")
            lines.append("talk_system_audio: [\(seconds(timeline.systemAudio))]")
        }
        lines.append("tags: [mixdown]")
        lines.append("---")
        return lines.joined(separator: "\n")
    }

    /// Body sections in display order.
    static func bodySections(for note: Note) -> [String] {
        var sections: [String] = []
        if let summary = note.summary.flatMap(summaryBody) {
            sections.append(section("Summary", body: summary))
        }
        if let translation = note.translation {
            sections.append(section("Translation", body: transcriptBody(translation)))
        }
        sections.append(section("Transcript", body: transcriptBody(note.transcript)))
        if let timeline = note.talkTimeline {
            sections.append(section(talkTimeHeading, body: talkTimeBody(timeline)))
        }
        return sections
    }

    static func section(_ heading: String, body: String) -> String {
        "## \(heading)\n\n\(body)"
    }

    /// Templates with fixed sections get `###` TL;DR, Decisions, Action Items and Open Questions,
    /// each shown even when empty, so every note of a kind reads the same. The `general` template
    /// gets the overview, then `###` lists of key points and action items, leaving out empty parts.
    /// Action items are `- [ ]` task items to tick off. `nil` if the summary has nothing to show.
    static func summaryBody(_ summary: NoteSummary) -> String? {
        let overview = escapedMarkdown(singleLine(summary.overview))
        let list = { (marker: String, items: [String]) -> String in
            items.map { escapedMarkdown(singleLine($0)) }.filter { !$0.isEmpty }.map { marker + $0 }
                .joined(separator: "\n")
        }
        var blocks: [String] = []
        if summary.template.hasFixedSections {
            let sections = [
                ("TL;DR", overview), ("Decisions", list("- ", summary.decisions)),
                ("Action Items", list("- [ ] ", summary.actionItems)),
                ("Open Questions", list("- ", summary.openQuestions)),
            ]
            guard sections.contains(where: { !$0.1.isEmpty }) else { return nil }
            for (heading, body) in sections {
                blocks.append("### \(heading)\n\n" + (body.isEmpty ? emptySectionPlaceholder : body))
            }
        } else {
            if !overview.isEmpty { blocks.append(overview) }
            for (heading, body) in [
                ("Key Points", list("- ", summary.keyPoints)), ("Action Items", list("- [ ] ", summary.actionItems)),
            ] where !body.isEmpty {
                blocks.append("### \(heading)\n\n" + body)
            }
        }
        return blocks.isEmpty ? nil : blocks.joined(separator: "\n\n")
    }

    static func transcriptBody(_ transcript: Transcript) -> String {
        let paragraphs = transcript.segments.compactMap { segment -> String? in
            let text = escapedMarkdown(singleLine(segment.text))
            guard !text.isEmpty else { return nil }
            if let speaker = segment.speaker.map({ escapedMarkdown(singleLine($0)) }), !speaker.isEmpty {
                return "**[\(timestamp(segment.start))] \(speaker):** \(text)"
            }
            return "**[\(timestamp(segment.start))]** \(text)"
        }
        return paragraphs.isEmpty ? emptyTranscriptPlaceholder : paragraphs.joined(separator: "\n\n")
    }

    /// Each side's share of the talking, then a table of how long each talked in every minute,
    /// with a bar of `█` per tenth of the minute.
    static func talkTimeBody(_ timeline: TalkTimeline) -> String {
        let microphone = escapedMarkdown(singleLine(timeline.microphoneLabel))
        let systemAudio = escapedMarkdown(singleLine(timeline.systemAudioLabel))
        let total = timeline.total
        var blocks: [String] = []
        if let percentages = total.percentages {
            blocks.append(
                "**\(microphone)** \(percentages.microphone) % (\(minutesAndSeconds(total.microphone))) · "
                    + "**\(systemAudio)** \(percentages.systemAudio) % (\(minutesAndSeconds(total.systemAudio)))"
            )
        }
        // Pipes would end a table cell.
        let cell = { (text: String) in text.replacingOccurrences(of: "|", with: "\\|") }
        var rows = ["| Minute | \(cell(microphone)) | \(cell(systemAudio)) |", "| --- | --- | --- |"]
        for (index, (mine, theirs)) in zip(timeline.microphone, timeline.systemAudio).enumerated() {
            let start = timestamp(Double(index) * TalkTimeline.interval)
            rows.append("| \(start) | \(talkBar(mine)) | \(talkBar(theirs)) |")
        }
        blocks.append(rows.joined(separator: "\n"))
        return blocks.joined(separator: "\n\n")
    }

    /// E.g. `███ 21 s`; `–` for no talking.
    private static func talkBar(_ seconds: TimeInterval) -> String {
        let whole = wholeSeconds(seconds)
        guard whole > 0 else { return "–" }
        let blocks = max(Int((seconds / TalkTimeline.interval * Double(talkBarLength)).rounded()), 1)
        return String(repeating: "█", count: min(blocks, talkBarLength)) + " \(whole) s"
    }

    /// E.g. `4 min 05 s`, or `35 s` under a minute.
    static func minutesAndSeconds(_ seconds: TimeInterval) -> String {
        let total = wholeSeconds(seconds)
        return total < 60 ? "\(total) s" : "\(total / 60) min \(pad(total % 60)) s"
    }

    // MARK: - Formatting helpers

    /// `HH:MM:SS` for an offset in seconds; hours are not capped at 24.
    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds)) : 0
        return "\(pad(total / 3600)):\(pad(total % 3600 / 60)):\(pad(total % 60))"
    }

    static func wholeSeconds(_ duration: TimeInterval) -> Int {
        guard duration.isFinite, duration > 0 else { return 0 }
        return Int(duration.rounded())
    }

    static func iso8601(_ date: Date) -> String {
        // Created per call: formatters aren't guaranteed Sendable, and notes are rare.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    /// A YAML double-quoted scalar with backslashes, quotes and control characters escaped.
    static func yamlQuoted(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default:
                if scalar.properties.generalCategory == .control {
                    let hex = String(scalar.value, radix: 16, uppercase: true)
                    escaped += "\\u" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return "\"\(escaped)\""
    }

    /// Backslash-escapes the characters that start inline Markdown, inline HTML or entities, so
    /// text shows as written. Block syntax needs no escaping: the text never starts a line.
    static func escapedMarkdown(_ text: String) -> String {
        var escaped = ""
        for character in text {
            if "\\`*_[]<&~".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    /// `escapedMarkdown(_:)` for the text of a `#` heading, also escaping trailing `#`s that
    /// would otherwise close the heading and be dropped.
    static func headingText(_ text: String) -> String {
        let escaped = escapedMarkdown(text)
        guard let closing = escaped.range(of: #"(^|\s)#+$"#, options: .regularExpression),
            let marks = escaped[closing].firstIndex(of: "#")
        else { return escaped }
        return String(escaped[..<marks]) + "\\" + escaped[marks...]
    }

    /// Collapses line breaks so multi-line text stays a single Markdown line or paragraph.
    static func singleLine(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func pad(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
