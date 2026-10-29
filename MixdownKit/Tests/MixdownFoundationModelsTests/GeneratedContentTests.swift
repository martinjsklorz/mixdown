import MixdownCore
import Testing

@testable import MixdownFoundationModels

struct GeneratedContentTests {
    @Test func speakerNamesKeepTheFirstAnswerForALabel() {
        let names = GeneratedSpeakerNames(speakers: [
            GeneratedSpeakerName(label: "Speaker 1", name: "Anna"),
            GeneratedSpeakerName(label: "Speaker 2", name: "Ben"),
            GeneratedSpeakerName(label: "Speaker 1", name: "Clara"),
        ])
        #expect(names.guesses == ["Speaker 1": "Anna", "Speaker 2": "Ben"])
    }

    @Test func summariesAreTrimmedIntoNoteSummaries() {
        let summary = GeneratedSummary(
            keyPoints: ["  Ship on Friday  "],
            actionItems: ["- Anna writes the notes"],
            overview: "  The release.\n",
            title: " Release timeline "
        )
        .noteSummary(template: .general)
        #expect(summary.title == "Release timeline")
        #expect(summary.overview == "The release.")
        #expect(summary.keyPoints == [SummaryPrompt.listItem("  Ship on Friday  ")])
        #expect(summary.actionItems == [SummaryPrompt.listItem("- Anna writes the notes")])
    }

    @Test func sectionedSummariesPutTheTLDRInTheOverview() {
        let summary = GeneratedSectionedSummary(
            decisions: ["Ship Friday"],
            actionItems: [],
            openQuestions: ["Who reviews?"],
            tldr: " Shipping Friday. ",
            title: "Standup"
        )
        .noteSummary
        #expect(summary.overview == "Shipping Friday.")
        #expect(summary.decisions == [SummaryPrompt.listItem("Ship Friday")])
        #expect(summary.openQuestions == [SummaryPrompt.listItem("Who reviews?")])
    }

    @Test func onlyContextOverflowCountsAsOne() {
        struct Other: Error {}
        #expect(!SystemModelSummary.isContextOverflow(Other()))
        #expect(!SystemModelSummary.isContextOverflow(CancellationError()))
    }
}
