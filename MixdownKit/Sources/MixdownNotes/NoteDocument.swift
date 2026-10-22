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
    /// The transcript's speakers in order of first appearance, from the frontmatter's `speakers`
    /// list. Empty for a transcript without labels.
    public var speakers: [String]
    /// How long each side talked, minute by minute, from the frontmatter's `talk_microphone` and
    /// `talk_system_audio` lists. `nil` if they're missing or unusable.
    public var talkTimeline: TalkTimeline?

    public var id: URL { url }

    static let maxSnippetLength = 200
    /// About 31 years. Larger values, like `inf` or `1e30`, would overflow `Duration`.
    static let maxDuration: TimeInterval = 1_000_000_000

    public init(url: URL, contents: String, fileDate: Date) {
        let (fields, body) = Frontmatter.split(contents)
        let scalars = fields.mapValues(Frontmatter.yamlScalar)
        let blocks = MarkdownBlock.parse(body)

        self.url = url
        self.body = body
        self.title = Self.title(fields: scalars, blocks: blocks, url: url)
        self.createdAt = scalars["created"].flatMap(Frontmatter.date(fromYAML:)) ?? fileDate
        // `nan` fails the range check too.
        self.duration = scalars["duration"].flatMap(TimeInterval.init).flatMap {
            (0...Self.maxDuration).contains($0) ? $0 : nil
        }
        let sources = fields["sources"].flatMap(Frontmatter.yamlFlowSequence) ?? scalars["source"].map { [$0] } ?? []
        self.sources = sources.filter { !$0.isEmpty }
        self.trigger = scalars["trigger"].flatMap(RecordingTrigger.init(rawValue:))
        self.template = scalars["template"].flatMap { $0.isEmpty ? nil : $0 }
        // YAML's `true`, `True` and `TRUE`.
        self.isPinned = scalars["pinned"]?.lowercased() == "true"
        self.speakers = (fields["speakers"].flatMap(Frontmatter.yamlFlowSequence) ?? []).filter { !$0.isEmpty }
        self.talkTimeline = Self.talkTimeline(fields: fields)
        self.snippet = Self.snippet(from: blocks)
        self.isCall =
            scalars["call"]?.lowercased() == "true" || trigger == .automatic
            || template == SummaryTemplate.clientCall.id
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
            guard let items = fields[key].flatMap(Frontmatter.yamlFlowSequence), !items.isEmpty else { return nil }
            let values = items.compactMap(TimeInterval.init)
            // `nan` fails the range check too.
            guard values.count == items.count, values.allSatisfy({ (0...TalkTimeline.interval).contains($0) })
            else { return nil }
            return values
        }
        guard let microphone = seconds("talk_microphone"), let systemAudio = seconds("talk_system_audio") else {
            return nil
        }
        let labels = fields["talk_labels"].flatMap(Frontmatter.yamlFlowSequence) ?? []
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
            Self.section(MarkdownNoteRenderer.transcriptHeading, in: blocks).map {
                blocks[($0.lowerBound + 1)..<$0.upperBound]
            } ?? blocks[...]

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
}
