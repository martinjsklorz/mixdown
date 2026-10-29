import MixdownCore
import Synchronization
import Testing

@testable import MixdownMLXLLM

struct MLXSummarizerTests {
    /// Answers with `answers` in turn, and counts the prompts.
    private final class ScriptedRuntime: LanguageModelResponding {
        private let answers: Mutex<[String]>
        private let prompts = Mutex(0)

        init(_ answers: [String]) {
            self.answers = Mutex(answers)
        }

        var promptCount: Int { prompts.withLock { $0 } }

        func respond(instructions: String, prompt: String, maximumTokens: Int) async throws -> String {
            prompts.withLock { $0 += 1 }
            return answers.withLock { $0.isEmpty ? "" : $0.removeFirst() }
        }

        func unload() async {}
    }

    private let transcript = Transcript(
        segments: [TranscriptSegment(start: 0, end: 30, text: "We agreed to move the launch to May.")],
        language: "en"
    )

    private func summarizer(_ runtime: ScriptedRuntime) -> MLXSummarizer {
        MLXSummarizer(model: .qwen3Small, runtime: runtime, isDownloaded: true)
    }

    private static let summary = """
        {"keyPoints": ["The launch moves to May."], "actionItems": [], \
        "overview": "The team planned the launch.", "title": "Launch planning"}
        """

    @Test func anAnswerWithoutJSONIsAskedForOnceMore() async throws {
        let runtime = ScriptedRuntime(["Sure! Here's a summary.", Self.summary])
        let summary = try await summarizer(runtime).summarize(transcript, moments: [], template: .general)
        #expect(summary.title == "Launch planning")
        #expect(summary.keyPoints == ["The launch moves to May."])
        #expect(runtime.promptCount == 2)
    }

    @Test func twoAnswersWithoutJSONFail() async throws {
        let runtime = ScriptedRuntime(["No JSON here.", "Still none."])
        await #expect(throws: SummarizationError.self) {
            try await summarizer(runtime).summarize(transcript, moments: [], template: .general)
        }
        #expect(runtime.promptCount == 2)
    }

    @Test func aSummaryWithoutATitleAsksForOne() async throws {
        let untitled = """
            {"keyPoints": ["The launch moves to May."], "actionItems": [], "overview": "The team planned the launch."}
            """
        let runtime = ScriptedRuntime([untitled, "Title: \"Launch in May\""])
        let summary = try await summarizer(runtime).summarize(transcript, moments: [], template: .general)
        #expect(summary.title == "Launch in May")
        #expect(runtime.promptCount == 2)
    }

    @Test func withoutTheModelOnDiskItsUnavailable() async throws {
        let summarizer = MLXSummarizer(model: .qwen3Small, runtime: ScriptedRuntime([]), isDownloaded: false)
        guard case .unavailable = summarizer.availability else {
            Issue.record("Expected the summarizer to be unavailable")
            return
        }
    }
}
