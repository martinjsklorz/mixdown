import Foundation
import Testing

@testable import MixdownCore

struct CatchUpTests {
    /// A summarizer without a catch-up of its own.
    private struct SummaryOnly: Summarizer {
        let info = SummarizerInfo(id: "summary-only", displayName: "Summary Only")
        let availability = SummarizerAvailability.available
        let summary: NoteSummary

        func summarize(_ transcript: Transcript, template: SummaryTemplate) async throws -> NoteSummary {
            summary
        }
    }

    private let transcript = Transcript(segments: [TranscriptSegment(start: 0, end: 1, text: "Hello.")])

    @Test func defaultCatchUpIsTheSummarysKeyPoints() async throws {
        let summarizer = SummaryOnly(summary: NoteSummary(overview: "A greeting.", keyPoints: ["Hello.", " "]))
        #expect(try await summarizer.catchUp(on: transcript, language: "de") == ["Hello."])
    }

    @Test func defaultCatchUpFallsBackOnTheOverview() async throws {
        let summarizer = SummaryOnly(summary: NoteSummary(overview: " A greeting. "))
        #expect(try await summarizer.catchUp(on: transcript, language: nil) == ["A greeting."])
        #expect(try await SummaryOnly(summary: NoteSummary()).catchUp(on: transcript, language: nil).isEmpty)
    }
}
