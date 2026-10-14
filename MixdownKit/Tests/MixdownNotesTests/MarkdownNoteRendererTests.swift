import Foundation
import MixdownCore
import MixdownNotes
import Testing

enum NoteFixtures {
    static let createdAt = Date(timeIntervalSince1970: 1_760_000_000)

    static func note(
        title: String = "Weekly Sync",
        duration: TimeInterval = 65.4,
        segments: [TranscriptSegment] = [
            TranscriptSegment(start: 0, end: 4, text: " Hello everyone."),
            TranscriptSegment(start: 65, end: 70, text: "Next topic. "),
        ],
        language: String? = "en",
        sources: [AudioInputDevice] = [
            AudioInputDevice(id: "builtin", name: "MacBook Pro Microphone", kind: .microphone)
        ]
    ) -> Note {
        Note(
            title: title,
            createdAt: createdAt,
            duration: duration,
            sources: sources,
            engine: TranscriptionEngineInfo(id: "speech-swift", displayName: "Qwen3-ASR 0.6B"),
            transcript: Transcript(segments: segments, language: language)
        )
    }
}

struct MarkdownNoteRendererTests {
    private func frontmatterLines(_ markdown: String) -> [String] {
        let lines = markdown.components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return [] }
        return Array(lines[1..<end])
    }

    @Test func frontmatterContainsMetadata() throws {
        let markdown = MarkdownNoteRenderer.render(NoteFixtures.note())
        let lines = frontmatterLines(markdown)

        #expect(markdown.hasPrefix("---\n"))
        #expect(lines.contains(#"title: "Weekly Sync""#))
        #expect(lines.contains("duration: 65"))
        #expect(lines.contains(#"source: "MacBook Pro Microphone""#))
        #expect(lines.contains("source_kind: microphone"))
        #expect(lines.contains(#"engine: "Qwen3-ASR 0.6B""#))
        #expect(lines.contains(#"language: "en""#))
        #expect(lines.contains("tags: [mixdown]"))

        let created = try #require(lines.first { $0.hasPrefix("created: ") })
        let parsed = ISO8601DateFormatter().date(from: String(created.dropFirst("created: ".count)))
        #expect(parsed == NoteFixtures.createdAt)
    }

    @Test func listsMultipleSources() {
        let markdown = MarkdownNoteRenderer.render(
            NoteFixtures.note(sources: [
                AudioInputDevice(id: "builtin", name: "MacBook Pro Microphone", kind: .microphone),
                .systemAudio,
            ])
        )
        let lines = frontmatterLines(markdown)

        #expect(lines.contains(#"sources: ["MacBook Pro Microphone", "System Audio"]"#))
        #expect(lines.contains("source_kinds: [microphone, systemAudio]"))
        #expect(!lines.contains { $0.hasPrefix("source:") || $0.hasPrefix("source_kind:") })
    }

    @Test func omitsLanguageWhenUnknown() {
        let markdown = MarkdownNoteRenderer.render(NoteFixtures.note(language: nil))
        #expect(!frontmatterLines(markdown).contains { $0.hasPrefix("language:") })
    }

    @Test func bodyHasHeadingAndTimestampedParagraphs() {
        let markdown = MarkdownNoteRenderer.render(NoteFixtures.note())

        #expect(markdown.contains("\n# Weekly Sync\n"))
        #expect(markdown.contains("\n## Transcript\n\n**[00:00:00]** Hello everyone.\n\n**[00:01:05]** Next topic.\n"))
        #expect(!markdown.contains("_No speech detected._"))
    }

    @Test func omitsSpeakersWithoutDiarization() {
        let markdown = MarkdownNoteRenderer.render(NoteFixtures.note())
        #expect(!frontmatterLines(markdown).contains { $0.hasPrefix("speakers:") })
    }

    @Test func labelsDiarizedSegments() {
        let markdown = MarkdownNoteRenderer.render(
            NoteFixtures.note(segments: [
                TranscriptSegment(start: 0, end: 2, text: "Hi.", speaker: "Speaker 1"),
                TranscriptSegment(start: 2, end: 4, text: "Hello!", speaker: "Speaker 2"),
                TranscriptSegment(start: 4, end: 6, text: "Shall we?", speaker: "Speaker 1"),
            ])
        )
        #expect(frontmatterLines(markdown).contains(#"speakers: ["Speaker 1", "Speaker 2"]"#))
        #expect(markdown.contains("**[00:00:00] Speaker 1:** Hi.\n\n**[00:00:02] Speaker 2:** Hello!"))
    }

    @Test func formatsHoursInTimestamps() {
        let markdown = MarkdownNoteRenderer.render(
            NoteFixtures.note(segments: [TranscriptSegment(start: 3723.9, end: 3725, text: "Late")])
        )
        #expect(markdown.contains("**[01:02:03]** Late"))
    }

    @Test func emptyTranscriptShowsPlaceholder() {
        let markdown = MarkdownNoteRenderer.render(
            NoteFixtures.note(segments: [TranscriptSegment(start: 0, end: 1, text: "  ")])
        )
        #expect(markdown.hasSuffix("## Transcript\n\n_No speech detected._\n"))
        #expect(!markdown.contains("**["))
    }

    @Test func escapesTitleInYAML() {
        let markdown = MarkdownNoteRenderer.render(NoteFixtures.note(title: #"Say "hi" \ now"#))
        #expect(frontmatterLines(markdown).contains(#"title: "Say \"hi\" \\ now""#))
        #expect(markdown.contains(#"# Say "hi" \ now"#))
    }

    @Test func multilineTitleStaysOnOneLine() {
        let markdown = MarkdownNoteRenderer.render(NoteFixtures.note(title: "First\nSecond"))
        #expect(frontmatterLines(markdown).contains(#"title: "First Second""#))
        #expect(markdown.contains("\n# First Second\n"))
    }
}
