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
        ],
        translation: Transcript? = nil,
        summary: NoteSummary? = nil,
        trigger: RecordingTrigger = .manual,
        isCall: Bool? = nil,
        template: SummaryTemplate? = nil,
        moments: [Moment] = [],
        talkTimeline: TalkTimeline? = nil
    ) -> Note {
        Note(
            title: title,
            createdAt: createdAt,
            duration: duration,
            sources: sources,
            engine: TranscriptionEngineInfo(id: "speech-swift", displayName: "Qwen3-ASR 0.6B"),
            transcript: Transcript(segments: segments, language: language),
            translation: translation,
            summary: summary,
            trigger: trigger,
            isCall: isCall,
            template: template,
            moments: moments,
            talkTimeline: talkTimeline
        )
    }

    static let talkTimeline = TalkTimeline(
        microphoneLabel: "Me",
        systemAudioLabel: "Others | Team",
        microphone: [35.4, 0.2, 60],
        systemAudio: [12, 50, 0]
    )
}

struct MarkdownNoteRendererTests {
    private func frontmatterLines(_ markdown: String) -> [String] {
        let lines = markdown.components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return [] }
        return Array(lines[1..<end])
    }

    @Test func frontmatterSaysWhatKindOfRecordingItIs() {
        let call = frontmatterLines(MarkdownNoteRenderer.render(NoteFixtures.note(isCall: true, template: .oneOnOne)))
        #expect(call.contains("call: true"))
        #expect(call.contains("template: oneOnOne"))

        let memo = frontmatterLines(MarkdownNoteRenderer.render(NoteFixtures.note(template: .general)))
        #expect(!memo.contains { $0.hasPrefix("call:") || $0.hasPrefix("template:") })

        // A renamed built-in still goes by its id, the user's own templates by name.
        var renamed = SummaryTemplate.oneOnOne
        renamed.name = "Check-in"
        let checkIn = frontmatterLines(MarkdownNoteRenderer.render(NoteFixtures.note(template: renamed)))
        #expect(checkIn.contains("template: oneOnOne"))
        let review = SummaryTemplate(id: "custom-1", name: "Sprint \"Review\"\n", layout: .sections)
        let custom = frontmatterLines(MarkdownNoteRenderer.render(NoteFixtures.note(template: review)))
        #expect(custom.contains(#"template: "Sprint \"Review\"""#))
        // Mixdown only records by itself for calls.
        #expect(
            frontmatterLines(MarkdownNoteRenderer.render(NoteFixtures.note(trigger: .automatic))).contains("call: true")
        )
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
        #expect(lines.contains("trigger: manual"))
        #expect(lines.contains("tags: [mixdown]"))
        // Only diarized transcripts list speakers.
        #expect(!lines.contains { $0.hasPrefix("speakers:") })

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
        #expect(markdown.contains(#"# Say "hi" \\ now"#))
    }

    @Test(arguments: [("C# *draft* #", "# C# \\*draft\\* \\#"), ("##", "# \\##"), ("Foo#", "# Foo#")])
    func escapesTitleHeading(title: String, heading: String) {
        let markdown = MarkdownNoteRenderer.render(NoteFixtures.note(title: title))
        #expect(markdown.contains("\n\(heading)\n"))
        // The heading reads as the title, so the note window doesn't show it twice.
        let blocks = NoteDocument(url: URL(filePath: "/n.md"), contents: markdown, fileDate: .now).displayBlocks()
        #expect(!blocks.contains { $0 == .heading(level: 1, text: String(heading.dropFirst(2))) })
    }

    @Test func escapesMarkdownInTranscript() {
        let markdown = MarkdownNoteRenderer.render(
            NoteFixtures.note(segments: [
                TranscriptSegment(
                    start: 0,
                    end: 2,
                    text: #"A *star*, <details> & [link](x) `code` ~~gone~~ \ _"#,
                    speaker: "Bob_1*"
                )
            ])
        )
        #expect(
            markdown.contains(
                #"**[00:00:00] Bob\_1\*:** A \*star\*, \<details> \& \[link\](x) \`code\` \~\~gone\~\~ \\ \_"#
            )
        )
    }

    @Test func multilineTitleStaysOnOneLine() {
        let markdown = MarkdownNoteRenderer.render(NoteFixtures.note(title: "First\nSecond"))
        #expect(frontmatterLines(markdown).contains(#"title: "First Second""#))
        #expect(markdown.contains("\n# First Second\n"))
    }

    // MARK: - Summary

    @Test func summaryGoesBeforeTranscript() {
        let summary = NoteSummary(
            overview: "We planned\nthe *release*.",
            keyPoints: ["Ship on Friday", " "],
            actionItems: ["Anna writes the notes"]
        )
        let markdown = MarkdownNoteRenderer.render(NoteFixtures.note(summary: summary))

        let expected = """
            ## Summary

            We planned the \\*release\\*.

            ### Key Points

            - Ship on Friday

            ### Action Items

            - [ ] Anna writes the notes

            ## Transcript
            """
        #expect(markdown.contains(expected))
    }

    // MARK: - Moments

    @Test func momentsGoLastInTheSummary() {
        let markdown = MarkdownNoteRenderer.render(
            NoteFixtures.note(
                summary: NoteSummary(overview: "A sync."),
                moments: [
                    Moment(time: 2, text: "The *intro*"),
                    // Ten seconds after "Next topic." ended.
                    Moment(time: 80),
                ]
            )
        )

        let expected = """
            ## Summary

            A sync.

            ### Moments

            - **[00:00:02]** The \\*intro\\* — _“Hello everyone.”_
            - **[00:01:20]** _“Next topic.”_

            ## Transcript
            """
        #expect(markdown.contains(expected))
    }

    @Test func momentsWithoutSummaryGetASectionOfTheirOwn() {
        let markdown = MarkdownNoteRenderer.render(
            NoteFixtures.note(
                segments: [TranscriptSegment(start: 0, end: 4, text: "Hello.", speaker: "Others")],
                moments: [Moment(time: 1, text: "Greeting"), Moment(time: 30)]
            )
        )

        let expected = """
            # Weekly Sync

            ## Moments

            - **[00:00:01]** Greeting — _Others: “Hello.”_
            - **[00:00:30]** _Marked._

            ## Transcript
            """
        #expect(markdown.contains(expected))
        #expect(!MarkdownNoteRenderer.render(NoteFixtures.note()).contains("Moments"))
    }

    @Test func momentQuotesTheTranslationLikeTheSummary() {
        let translation = Transcript(
            segments: [TranscriptSegment(start: 0, end: 4, text: "Hallo zusammen.")],
            language: "de"
        )
        let markdown = MarkdownNoteRenderer.render(
            NoteFixtures.note(translation: translation, moments: [Moment(time: 1)])
        )
        #expect(markdown.contains("## Moments\n\n- **[00:00:01]** _“Hallo zusammen.”_\n\n## Translation"))
    }

    @Test func momentQuotesTheWordsSaidByThen() {
        let words = { (range: ClosedRange<Int>) in range.map { "w\($0)" }.joined(separator: " ") }
        let quote = { (time: TimeInterval) in
            let note = NoteFixtures.note(
                segments: [TranscriptSegment(start: 0, end: 30, text: words(1...60))],
                moments: [Moment(time: time)]
            )
            let markdown = MarkdownNoteRenderer.render(note)
            let prefix = "- **[\(MarkdownNoteRendererTests.timestamp(time))]** _“"
            return markdown.components(separatedBy: "\n").first { $0.hasPrefix(prefix) }
                .map { String($0.dropFirst(prefix.count).dropLast(2)) }
        }

        // Halfway through: the 20 words up to the 30th.
        #expect(quote(15) == "…" + words(11...30) + "…")
        // Early on: the first 20, rather than fewer.
        #expect(quote(1) == words(1...20) + "…")
        // Past the end: the last 20.
        #expect(quote(40) == "…" + words(41...60))
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
    }

    @Test func emptySummaryPartsAreLeftOut() {
        let markdown = MarkdownNoteRenderer.render(
            NoteFixtures.note(summary: NoteSummary(overview: "", keyPoints: ["Only point"]))
        )
        #expect(markdown.contains("## Summary\n\n### Key Points\n\n- Only point\n\n## Transcript"))
        #expect(!markdown.contains("Action Items"))

        let empty = MarkdownNoteRenderer.render(NoteFixtures.note(summary: NoteSummary(overview: " ")))
        #expect(!empty.contains("## Summary"))
        #expect(!MarkdownNoteRenderer.render(NoteFixtures.note()).contains("## Summary"))
    }

    @Test func templateSummaryHasFixedSections() {
        let summary = NoteSummary(
            template: .clientCall,
            title: "Onboarding",
            overview: "The client wants SSO.",
            keyPoints: ["Ignored outside General"],
            actionItems: ["Send the *quote*"],
            openQuestions: ["Which IdP?"]
        )
        let markdown = MarkdownNoteRenderer.render(NoteFixtures.note(summary: summary))

        let expected = """
            ## Summary

            ### TL;DR

            The client wants SSO.

            ### Decisions

            _None._

            ### Action Items

            - [ ] Send the \\*quote\\*

            ### Open Questions

            - Which IdP?

            ## Transcript
            """
        #expect(markdown.contains(expected))
        #expect(!markdown.contains("Ignored outside General"))
    }

    @Test func templateSummaryWithNothingInItsSectionsIsLeftOut() {
        let summary = NoteSummary(template: .standup, title: "Standup", decisions: [" "])
        #expect(!MarkdownNoteRenderer.render(NoteFixtures.note(summary: summary)).contains("## Summary"))
    }

    @Test func transcriptTextSkipsSummary() {
        let markdown = MarkdownNoteRenderer.render(
            NoteFixtures.note(summary: NoteSummary(overview: "Overview.", actionItems: ["Do it"]))
        )
        let document = NoteDocument(url: URL(fileURLWithPath: "/tmp/n.md"), contents: markdown, fileDate: .now)
        #expect(!document.transcriptText.contains("Overview."))
        #expect(document.transcriptText.contains("Hello everyone."))
        #expect(document.snippet == "Overview.")
    }

    // MARK: - Translation

    @Test func translationGoesBetweenSummaryAndTranscript() {
        let translation = Transcript(
            segments: [
                TranscriptSegment(start: 0, end: 4, text: "Hallo zusammen.", speaker: "Ich"),
                TranscriptSegment(start: 65, end: 70, text: " "),
            ],
            language: "de"
        )
        let markdown = MarkdownNoteRenderer.render(
            NoteFixtures.note(translation: translation, summary: NoteSummary(overview: "Begrüßung."))
        )

        #expect(
            markdown.contains(
                """
                ## Summary

                Begrüßung.

                ## Translation

                **[00:00:00] Ich:** Hallo zusammen.

                ## Transcript

                **[00:00:00]** Hello everyone.
                """
            )
        )
        #expect(frontmatterLines(markdown).contains("language: \"en\""))
        #expect(frontmatterLines(markdown).contains("translation_language: \"de\""))
    }

    @Test func noteWithoutTranslationHasNoTranslationSection() {
        let markdown = MarkdownNoteRenderer.render(NoteFixtures.note())
        #expect(!markdown.contains("## Translation"))
        #expect(!markdown.contains("translation_language"))
    }

    @Test func transcriptTextSkipsTranslation() {
        let translation = Transcript(segments: [TranscriptSegment(start: 0, end: 4, text: "Hallo.")], language: "de")
        let markdown = MarkdownNoteRenderer.render(NoteFixtures.note(translation: translation))
        let document = NoteDocument(url: URL(fileURLWithPath: "/tmp/n.md"), contents: markdown, fileDate: .now)
        #expect(!document.transcriptText.contains("Hallo."))
        #expect(document.transcriptText.contains("Hello everyone."))
    }

    // MARK: - Talk time

    @Test func talkTimelineGoesInFrontmatterAndItsOwnSection() {
        let markdown = MarkdownNoteRenderer.render(NoteFixtures.note(talkTimeline: NoteFixtures.talkTimeline))
        let lines = frontmatterLines(markdown)

        #expect(lines.contains(#"talk_labels: ["Me", "Others | Team"]"#))
        #expect(lines.contains("talk_microphone: [35, 0, 60]"))
        #expect(lines.contains("talk_system_audio: [12, 50, 0]"))
        #expect(
            markdown.hasSuffix(
                """
                ## Talk Time

                **Me** 61 % (1 min 36 s) · **Others | Team** 39 % (1 min 02 s)

                | Minute | Me | Others \\| Team |
                | --- | --- | --- |
                | 00:00:00 | ██████ 35 s | ██ 12 s |
                | 00:01:00 | – | ████████ 50 s |
                | 00:02:00 | ██████████ 60 s | – |

                """
            )
        )
        // After the transcript.
        #expect(markdown.range(of: "## Transcript")!.lowerBound < markdown.range(of: "## Talk Time")!.lowerBound)
    }

    @Test func noTalkTimeWithoutATimeline() {
        let markdown = MarkdownNoteRenderer.render(NoteFixtures.note())
        #expect(!markdown.contains("talk_"))
        #expect(!markdown.contains("## Talk Time"))
    }
}
