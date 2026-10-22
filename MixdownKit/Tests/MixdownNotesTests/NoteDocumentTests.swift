import Foundation
import MixdownCore
import MixdownNotes
import Testing

struct NoteDocumentTests {
    private let url = URL(filePath: "/notes/2026-10-13 1402 File Name.md")
    private let fileDate = Date(timeIntervalSince1970: 1_000)

    @Test func readsBackRenderedNote() {
        let note = NoteFixtures.note()

        let document = NoteDocument(url: url, contents: MarkdownNoteRenderer.render(note), fileDate: fileDate)

        #expect(document.title == "Weekly Sync")
        #expect(document.createdAt == note.createdAt)
        #expect(document.duration == 65)
        #expect(document.sources == ["MacBook Pro Microphone"])
        #expect(document.trigger == .manual)
        #expect(document.snippet == "[00:00:00] Hello everyone.")
        #expect(document.body.hasPrefix("\n# Weekly Sync\n\n## Transcript\n"))
        #expect(document.id == url)
    }

    @Test func readsBackTrigger() {
        let note = NoteFixtures.note(trigger: .automatic)
        let automatic = NoteDocument(url: url, contents: MarkdownNoteRenderer.render(note), fileDate: fileDate)
        #expect(automatic.trigger == .automatic)

        let quoted = NoteDocument(url: url, contents: "---\ntrigger: \"manual\"\n---\n", fileDate: fileDate)
        #expect(quoted.trigger == .manual)

        let unknown = NoteDocument(url: url, contents: "---\ntrigger: scheduled\n---\n", fileDate: fileDate)
        #expect(unknown.trigger == nil)
    }

    @Test func readsBackKindOfRecording() {
        let rendered = MarkdownNoteRenderer.render(NoteFixtures.note(isCall: true, template: .standup))
        let document = NoteDocument(url: url, contents: rendered, fileDate: fileDate)
        #expect(document.isCall)
        #expect(document.template == "standup")

        let review = SummaryTemplate(id: "custom-1", name: "Sprint Review")
        let custom = NoteDocument(
            url: url,
            contents: MarkdownNoteRenderer.render(NoteFixtures.note(template: review)),
            fileDate: fileDate
        )
        #expect(custom.template == "Sprint Review")
        #expect(!custom.isCall)

        let memo = NoteDocument(
            url: url,
            contents: MarkdownNoteRenderer.render(NoteFixtures.note()),
            fileDate: fileDate
        )
        #expect(!memo.isCall)
        #expect(memo.template == nil)

        // From before Mixdown wrote `call`.
        let titled = NoteDocument(url: url, contents: "---\ntitle: \"Anruf zu Budget\"\n---\n", fileDate: fileDate)
        #expect(titled.isCall)
        let untitled = NoteDocument(url: url, contents: "---\ntitle: \"Call about\"\n---\n", fileDate: fileDate)
        #expect(!untitled.isCall)
    }

    @Test func readsPinned() {
        let note = NoteFixtures.note()
        #expect(!NoteDocument(url: url, contents: MarkdownNoteRenderer.render(note), fileDate: fileDate).isPinned)

        for (value, isPinned) in [("true", true), ("True", true), ("\"true\"", true), ("false", false), ("1", false)] {
            let document = NoteDocument(url: url, contents: "---\npinned: \(value)\n---\n", fileDate: fileDate)
            #expect(document.isPinned == isPinned, "pinned: \(value)")
        }
    }

    @Test func displayBlocksDropLeadingTitleHeading() {
        let note = NoteFixtures.note()

        let document = NoteDocument(url: url, contents: MarkdownNoteRenderer.render(note), fileDate: fileDate)

        #expect(document.displayBlocks().first == .heading(level: 2, text: "Transcript"))
    }

    @Test func displayBlocksKeepHeadingThatDiffersFromTitle() {
        let contents = "---\ntitle: Renamed\n---\n# Original\n\nBody text."

        let document = NoteDocument(url: url, contents: contents, fileDate: fileDate)

        #expect(document.displayBlocks() == [.heading(level: 1, text: "Original"), .paragraph("Body text.")])
    }

