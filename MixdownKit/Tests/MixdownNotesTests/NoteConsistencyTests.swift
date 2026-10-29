import Foundation
import MixdownCore
import Testing

@testable import MixdownNotes

/// The copies a note keeps of a value, in its frontmatter and its body, stay in step as it's
/// edited, and what's worked out from a note follows its changes.
struct NoteConsistencyTests {
    private let url = URL(filePath: "/n/Note.md")

    private func document(_ contents: String) -> NoteDocument {
        NoteDocument(url: url, contents: contents, fileDate: .distantPast)
    }

    private func rendered(_ note: Note) -> String {
        MarkdownNoteRenderer.render(note)
    }

    private func speakerNote() -> Note {
        NoteFixtures.note(
            segments: [
                TranscriptSegment(start: 0, end: 4, text: "Hello.", speaker: "Martin Jan"),
                TranscriptSegment(start: 5, end: 8, text: "Hi.", speaker: "Anna"),
            ],
            talkTimeline: TalkTimeline(
                microphoneLabel: "Martin Jan",
                systemAudioLabel: "Anna",
                microphone: [3],
                systemAudio: [7]
            )
        )
    }

    // MARK: - Vocabulary and speakers

    @Test func vocabularyCorrectsSpeakersAlongWithTheirLabels() throws {
        let correction = NoteDocument.VocabularyCorrection(
            Vocabulary(entries: [.init(term: "Martin-Jan", soundsLike: ["Martin Jan"])])
        )

        let corrected = try #require(NoteDocument.corrected(rendered(speakerNote()), by: correction))

        #expect(corrected.contains("speakers: [\"Martin-Jan\", \"Anna\"]"))
        #expect(corrected.contains("talk_labels: [\"Martin-Jan\", \"Anna\"]"))
        #expect(corrected.contains("**[00:00:00] Martin-Jan:** Hello."))
        let note = document(corrected)
        #expect(note.speakers == ["Martin-Jan", "Anna"])
        #expect(note.talkTimeline?.microphoneLabel == "Martin-Jan")

        // Renaming the corrected speaker still finds their labels.
        let renamed = try #require(NoteDocument.renamingSpeaker(corrected, from: "Martin-Jan", to: "MJ"))
        #expect(renamed.contains("**[00:00:00] MJ:** Hello."))
        #expect(document(renamed).speakers == ["MJ", "Anna"])
    }

    @Test func vocabularyMergesSpeakersItMakesTheSame() throws {
        let correction = NoteDocument.VocabularyCorrection(
            Vocabulary(entries: [.init(term: "Anna", soundsLike: ["Martin Jan"])])
        )

        let corrected = try #require(NoteDocument.corrected(rendered(speakerNote()), by: correction))

        #expect(document(corrected).speakers == ["Anna"])
        // Talk Time keeps a label for each of its sides.
        #expect(corrected.contains("talk_labels: [\"Anna\", \"Anna\"]"))
    }

    @Test func vocabularyCorrectsATitleWrittenOverSeveralLines() throws {
        let correction = NoteDocument.VocabularyCorrection(
            Vocabulary(entries: [.init(term: "Kubernetes", soundsLike: ["cooper netties"])])
        )
        let contents = "---\ntitle: \"cooper netties\"\n  # a comment\ntags: [x]\n---\n# cooper netties\n"

        let corrected = try #require(NoteDocument.corrected(contents, by: correction))

        #expect(corrected == "---\ntitle: \"Kubernetes\"\ntags: [x]\n---\n# Kubernetes\n")
        #expect(document(corrected).displayBlocks().isEmpty)
    }

    @Test func renamingADistinctiveSpeakerLeavesTheTitleHeadingAsTheTitleIs() throws {
        let note = NoteFixtures.note(
            title: "Call with Speaker 2",
            segments: [TranscriptSegment(start: 0, end: 4, text: "Hello.", speaker: "Speaker 2")]
        )

        let renamed = try #require(NoteDocument.renamingSpeaker(rendered(note), from: "Speaker 2", to: "Anna"))

        #expect(renamed.contains("# Call with Speaker 2\n"))
        #expect(renamed.contains("**[00:00:00] Anna:** Hello."))
        let document = document(renamed)
        #expect(document.title == "Call with Speaker 2")
        #expect(document.displayBlocks().first != .heading(level: 1, text: "Call with Speaker 2"))
    }

    // MARK: - Whitespace

    @Test func titleWithRunsOfWhitespaceIsShownOnce() {
        let contents = rendered(NoteFixtures.note(title: "A  B\tC"))

        #expect(contents.contains("title: \"A B C\""))
        let note = document(contents)
        #expect(note.title == "A B C")
        #expect(note.displayBlocks().first == .heading(level: 2, text: "Transcript"))
    }

    @Test func titleHeadingMatchesATitleWithRunsOfSpacesWrittenByHand() {
        let note = document("---\ntitle: \"Weekly  Sync\"\n---\n# Weekly  Sync\n\nText")
        #expect(note.displayBlocks() == [.paragraph("Text")])
    }

    // MARK: - Duplicate frontmatter keys

    @Test func duplicateKeysReadTheFirstLikeEditsChangeIt() {
        let contents = "---\ntitle: \"First\"\npinned: true\ntitle: \"Second\"\npinned: true\n---\nText"
        #expect(document(contents).title == "First")

        let unpinned = NoteDocument.pinned(contents, false)
        #expect(unpinned == "---\ntitle: \"First\"\ntitle: \"Second\"\n---\nText")
        #expect(!document(unpinned).isPinned)
        #expect(
            NoteDocument.pinned(contents, true) == "---\ntitle: \"First\"\npinned: true\ntitle: \"Second\"\n---\nText"
        )

        let renamed = NoteDocument.retitled(contents, url: url, to: "Renamed")
        #expect(document(renamed).title == "Renamed")
    }

    // MARK: - Kept values

    @Test func fingerprintFollowsEveryFieldItIsMadeFrom() {
        let base = document(rendered(NoteFixtures.note(talkTimeline: NoteFixtures.talkTimeline)))
        let fingerprint = NoteSearchIndex.fingerprint(of: base)
        let changes: [(String, (inout NoteDocument) -> Void)] = [
            ("url", { $0.url = URL(filePath: "/n/Other.md") }),
            ("title", { $0.title = "Other" }),
            ("createdAt", { $0.createdAt += 1 }),
            ("sources", { $0.sources = ["Other"] }),
            ("body", { $0.body += "\nMore." }),
            ("folder", { $0.folder = "Other" }),
            ("talkTimeline", { $0.talkTimeline = nil }),
        ]
        for (field, change) in changes {
            var changed = base
            change(&changed)
            #expect(NoteSearchIndex.fingerprint(of: changed) != fingerprint, "\(field)")
            // The copy it was made from keeps its own.
            #expect(NoteSearchIndex.fingerprint(of: base) == fingerprint, "\(field)")
        }
    }

    @Test func linesFollowTheTalkTimeline() {
        var note = document(rendered(NoteFixtures.note(talkTimeline: NoteFixtures.talkTimeline)))
        let talkTime = MarkdownBlock.heading(level: 2, text: MarkdownNoteRenderer.talkTimeHeading)
        #expect(!note.displayBlocks().contains(talkTime))
        #expect(!NoteSearchIndex.lines(of: note).contains { $0.section == MarkdownNoteRenderer.talkTimeHeading })

        note.talkTimeline = nil

        #expect(note.displayBlocks().contains(talkTime))
        #expect(NoteSearchIndex.lines(of: note).contains { $0.section == MarkdownNoteRenderer.talkTimeHeading })
    }
}
