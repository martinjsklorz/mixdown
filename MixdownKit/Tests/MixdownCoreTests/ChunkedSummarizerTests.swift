import Foundation
@testable import MixdownCore
import Testing

struct ChunkedSummarizerTests {
    /// Records each step and answers with a summary naming it, e.g. `transcript 1`.
    private final class StepRecorder: @unchecked Sendable {
        var steps: [(text: String, kind: ChunkedSummarizer.Step)] = []

        func step(_ text: String, _ kind: ChunkedSummarizer.Step) -> NoteSummary {
            steps.append((text, kind))
            let count = steps.filter { $0.kind == kind }.count
            return NoteSummary(overview: "\(kind) \(count)")
        }
    }

    /// One segment per text, all by `speaker`, or by `S1`, `S2`, … so each is its own turn.
    private func transcript(_ texts: [String], speaker: String? = nil) -> Transcript {
        Transcript(
            segments: texts.enumerated().map { index, text in
                TranscriptSegment(
                    start: Double(index),
                    end: Double(index + 1),
                    text: text,
                    speaker: speaker ?? "S\(index + 1)"
                )
            }
        )
    }

    /// Three turns that each fit in 30 tokens, but no two together.
    private let longTurns = (1...3).map { "Line \($0) " + String(repeating: "x", count: 50) }

    // MARK: - Lines

