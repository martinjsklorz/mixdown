import Foundation
import MixdownCore
import Testing

@testable import MixdownNotes

struct NoteSummaryEditingTests {
    private let general = NoteSummary(
        template: .general,
        title: "Release",
        overview: "We talked about the release.",
        keyPoints: ["Beta is out"],
        actionItems: ["Ship it"]
    )
    private let standup = NoteSummary(
        template: .standup,
        title: "Standup",
        overview: "Short standup.",
        decisions: ["Freeze on Friday"],
        actionItems: ["Write *release* notes"],
        openQuestions: []
    )
    private let moments = [Moment(time: 2, text: "Check [this]"), Moment(time: 66)]

    private func rendered(summary: NoteSummary?, moments: [Moment] = [], translation: Transcript? = nil) -> String {
        MarkdownNoteRenderer.render(
            NoteFixtures.note(translation: translation, summary: summary, template: summary?.template, moments: moments)
        )
    }

    // MARK: - Replacing

    @Test func replacesTheSummaryAndTemplateLikeANewNote() {
        let contents = rendered(summary: general, moments: moments)
        #expect(
            NoteDocument.replacingSummary(in: contents, with: standup) == rendered(summary: standup, moments: moments)
        )
        // And back: the `template` field goes again.
        let standupNote = rendered(summary: standup, moments: moments)
        #expect(NoteDocument.replacingSummary(in: standupNote, with: general) == contents)
    }

    @Test func addsASummaryToANoteWithout() {
        #expect(NoteDocument.replacingSummary(in: rendered(summary: nil), with: general) == rendered(summary: general))
        #expect(
            NoteDocument.replacingSummary(in: rendered(summary: nil, moments: moments), with: standup)
                == rendered(summary: standup, moments: moments)
        )
        let translation = Transcript(
            segments: [TranscriptSegment(start: 0, end: 4, text: "Hallo zusammen.")],
            language: "de"
        )
        #expect(
            NoteDocument.replacingSummary(in: rendered(summary: nil, translation: translation), with: general)
                == rendered(summary: general, translation: translation)
        )
    }

    @Test func keepsMomentsAsTheyAreWritten() {
        let contents = rendered(summary: general, moments: moments)
            .replacingOccurrences(of: "Check \\[this\\]", with: "Check this, edited by hand")
        let replaced = NoteDocument.replacingSummary(in: contents, with: standup) ?? ""
        #expect(replaced.contains("### Moments\n\n- **[00:00:02]** Check this, edited by hand"))
    }

    @Test func leavesTheNoteAloneForAnEmptySummary() {
        #expect(NoteDocument.replacingSummary(in: rendered(summary: general), with: NoteSummary()) == nil)
    }

    // MARK: - Reading back

    @Test func readsBackTheTranscriptAndMoments() throws {
        let note = NoteFixtures.note(
            duration: 70,
            segments: [
                TranscriptSegment(start: 0, end: 4, text: "Use *stars* and [brackets] \\ here.", speaker: "Me"),
                TranscriptSegment(start: 5, end: 9, text: "Okay.", speaker: "Others (Speaker 2)"),
                TranscriptSegment(start: 65, end: 70, text: "Next topic."),
            ],
            summary: general,
            moments: moments
        )
        let source = try #require(NoteDocument.summarySource(of: MarkdownNoteRenderer.render(note)))
        #expect(
            source.transcript
                == Transcript(
                    segments: [
                        TranscriptSegment(start: 0, end: 5, text: "Use *stars* and [brackets] \\ here.", speaker: "Me"),
                        TranscriptSegment(start: 5, end: 65, text: "Okay.", speaker: "Others (Speaker 2)"),
                        TranscriptSegment(start: 65, end: 70, text: "Next topic."),
                    ],
                    language: "en"
                )
        )
        #expect(source.moments.map(\.time) == [2, 66])
        #expect(source.moments.map(\.text) == ["Check [this]", ""])
    }

    @Test func readsTheTranslationWhenThereIsOne() throws {
        let translation = Transcript(
            segments: [TranscriptSegment(start: 0, end: 4, text: "Hallo zusammen.")],
            language: "de"
        )
        let source = try #require(NoteDocument.summarySource(of: rendered(summary: nil, translation: translation)))
        #expect(source.transcript.text == "Hallo zusammen.")
        #expect(source.transcript.language == "de")
    }

    @Test func linesEditedByHandContinueTheLineBefore() throws {
        let contents = "# Note\n\n## Transcript\n\n**[00:00:01]** First\nwrapped by hand.\n\n**[00:00:09]** Second.\n"
        let source = try #require(NoteDocument.summarySource(of: contents))
        #expect(source.transcript.segments.map(\.text) == ["First wrapped by hand.", "Second."])
        #expect(source.transcript.segments.map(\.start) == [1, 9])
    }

    @Test func noTranscriptNoSource() {
        #expect(NoteDocument.summarySource(of: "# Note\n\nJust text.\n") == nil)
        #expect(NoteDocument.summarySource(of: "## Transcript\n\n_No speech detected._\n") == nil)
    }
}