    @Test func readsBackMultipleSources() {
        let note = NoteFixtures.note(sources: [
            AudioInputDevice(id: "builtin", name: "MacBook Pro Microphone", kind: .microphone),
            AudioInputDevice(id: "usb", name: #"Mic "B", 2"#, kind: .microphone),
            .systemAudio,
        ])

        let document = NoteDocument(url: url, contents: MarkdownNoteRenderer.render(note), fileDate: fileDate)

        #expect(document.sources == ["MacBook Pro Microphone", #"Mic "B", 2"#, "System Audio"])
    }

    @Test func readsHandWrittenSourceLists() {
        let contents = "---\nsources: [Plain, 'It''s quoted', \"\", \"Last\"] # comment\n---\n"

        let document = NoteDocument(url: url, contents: contents, fileDate: fileDate)

        #expect(document.sources == ["Plain", "It's quoted", "Last"])
    }

    @Test(arguments: ["inf", "-inf", ".inf", "nan", "1e30", "-5"])
    func ignoresUnusableDuration(_ value: String) {
        let document = NoteDocument(url: url, contents: "---\nduration: \(value)\n---\n", fileDate: fileDate)

        #expect(document.duration == nil)
    }

    @Test func unescapesQuotedFrontmatter() {
        let note = NoteFixtures.note(title: #"Say "hi" \ wave"#)

        let document = NoteDocument(url: url, contents: MarkdownNoteRenderer.render(note), fileDate: fileDate)

        #expect(document.title == #"Say "hi" \ wave"#)
    }

    @Test func emptyTranscriptHasPlaceholderSnippet() {
        let note = NoteFixtures.note(segments: [])

        let document = NoteDocument(url: url, contents: MarkdownNoteRenderer.render(note), fileDate: fileDate)

        #expect(document.snippet == "No speech detected.")
    }

    @Test func withoutFrontmatterFallsBackToHeadingAndFileDate() {
        let contents = "Intro line\n\n# Hand *Written*\n\nBody text."

        let document = NoteDocument(url: url, contents: contents, fileDate: fileDate)

        #expect(document.title == "Hand Written")
        #expect(document.createdAt == fileDate)
        #expect(document.duration == nil)
        #expect(document.sources.isEmpty)
        #expect(document.trigger == nil)
        #expect(document.snippet == "Intro line")
        #expect(document.body == contents)
    }

    @Test func withoutTitleOrHeadingFallsBackToFileName() {
        let document = NoteDocument(url: url, contents: "---\ntags: [x]\n---\n## Only H2\n", fileDate: fileDate)

        #expect(document.title == "2026-10-13 1402 File Name")
        #expect(document.snippet.isEmpty)
    }

    @Test func toleratesOtherFrontmatterStyles() {
        let contents = """
            \u{FEFF}---\r
            title: 'It''s plain' # comment\r
            created: 2026-10-13\r
            duration: 12.5\r
              nested: ignored\r
            # comment: ignored\r
            ...\r
            Text
            """

        let document = NoteDocument(url: url, contents: contents, fileDate: fileDate)

        #expect(document.title == "It's plain")
        #expect(document.duration == 12.5)
        #expect(
            document.createdAt
                == Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 13))
        )
        #expect(document.body == "Text")
    }

    @Test func unterminatedFrontmatterIsBody() {
        let contents = "---\ntitle: Nope\n\nText"

        let document = NoteDocument(url: url, contents: contents, fileDate: fileDate)

        #expect(document.title == "2026-10-13 1402 File Name")
        #expect(document.body == contents)
    }

    @Test func snippetIsCapped() {
        let document = NoteDocument(url: url, contents: String(repeating: "word ", count: 100), fileDate: fileDate)

        #expect(document.snippet.count == 200)
    }

    @Test func transcriptTextIsTranscriptSectionAsPlainText() {
        let contents = MarkdownNoteRenderer.render(NoteFixtures.note()) + "\n## Summary\n\nLater."

        let document = NoteDocument(url: url, contents: contents, fileDate: fileDate)

        #expect(document.transcriptText == "[00:00:00] Hello everyone.\n\n[00:01:05] Next topic.")
    }

    @Test func transcriptTextWithoutTranscriptSectionIsWholeBody() {
        let contents = "# Title\n\nSome **bold** text.\n\n- One\n  - Two\n1. Three\n\n---\n\n```\ncode  here\n```"

        let document = NoteDocument(url: url, contents: contents, fileDate: fileDate)

        #expect(document.transcriptText == "Title\n\nSome bold text.\n\n• One\n  • Two\n1. Three\n\ncode  here")
    }

    // MARK: - Talk time

    @Test func readsBackTalkTimelineAndLeavesItsSectionToTheChart() throws {
        let note = NoteFixtures.note(talkTimeline: NoteFixtures.talkTimeline)
        let document = NoteDocument(url: url, contents: MarkdownNoteRenderer.render(note), fileDate: fileDate)

        let timeline = try #require(document.talkTimeline)
        #expect(timeline.microphoneLabel == "Me")
        #expect(timeline.systemAudioLabel == "Others | Team")
        #expect(timeline.microphone == [35, 0, 60])
        #expect(timeline.systemAudio == [12, 50, 0])

        let headings = document.displayBlocks().compactMap { block -> String? in
            guard case .heading(_, let text) = block else { return nil }
            return text
        }
        #expect(headings == ["Transcript"])
        #expect(!document.transcriptText.contains("Minute"))
    }

    @Test func keepsTalkTimeSectionWithoutUsableTimeline() {
        let body = "\n## Talk Time\n\n| Minute | Me | Others |\n"
        for frontmatter in [
            "", "talk_microphone: [10, 20]", "talk_microphone: [10, x]\ntalk_system_audio: [1, 2]",
            "talk_microphone: [10, 61]\ntalk_system_audio: [1, 2]", "talk_microphone: []\ntalk_system_audio: []",
        ] {
            let document = NoteDocument(url: url, contents: "---\n\(frontmatter)\n---\n\(body)", fileDate: fileDate)
            #expect(document.talkTimeline == nil)
            #expect(document.displayBlocks().first == .heading(level: 2, text: "Talk Time"))
        }
    }

    @Test func fallsBackToDefaultTalkLabels() {
        let contents = "---\ntalk_microphone: [10]\ntalk_system_audio: [5, 6]\n---\n"
        let timeline = NoteDocument(url: url, contents: contents, fileDate: fileDate).talkTimeline
        #expect(timeline?.microphoneLabel == "Me")
        #expect(timeline?.systemAudioLabel == "Others")
        #expect(timeline?.microphone == [10, 0])
    }
}
