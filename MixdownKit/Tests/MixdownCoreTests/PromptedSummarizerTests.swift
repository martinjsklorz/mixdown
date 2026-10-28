import Foundation
import Testing

@testable import MixdownCore

struct PromptedSummarizerTests {
    /// One segment per text, each by a speaker of its own, `S1`, `S2`, …, so each is its own turn.
    private func transcript(_ texts: [String], speakers: [String]? = nil) -> Transcript {
        Transcript(
            segments: texts.enumerated().map { index, text in
                TranscriptSegment(
                    start: Double(index),
                    end: Double(index + 1),
                    text: text,
                    speaker: speakers?[index % (speakers?.count ?? 1)] ?? "S\(index + 1)"
                )
            }
        )
    }

    /// Two turns of 38 tokens each, which fit together in 100.
    private let turns = (1...2).map { "Line \($0) " + String(repeating: "x", count: 103) }

    private let review = SummaryTemplate(
        id: "custom-1",
        name: "Review",
        instructions: "Look out for " + String(repeating: "demos ", count: 25)
    )

    // MARK: - Summaries

    @Test func pieceBudgetLeavesRoomForTheTemplatesInstructionsAndMoments() throws {
        let prompted = PromptedSummarizer(maxTokens: 100, minTokens: 10)
        let focus = try #require(SummaryPrompt.focus(of: review))
        let rule = try #require(SummaryPrompt.momentsRule(for: .transcript))
        #expect(prompted.pieceTokens(template: .general, hasMoments: false) == 100)
        #expect(
            prompted.pieceTokens(template: review, hasMoments: false)
                == 100 - ChunkedSummarizer.estimatedTokens(in: focus)
        )
        #expect(prompted.pieceTokens(template: review, hasMoments: true) == 10)
        #expect(ChunkedSummarizer.estimatedTokens(in: focus + rule) > 90)
    }

    @Test(arguments: [false, true]) func templateInstructionsMakePiecesSmaller(withTemplate: Bool) async throws {
        let requests = LockedValue<[SummaryRequest]>([])

        _ = try await PromptedSummarizer(maxTokens: 100).summarize(
            transcript(turns),
            moments: [],
            template: withTemplate ? review : .general,
            language: nil
        ) { request in
            requests.update { $0.append(request) }
            return NoteSummary(title: "Review", overview: "Part.")
        }

        let kinds = requests.current.map(\.kind)
        #expect(kinds == (withTemplate ? [.transcript, .transcript, .combine] : [.transcript]))
    }

    @Test func requestsHaveTheInstructionsAndTheSummaryItsTemplateAndLanguage() async throws {
        let requests = LockedValue<[SummaryRequest]>([])
        let moments = [Moment(time: 0.5, text: "Key")]

        let summary = try await PromptedSummarizer(maxTokens: 1000).summarize(
            transcript(["Hello."]),
            moments: moments,
            template: .standup,
            language: "de"
        ) { request in
            requests.update { $0.append(request) }
            // Backends may leave the template out; it's set from the one asked for.
            return NoteSummary(title: "Standup", overview: "Hallo.")
        }

        #expect(
            requests.current == [
                SummaryRequest(
                    instructions: SummaryPrompt.instructions(
                        for: .transcript,
                        template: .standup,
                        language: "de",
                        hasMoments: true
                    ),
                    prompt: "Transcript:\nS1: Hello.\n[Marked by the user: Key]",
                    kind: .transcript
                )
            ]
        )
        #expect(summary == NoteSummary(template: .standup, title: "Standup", overview: "Hallo.", language: "de"))
    }

    @Test func blankTitleIsAskedForWithTheLanguageSet() async throws {
        let asked = LockedValue<[NoteSummary]>([])

        let summary = try await PromptedSummarizer(maxTokens: 1000).summarize(
            transcript(["Hello."]),
            moments: [],
            template: .general,
            language: "de"
        ) { _ in
            NoteSummary(title: " ", overview: "Hallo.")
        } title: { summary in
            asked.update { $0.append(summary) }
            return "Begrüßung"
        }

        #expect(summary.title == "Begrüßung")
        #expect(asked.current.map(\.language) == ["de"])
    }

    @Test func titleIsNotAskedForWhenGivenOrWithNothingToTitle() async throws {
        let asked = LockedValue(0)
        for answer in [NoteSummary(title: "Greeting", overview: "Hello."), NoteSummary()] {
            let summary = try await PromptedSummarizer(maxTokens: 1000).summarize(
                transcript(["Hello."]),
                moments: [],
                template: .general,
                language: nil
            ) { _ in
                answer
            } title: { _ in
                asked.update { $0 += 1 }
                return "Other"
            }
            #expect(summary.title == answer.title)
        }
        #expect(asked.current == 0)
    }

    @Test func failingTitleLeavesItBlank() async throws {
        let summary = try await PromptedSummarizer(maxTokens: 1000).summarize(
            transcript(["Hello."]),
            moments: [],
            template: .general,
            language: nil
        ) { _ in
            NoteSummary(overview: "Hello.")
        } title: { _ in
            throw SummarizationError.failed("No title.")
        }
        #expect(summary.title == "")
        #expect(summary.overview == "Hello.")

        await #expect(throws: CancellationError.self) {
            try await PromptedSummarizer(maxTokens: 1000).summarize(
                transcript(["Hello."]),
                moments: [],
                template: .general,
                language: nil
            ) { _ in
                NoteSummary(overview: "Hello.")
            } title: { _ in
                throw CancellationError()
            }
        }
    }

    // MARK: - Catch-ups and speakers

    @Test func catchUpAsksForCatchUpsAndKeepsAtMostFourPoints() async throws {
        let requests = LockedValue<[SummaryRequest]>([])

        // Two pieces, whose points are merged when combining them fails.
        let points = try await PromptedSummarizer(maxTokens: 40).catchUp(on: transcript(turns), language: "fr") {
            request in
            requests.update { $0.append(request) }
            if request.kind == .combine { throw SummarizationError.failed("No catch-up.") }
            return request.prompt.contains("Line 1") ? ["a", "b", "c"] : ["d", "e"]
        }

        #expect(points == ["a", "b", "c", "d"])
        #expect(
            requests.current.first?.instructions == SummaryPrompt.catchUpInstructions(for: .transcript, language: "fr")
        )
    }

    @Test func nameSpeakersAsksWithTheNamingInstructions() async throws {
        let requests = LockedValue<[SummaryRequest]>([])

        let names = try await PromptedSummarizer(maxTokens: 1000).nameSpeakers(
            ["Speaker 1"],
            in: transcript(["I'm Anna.", "Hi Anna."], speakers: ["Speaker 1", "Speaker 2"])
        ) { request in
            requests.update { $0.append(request) }
            return ["Speaker 1": "Anna"]
        }

        #expect(names == ["Speaker 1": "Anna"])
        #expect(requests.current.map(\.instructions) == [SpeakerNaming.instructions])
        #expect(
            requests.current.map(\.prompt) == [
                SpeakerNaming.prompt(for: "Speaker 1: I'm Anna.\nSpeaker 2: Hi Anna.", speakers: ["Speaker 1"])
            ]
        )
    }

    @Test func unavailableModelEndsNamingSpeakersAtOnce() async throws {
        let steps = LockedValue(0)
        let lines = (1...3).map { "Line \($0) " + String(repeating: "x", count: 50) }

        await #expect(throws: SummarizationError.unavailable("No model.")) {
            try await SpeakerNaming.names(
                for: ["Speaker 1", "Speaker 2"],
                in: transcript(lines, speakers: ["Speaker 1", "Speaker 2"]),
                maxTokens: 30
            ) { _, _ in
                steps.update { $0 += 1 }
                throw SummarizationError.unavailable("No model.")
            }
        }
        #expect(steps.current == 1)
    }
}
