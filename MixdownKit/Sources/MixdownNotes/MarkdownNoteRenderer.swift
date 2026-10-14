import Foundation
import MixdownCore

/// Renders a `Note` as Markdown with YAML frontmatter.
///
/// Layout: frontmatter, `# Title`, then one `##` section per body part. Today that is only
/// `## Transcript`; further sections (e.g. `## Summary`) are added in `bodySections(for:)`.
public enum MarkdownNoteRenderer {
    /// Shown instead of transcript paragraphs when nothing was recognized.
    public static let emptyTranscriptPlaceholder = "_No speech detected._"

    public static func render(_ note: Note) -> String {
        let title = singleLine(note.title)
        let blocks = [frontmatter(for: note), "# \(title.isEmpty ? "Untitled" : title)"]
            + bodySections(for: note)
        return blocks.joined(separator: "\n\n") + "\n"
    }

    // MARK: - Sections

    static func frontmatter(for note: Note) -> String {
        var lines = ["---"]
        lines.append("title: \(yamlQuoted(singleLine(note.title)))")
        lines.append("created: \(iso8601(note.createdAt))")
        lines.append("duration: \(wholeSeconds(note.duration))")
        lines.append("source: \(yamlQuoted(note.source.name))")
        lines.append("source_kind: \(note.source.kind.rawValue)")
        lines.append("engine: \(yamlQuoted(note.engine.displayName))")
        if let language = note.transcript.language, !language.isEmpty {
            // Quoted so codes like `no` (Norwegian) aren't read as YAML booleans.
            lines.append("language: \(yamlQuoted(language))")
        }
        let speakers = note.transcript.speakers.map { singleLine($0) }.filter { !$0.isEmpty }
        if !speakers.isEmpty {
            lines.append("speakers: [\(speakers.map(yamlQuoted).joined(separator: ", "))]")
        }
        lines.append("tags: [mixdown]")
        lines.append("---")
        return lines.joined(separator: "\n")
    }

    /// Body sections in display order. A future summary goes before the transcript.
    static func bodySections(for note: Note) -> [String] {
        [section("Transcript", body: transcriptBody(note.transcript))]
    }

    static func section(_ heading: String, body: String) -> String {
        "## \(heading)\n\n\(body)"
    }

    static func transcriptBody(_ transcript: Transcript) -> String {
        let paragraphs = transcript.segments.compactMap { segment -> String? in
            let text = singleLine(segment.text)
            guard !text.isEmpty else { return nil }
            if let speaker = segment.speaker.map(singleLine), !speaker.isEmpty {
                return "**[\(timestamp(segment.start))] \(speaker):** \(text)"
            }
            return "**[\(timestamp(segment.start))]** \(text)"
        }
        return paragraphs.isEmpty ? emptyTranscriptPlaceholder : paragraphs.joined(separator: "\n\n")
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