    @Test func linesJoinTurnsOfTheSameSpeaker() {
        let transcript = Transcript(segments: [
            TranscriptSegment(start: 0, end: 1, text: " Hello\nthere.", speaker: "Me"),
            TranscriptSegment(start: 1, end: 2, text: "How are you?", speaker: "Me"),
            TranscriptSegment(start: 2, end: 3, text: "  ", speaker: "Others"),
            TranscriptSegment(start: 3, end: 4, text: "Fine.", speaker: "Others"),
            TranscriptSegment(start: 4, end: 5, text: "Unlabeled."),
            TranscriptSegment(start: 5, end: 6, text: "Still unlabeled.", speaker: " "),
        ])

        #expect(
            ChunkedSummarizer.lines(of: transcript) == [
                "Me: Hello there. How are you?",
                "Others: Fine.",
                "Unlabeled. Still unlabeled.",
            ]
        )
    }

    // MARK: - Estimates and pieces

    @Test func estimatesCJKDenserThanLatin() {
        #expect(ChunkedSummarizer.estimatedTokens(in: "") == 0)
        #expect(ChunkedSummarizer.estimatedTokens(in: "abc") == 1)
        #expect(ChunkedSummarizer.estimatedTokens(in: "abcd") == 2)
        #expect(ChunkedSummarizer.estimatedTokens(in: "会議です") == 4)
        #expect(ChunkedSummarizer.estimatedTokens(in: "회의") == 2)
    }

    @Test func chunksPackLinesInOrderWithinTheLimit() {
        // 9 characters each, so 3 tokens; two lines plus a newline are 7.
        let lines = ["aaaaaaaaa", "bbbbbbbbb", "ccccccccc"]

        #expect(
            ChunkedSummarizer.chunks(of: lines, maxTokens: 7, separator: "\n") == ["aaaaaaaaa\nbbbbbbbbb", "ccccccccc"]
        )
        #expect(ChunkedSummarizer.chunks(of: lines, maxTokens: 100, separator: "\n") == [lines.joined(separator: "\n")])
        #expect(ChunkedSummarizer.chunks(of: [], maxTokens: 7, separator: "\n").isEmpty)
    }

    @Test func longLineIsSplitAtSpaces() {
        let pieces = ChunkedSummarizer.split("one two three four five", maxTokens: 3)

        #expect(pieces == ["one two", "three", "four five"])
        #expect(pieces.allSatisfy { ChunkedSummarizer.estimatedTokens(in: $0) <= 3 })
    }

    @Test func lineWithoutSpacesIsSplitAnywhere() {
        let pieces = ChunkedSummarizer.split("会議の要点をまとめる", maxTokens: 4)

        #expect(pieces == ["会議の要", "点をまと", "める"])
    }

    // MARK: - Passes

    @Test func shortTranscriptIsOneStep() async throws {
        let recorder = StepRecorder()
        let summary = try await ChunkedSummarizer(maxTokens: 1000).summarize(
            transcript(["Hello.", "Bye."], speaker: "Me"),
            step: { recorder.step($0, $1) }
        )

        #expect(summary == NoteSummary(overview: "transcript 1"))
        #expect(recorder.steps.map(\.text) == ["Me: Hello. Bye."])
        #expect(recorder.steps.map(\.kind) == [.transcript])
    }

    @Test func longTranscriptIsSummarizedInPiecesThenCombined() async throws {
        let recorder = StepRecorder()

        let summary = try await ChunkedSummarizer(maxTokens: 30).summarize(
            transcript(longTurns),
            step: { recorder.step($0, $1) }
        )

        #expect(summary == NoteSummary(overview: "combine 1"))
        #expect(recorder.steps.map(\.kind) == [.transcript, .transcript, .transcript, .combine])
        #expect(recorder.steps[0].text == "S1: \(longTurns[0])")
        #expect(
            recorder.steps[3].text
                == "Part 1 of 3:\ntranscript 1\n\nPart 2 of 3:\ntranscript 2\n\nPart 3 of 3:\ntranscript 3"
        )
    }

    @Test func emptyPartsAreLeftOutOfTheCombination() async throws {
        let combined = LockedValue<[String]>([])

        let summary = try await ChunkedSummarizer(maxTokens: 30).summarize(
            transcript(longTurns),
            step: { text, kind in
                if kind == .combine {
                    combined.update { $0.append(text) }
                    return NoteSummary(overview: "All")
                }
                // A title alone doesn't make a part worth combining.
                return text.hasPrefix("S2")
                    ? NoteSummary(title: "Second") : NoteSummary(keyPoints: [String(text.prefix(2))])
            }
        )

        #expect(summary == NoteSummary(overview: "All"))
        #expect(combined.current == ["Part 1 of 3:\nKey points:\n- S1\n\nPart 3 of 3:\nKey points:\n- S3"])
    }

    @Test func allEmptyPartsGiveAnEmptySummary() async throws {
        let summary = try await ChunkedSummarizer(maxTokens: 30).summarize(transcript(longTurns)) { _, _ in
            NoteSummary()
        }
        #expect(summary.isEmpty)
    }

    @Test func summariesThatDontShrinkGiveUp() async throws {
        let steps = LockedValue(0)

        await #expect(throws: SummarizationError.self) {
            try await ChunkedSummarizer(maxTokens: 30, maxCombinePasses: 2).summarize(transcript(longTurns)) {
                text,
                _ in
                steps.update { $0 += 1 }
                return NoteSummary(overview: text)
            }
        }
        #expect(steps.current < 50)
    }

    // MARK: - Summary text

    @Test func plainTextListsNonEmptyParts() {
        let summary = NoteSummary(
            title: "Release",
            overview: " Planning. ",
            keyPoints: ["Ship Friday", " "],
            actionItems: []
        )
        #expect(summary.plainText == "Planning.\n\nKey points:\n- Ship Friday")
        #expect(!summary.isEmpty)
        #expect(NoteSummary(title: " ", overview: "\n", keyPoints: [" "], actionItems: [""]).isEmpty)
        #expect(!NoteSummary(title: "Release").isEmpty)
    }

    @Test func plainTextIncludesFixedSections() {
        let summary = NoteSummary(
            template: .standup,
            overview: "Status.",
            decisions: ["Ship Friday"],
            actionItems: ["Anna fixes the build"],
            openQuestions: ["Who reviews?"]
        )
        #expect(
            summary.plainText
                == "Status.\n\nDecisions:\n- Ship Friday\n\nAction items:\n- Anna fixes the build"
                + "\n\nOpen questions:\n- Who reviews?"
        )
        #expect(!NoteSummary(template: .oneOnOne, openQuestions: ["Why?"]).isEmpty)
        #expect(NoteSummary(template: .oneOnOne, decisions: [" "], openQuestions: [""]).isEmpty)
    }
}
