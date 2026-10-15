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
        #expect(document.source == "MacBook Pro Microphone")
        #expect(document.snippet == "[00:00:00] Hello everyone.")
        #expect(document.body.hasPrefix("\n# Weekly Sync\n\n## Transcript\n"))
        #expect(document.id == url)
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
        #expect(document.source == nil)
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
}
