import Foundation
import MixdownCore
import MixdownNotes
import Testing

struct NoteSearchIndexTests {
    private let url = URL(filePath: "/notes/2026-10-13 1402 Weekly Sync.md")

    private func document(_ note: Note = NoteFixtures.note(), url: URL? = nil) -> NoteDocument {
        NoteDocument(url: url ?? self.url, contents: MarkdownNoteRenderer.render(note), fileDate: .distantPast)
    }

    private func document(contents: String, url: URL? = nil) -> NoteDocument {
        NoteDocument(url: url ?? self.url, contents: contents, fileDate: .distantPast)
    }

    // MARK: Items

    @Test func indexesNoteAndEachTranscriptLine() {
        let note = document(
            NoteFixtures.note(segments: [
                TranscriptSegment(start: 0, end: 4, text: "Hello everyone.", speaker: "Me"),
                TranscriptSegment(start: 754, end: 760, text: "Let's move the release timeline.", speaker: "Others"),
            ])
        )

        let items = NoteSearchIndex.items(for: note)

        #expect(items.map(\.id) == [url.absoluteString, url.absoluteString + "#0", url.absoluteString + "#1"])
        #expect(items[0].title == "Weekly Sync")
        #expect(items[0].description == note.snippet)
        #expect(items[0].text.contains("release timeline"))
        #expect(items[0].keywords == ["MacBook Pro Microphone"])
        #expect(items[2].title == "Others: Let's move the release timeline.")
        #expect(items[2].description == "Weekly Sync · 00:12:34")
        #expect(items[2].text == "Others: Let's move the release timeline.")
        #expect(items.allSatisfy { $0.date == NoteFixtures.createdAt })
    }

    @Test func linesSaySectionTheyAreIn() {
        let note = document(
            NoteFixtures.note(
                translation: Transcript(
                    segments: [TranscriptSegment(start: 1, end: 2, text: "Hallo.")],
                    language: "de"
                ),
                summary: NoteSummary(overview: "We planned the release.", actionItems: ["Anna writes the notes"])
            )
        )

        let descriptions = NoteSearchIndex.items(for: note).dropFirst().map { "\($0.title) | \($0.description)" }

        #expect(
            descriptions == [
                "We planned the release. | Weekly Sync · Summary",
                "Anna writes the notes | Weekly Sync · Action Items",
                "Hallo. | Weekly Sync · Translation · 00:00:01",
                "Hello everyone. | Weekly Sync · 00:00:00",
                "Next topic. | Weekly Sync · 00:01:05",
            ]
        )
    }

    @Test func linesPointAtDisplayedBlocks() {
        let note = document(
            contents: "# Weekly Sync\n\n## Notes\n\nFirst.\n\n---\n\n- Second\n\n```\nthird   line\n```"
        )

        let lines = NoteSearchIndex.lines(of: note)

        #expect(lines.map(\.text) == ["First.", "Second", "third line"])
        let blocks = note.displayBlocks()
        #expect(lines.map(\.block) == [1, 3, 4])
        #expect(blocks[1] == .paragraph("First."))
    }

    @Test func leavesOutPlaceholders() {
        let note = document(
            NoteFixtures.note(segments: [], summary: NoteSummary(template: .standup, overview: "Quick one."))
        )

        #expect(NoteSearchIndex.lines(of: note).map(\.text) == ["Quick one."])
    }

    @Test func handWrittenNoteWithoutSections() {
        let note = document(contents: "Just a thought about the release timeline.")

        let items = NoteSearchIndex.items(for: note)

        #expect(items.count == 2)
        #expect(items[1].title == "Just a thought about the release timeline.")
        #expect(items[1].description == note.title)
    }

    @Test func folderIsAKeyword() {
        var note = document()
        note.folder = "Clients/Acme"

        #expect(NoteSearchIndex.items(for: note).allSatisfy { $0.keywords.last == "Clients/Acme" })
    }

    // MARK: Identifiers

    @Test func findsNoteAndLineFromItemID() throws {
        let url = URL(filePath: "/notes/Clients #1/Plan 50% done.md")
        let items = NoteSearchIndex.items(for: document(url: url))

        let note = try #require(NoteSearchIndex.location(ofItemID: items[0].id))
        #expect(note.noteURL == url)
        #expect(note.line == nil)

        let line = try #require(NoteSearchIndex.location(ofItemID: items[2].id))
        #expect(line.noteURL == url)
        #expect(line.line == 1)

        #expect(NoteSearchIndex.location(ofItemID: "something-else") == nil)
        #expect(NoteSearchIndex.location(ofItemID: items[0].id + "#-1")?.line == nil)
    }

    // MARK: Updating

    @Test func firstUpdateIndexesEverything() {
        let notes = [document(), document(url: URL(filePath: "/notes/Other.md"))]

        let update = NoteSearchIndex.update(from: .init(), to: notes)

        #expect(update.items.count == 6)
        #expect(update.deletedIDs.isEmpty)
        #expect(!update.state.isEmpty)
    }

    @Test func unchangedNotesAreLeftAlone() {
        let notes = [document()]
        let state = NoteSearchIndex.update(from: .init(), to: notes).state

        let update = NoteSearchIndex.update(from: state, to: notes)

        #expect(update.isEmpty)
        #expect(update.state == state)
    }

    @Test func changedNoteIsIndexedAgainAndLosesLinesItNoLongerHas() {
        let state = NoteSearchIndex.update(from: .init(), to: [document()]).state
        let shorter = document(NoteFixtures.note(segments: [TranscriptSegment(start: 0, end: 1, text: "Only.")]))

        let update = NoteSearchIndex.update(from: state, to: [shorter])

        #expect(update.items.map(\.title) == ["Weekly Sync", "Only."])
        #expect(update.deletedIDs == [url.absoluteString + "#1"])
    }

    @Test func removedNoteIsDeleted() {
        let other = document(url: URL(filePath: "/notes/Other.md"))
        let state = NoteSearchIndex.update(from: .init(), to: [document(), other]).state

        let update = NoteSearchIndex.update(from: state, to: [other])

        #expect(update.items.isEmpty)
        #expect(
            Set(update.deletedIDs) == [url.absoluteString, url.absoluteString + "#0", url.absoluteString + "#1"]
        )
        #expect(update.state == NoteSearchIndex.update(from: .init(), to: [other]).state)
    }

    @Test func renamedNoteMovesToItsNewID() {
        let state = NoteSearchIndex.update(from: .init(), to: [document()]).state
        let renamed = URL(filePath: "/notes/2026-10-13 1402 Planning.md")

        let update = NoteSearchIndex.update(from: state, to: [document(url: renamed)])

        #expect(update.items.map(\.id).allSatisfy { $0.hasPrefix(renamed.absoluteString) })
        #expect(update.deletedIDs.count == 3)
    }

    @Test func stateSurvivesEncoding() throws {
        let state = NoteSearchIndex.update(from: .init(), to: [document()]).state

        let decoded = try JSONDecoder().decode(NoteSearchIndex.State.self, from: JSONEncoder().encode(state))

        #expect(decoded == state)
        #expect(NoteSearchIndex.update(from: decoded, to: [document()]).isEmpty)
    }
}
