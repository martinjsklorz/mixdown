import Foundation
import MixdownCore
import Testing

@testable import MixdownNotes

/// What searching and counting read of a note: its text as shown, not the Markdown it's written
/// in, and what the renderer writes reads back as text.
struct NoteTextTests {
    private func document(_ note: Note, name: String = "Note") -> NoteDocument {
        NoteDocument(
            url: URL(filePath: "/n/\(name).md"),
            contents: MarkdownNoteRenderer.render(note),
            fileDate: .distantPast
        )
    }

    // MARK: - Search

    @Test func searchFindsTextTheRendererEscapes() throws {
        let note = document(
            NoteFixtures.note(segments: [
                TranscriptSegment(start: 0, end: 4, text: "Hello."),
                TranscriptSegment(start: 5, end: 9, text: "R&D renamed it to snake_case."),
            ])
        )
        #expect(note.body.contains("R\\&D"))

        for query in ["R&D", "snake_case", "\"R&D renamed\""] {
            #expect(
                try NoteLibrary.search([note], for: query) == [note.id: "R&D renamed it to snake_case."],
                "\(query)"
            )
        }
    }

    @Test func searchDoesNotFindMarkupEveryNoteHas() throws {
        let note = document(NoteFixtures.note())
        #expect(try NoteLibrary.search([note], for: "Transcript").isEmpty)
        #expect(try NoteLibrary.search([note], for: "00:00").isEmpty)
    }

    @Test func searchGivesTheSameExcerptsEveryTime() throws {
        let notes = (0..<20).map { number in
            document(
                NoteFixtures.note(
                    title: "Note \(number)",
                    segments: [TranscriptSegment(start: 0, end: 4, text: "Number \(number) of the notes.")]
                ),
                name: "\(number)"
            )
        }

        let first = try NoteLibrary.search(notes, for: "the notes")
        // A copy of a note keeps what was worked out for it.
        let second = try NoteLibrary.search(notes.map { $0 }, for: "the notes")

        #expect(first.count == notes.count)
        #expect(first == second)
        #expect(first[notes[3].id] == "Number 3 of the notes.")
    }

    // MARK: - Counting

    @Test func countingLeavesOutHeadingsAndPlaceholders() {
        let empty = document(
            NoteFixtures.note(summary: NoteSummary(template: .oneOnOne, overview: "We met.")),
            name: "Empty"
        )
        let decided = document(
            NoteFixtures.note(summary: NoteSummary(template: .oneOnOne, overview: "We met.", decisions: ["Ship it."])),
            name: "Decided"
        )
        let mentioned = document(
            NoteFixtures.note(
                segments: [TranscriptSegment(start: 10, end: 14, text: "We need more decisions.")],
                // Before anything was said.
                moments: [Moment(time: 1, text: "")]
            ),
            name: "Mentioned"
        )
        #expect(empty.body.contains("### Decisions"))
        #expect(mentioned.body.contains("_Marked._"))

        let decisions = NoteQuestion.parse("How many notes mentioned decisions?")
        #expect([empty, decided, mentioned].filter(decisions.counts).map(\.id) == [mentioned.id])
        let marked = NoteQuestion.parse("How many notes mentioned marked?")
        #expect([empty, decided, mentioned].filter(marked.counts).isEmpty)
        let topics = NoteQuestion.parse("How many notes mentioned ship?")
        #expect([empty, decided, mentioned].filter(topics.counts).map(\.id) == [decided.id])
    }

    // MARK: - Writing

    @Test(arguments: ["- a - b", "# Plan", "1. Ship", "2) Test", "> Note", "+ More", "---"])
    func overviewReadsBackAsAParagraph(_ overview: String) {
        let note = document(NoteFixtures.note(summary: NoteSummary(overview: overview, keyPoints: [overview])))
        let summary = note.displayBlocks().drop { $0 != .heading(level: 2, text: "Summary") }.dropFirst()

        #expect(summary.first.map { MarkdownBlock.plainText(paragraphText($0) ?? "") } == overview)
        // A key point stays a single item with the text.
        let point = summary.first { if case .listItem = $0 { true } else { false } }
        #expect(point.map { MarkdownBlock.plainText(listItemText($0) ?? "") } == overview)
    }

    private func paragraphText(_ block: MarkdownBlock) -> String? {
        if case .paragraph(let text) = block { text } else { nil }
    }

    private func listItemText(_ block: MarkdownBlock) -> String? {
        if case .listItem(_, 0, let text) = block { text } else { nil }
    }

    @Test func escapedLineStartLeavesOtherTextAsEscapedMarkdown() {
        #expect(MarkdownNoteRenderer.escapedLineStart("Plan for Q3") == "Plan for Q3")
        #expect(MarkdownNoteRenderer.escapedLineStart("2026 plans") == "2026 plans")
        #expect(MarkdownNoteRenderer.escapedLineStart("#tag & more") == "\\#tag \\& more")
        #expect(MarkdownNoteRenderer.escapedLineStart("10. Ten") == "10\\. Ten")
    }
}
