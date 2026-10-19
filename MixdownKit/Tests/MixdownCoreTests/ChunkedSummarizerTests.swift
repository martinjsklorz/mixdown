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

    /// A third of a token per ASCII letter, two thirds per Cyrillic letter, a whole one per CJK
    /// character or Thai or Devanagari scalar, even where several make one character.
    @Test(arguments: [
        ("", 0), ("abc", 1), ("abcd", 2), ("会議です", 4), ("회의", 2), ("привет", 4), ("สวัสดี", 6),
        ("नमस्ते", 6),
    ])
    func estimatesTokensFromUTF8Bytes(_ text: String, _ tokens: Int) {
        #expect(ChunkedSummarizer.estimatedTokens(in: text) == tokens)
    }

    @Test func groupsPackLinesInOrderWithinTheLimit() {
        // 9 characters each, so 3 tokens; two lines plus a newline are 7.
        let lines = ["aaaaaaaaa", "bbbbbbbbb", "ccccccccc"]

        #expect(
            ChunkedSummarizer.groups(of: lines, maxTokens: 7, separator: "\n") == [
                ["aaaaaaaaa", "bbbbbbbbb"], ["ccccccccc"],
            ]
        )
        #expect(ChunkedSummarizer.groups(of: lines, maxTokens: 100, separator: "\n") == [lines])
        #expect(ChunkedSummarizer.groups(of: [], maxTokens: 7, separator: "\n").isEmpty)
    }

    @Test func longLineIsSplitAtSpaces() {
        let pieces = ChunkedSummarizer.split("one two three four five", maxTokens: 3)

        #expect(pieces == ["one two", "three", "four five"])
        #expect(pieces.allSatisfy { ChunkedSummarizer.estimatedTokens(in: $0) <= 3 })
        #expect(ChunkedSummarizer.split("привет мир", maxTokens: 4) == ["привет", "мир"])
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

    @Test func negativeCombinePassesStillSummarize() async throws {
        let recorder = StepRecorder()
        let summary = try await ChunkedSummarizer(maxTokens: 1000, maxCombinePasses: -1).summarize(
            transcript(["Hello."]),
            step: { recorder.step($0, $1) }
        )
        #expect(summary == NoteSummary(overview: "transcript 1"))
    }

    // MARK: - Failures

    private struct StepFailure: Error {}

    @Test func failedPieceIsLeftOut() async throws {
        let combined = LockedValue<[String]>([])

        let summary = try await ChunkedSummarizer(maxTokens: 30).summarize(transcript(longTurns)) { text, kind in
            if kind == .combine {
                combined.update { $0.append(text) }
                return NoteSummary(overview: "All")
            }
            if text.hasPrefix("S2") { throw StepFailure() }
            return NoteSummary(overview: String(text.prefix(2)))
        }

        #expect(summary == NoteSummary(overview: "All"))
        #expect(combined.current == ["Part 1 of 3:\nS1\n\nPart 3 of 3:\nS3"])
    }

    @Test func allPiecesFailingThrows() async throws {
        await #expect(throws: StepFailure.self) {
            try await ChunkedSummarizer(maxTokens: 30).summarize(transcript(longTurns)) { _, _ in
                throw StepFailure()
            }
        }
    }

    @Test func cancellationIsNotTakenForAFailedPiece() async throws {
        let steps = LockedValue(0)

        await #expect(throws: CancellationError.self) {
            try await ChunkedSummarizer(maxTokens: 30).summarize(transcript(longTurns)) { text, _ in
                steps.update { $0 += 1 }
                if text.hasPrefix("S2") { throw CancellationError() }
                return NoteSummary(overview: "Part")
            }
        }
        #expect(steps.current == 2)
    }

    /// Six turns of 11 tokens each, which pack two to a piece of at most 25 tokens.
    private let shortTurns = (1...6).map { "Line \($0) " + String(repeating: "x", count: 20) }

    @Test func tooLongPieceIsSplitWithoutRedoingTheOthers() async throws {
        let recorder = StepRecorder()

        let summary = try await ChunkedSummarizer(maxTokens: 25).summarize(transcript(shortTurns)) { text, kind in
            // The piece with S3 and S4 only fits one turn at a time.
            if kind == .transcript, text.contains("S3:"), text.contains("\n") {
                throw SummarizationError.tooLong
            }
            return recorder.step(text, kind)
        }

        // Two parts fit in a piece, so the four are combined in two, then those two in one.
        #expect(summary == NoteSummary(overview: "combine 3"))
        let turns = shortTurns.enumerated().map { "S\($0 + 1): \($1)" }
        #expect(
            recorder.steps.filter { $0.kind == .transcript }.map(\.text) == [
                turns[0] + "\n" + turns[1], turns[2], turns[3], turns[4] + "\n" + turns[5],
            ]
        )
        #expect(
            recorder.steps.filter { $0.kind == .combine }.prefix(2).map(\.text) == [
                "Part 1 of 4:\ntranscript 1\n\nPart 2 of 4:\ntranscript 2",
                "Part 3 of 4:\ntranscript 3\n\nPart 4 of 4:\ntranscript 4",
            ]
        )
    }

    @Test func pieceTooLongAtTheMinimumIsLeftOut() async throws {
        let combined = LockedValue<[String]>([])

        let summary = try await ChunkedSummarizer(maxTokens: 25, minTokens: 20).summarize(transcript(shortTurns)) {
            text,
            kind in
            if kind == .combine {
                combined.update { $0.append(text) }
                return NoteSummary(overview: "All")
            }
            if text.contains("S3:") { throw SummarizationError.tooLong }
            return NoteSummary(overview: String(text.prefix(2)))
        }

        #expect(summary == NoteSummary(overview: "All"))
        #expect(combined.current == ["Part 1 of 3:\nS1\n\nPart 3 of 3:\nS5"])
    }

    @Test func singlePieceTooLongIsSummarizedInHalves() async throws {
        let recorder = StepRecorder()

        let summary = try await ChunkedSummarizer(maxTokens: 1000).summarize(transcript(["One.", "Two."])) {
            text,
            kind in
            if kind == .transcript, text.contains("\n") { throw SummarizationError.tooLong }
            return recorder.step(text, kind)
        }

        #expect(summary == NoteSummary(overview: "combine 1"))
        #expect(recorder.steps.map(\.text) == ["S1: One.", "S2: Two.", "Part 1 of 2:\ntranscript 1\n\nPart 2 of 2:\ntranscript 2"])
    }

    @Test func singlePieceTooLongToSplitThrows() async throws {
        await #expect(throws: SummarizationError.tooLong) {
            try await ChunkedSummarizer(maxTokens: 1000, minTokens: 100).summarize(transcript(["One.", "Two."])) {
                _,
                _ in
                throw SummarizationError.tooLong
            }
        }
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
