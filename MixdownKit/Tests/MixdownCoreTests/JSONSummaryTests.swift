import Testing

@testable import MixdownCore

struct JSONSummaryTests {
    @Test func readsAGeneralSummary() {
        let answer = """
            {"keyPoints": ["- The launch moves to May.", "Budget approved"], "actionItems": ["Anna sends the plan"],
             "overview": " The team planned the launch. ", "title": "Launch planning"}
            """
        let summary = JSONSummary.summary(from: answer, template: .general)
        #expect(
            summary
                == NoteSummary(
                    template: .general,
                    title: "Launch planning",
                    overview: "The team planned the launch.",
                    keyPoints: ["The launch moves to May.", "Budget approved"],
                    actionItems: ["Anna sends the plan"]
                )
        )
    }

    @Test func readsASectionedSummary() {
        let answer = """
            {"decisions": ["Ship on Friday"], "actionItems": [], "openQuestions": ["Who tests it?"],
             "tldr": "Shipping Friday.", "title": "Release"}
            """
        let summary = JSONSummary.summary(from: answer, template: .standup)
        #expect(summary?.template == .standup)
        #expect(summary?.overview == "Shipping Friday.")
        #expect(summary?.decisions == ["Ship on Friday"])
        #expect(summary?.actionItems == [])
        #expect(summary?.openQuestions == ["Who tests it?"])
    }

    @Test func skipsThinkingAndCodeFences() {
        let answer = """
            <think>The user wants {a summary}.</think>
            Here it is:
            ```json
            {"keyPoints": [], "actionItems": [], "overview": "Short call.", "title": "Check-in"}
            ```
            """
        let summary = JSONSummary.summary(from: answer, template: .general)
        #expect(summary?.title == "Check-in")
        #expect(summary?.overview == "Short call.")
    }

    @Test func acceptsAStringForAListAndDropsBlankItems() {
        let answer = #"{"keyPoints": "One point", "actionItems": ["", "  "], "overview": "", "title": "T"}"#
        let summary = JSONSummary.summary(from: answer, template: .general)
        #expect(summary?.keyPoints == ["One point"])
        #expect(summary?.actionItems == [])
    }

    @Test func returnsNilWithoutJSON() {
        #expect(JSONSummary.summary(from: "Sorry, I can't help with that.", template: .general) == nil)
        #expect(JSONSummary.summary(from: "{not json}", template: .general) == nil)
        #expect(JSONSummary.catchUpPoints(from: "") == nil)
    }

    @Test func readsAtMostFourCatchUpPoints() {
        let answer = #"{"points": ["a", "b", "c", "d", "e"]}"#
        #expect(JSONSummary.catchUpPoints(from: answer) == ["a", "b", "c", "d"])
    }

    @Test func formatListsTheKeysOfTheTemplate() {
        let general = JSONSummary.format(for: .general, language: nil)
        #expect(general.contains("\"keyPoints\"") && general.contains("\"overview\""))
        #expect(!general.contains("\"tldr\""))
        let sectioned = JSONSummary.format(for: .clientCall, language: "de")
        #expect(sectioned.contains("\"decisions\"") && sectioned.contains("\"openQuestions\""))
        #expect(sectioned.contains("\"tldr\""))
        #expect(sectioned.hasSuffix("You MUST write in German."))
    }

    @Test func instructionsAskForTheLanguage() {
        let instructions = SummaryPrompt.instructions(for: .transcript, template: .general, language: "de")
        #expect(instructions.contains("You MUST write in German."))
        let catchUp = SummaryPrompt.catchUpInstructions(for: .combine, language: nil)
        #expect(catchUp.contains("You MUST write in the language of the transcript."))
    }

    @Test func instructionsExplainMarkedMomentsOnlyWhenThereAreSome() throws {
        let rule = try #require(SummaryPrompt.momentsRule(for: .transcript))
        let review = SummaryTemplate(id: "custom-1", name: "Review", instructions: "Look out for demos.")
        let marked = SummaryPrompt.instructions(for: .transcript, template: review, language: nil, hasMoments: true)
        #expect(marked.contains("name.\n\(rule)\nLook out for demos.\n"))
        #expect(!SummaryPrompt.instructions(for: .transcript, template: review, language: nil).contains(rule))
        #expect(SummaryPrompt.momentsRule(for: .combine) == nil)
        #expect(
            SummaryPrompt.instructions(for: .combine, template: .general, language: nil, hasMoments: true)
                == SummaryPrompt.instructions(for: .combine, template: .general, language: nil)
        )
    }

    @Test func instructionsIncludeTheTemplatesOwn() {
        let review = SummaryTemplate(id: "custom-1", name: "Review", instructions: "  Look out for demos.\n")
        let instructions = SummaryPrompt.instructions(for: .transcript, template: review, language: nil)
        #expect(instructions.contains("name.\nLook out for demos.\nOnly use what's in the text"))
        #expect(!SummaryPrompt.instructions(for: .combine, template: .general, language: nil).contains("\n\n"))

        let long = SummaryTemplate(id: "custom-2", name: "Long", instructions: String(repeating: "a", count: 5000))
        #expect(SummaryPrompt.focus(of: long)?.count == SummaryTemplate.maximumInstructionsLength)
        #expect(SummaryPrompt.focus(of: SummaryTemplate(id: "custom-3", name: "Blank", instructions: " \n")) == nil)
    }

    @Test func formatFollowsTheLayout() {
        let custom = SummaryTemplate(id: "custom-1", name: "Review", layout: .sections)
        #expect(JSONSummary.format(for: custom, language: nil).contains("\"tldr\""))
        var general = SummaryTemplate.general
        general.layout = .sections
        let answer = #"{"tldr": "Short.", "decisions": ["Ship"]}"#
        #expect(JSONSummary.summary(from: answer, template: general)?.decisions == ["Ship"])
    }

    @Test func readsATitleAnswer() {
        #expect(SummaryPrompt.title(from: "\"May Launch Plan\"") == "May Launch Plan")
        #expect(SummaryPrompt.title(from: "Title: Budget review.\nMore text") == "Budget review")
        #expect(SummaryPrompt.title(from: "<think>hmm</think>\n**Release Planning**") == "Release Planning")
        #expect(SummaryPrompt.title(from: "") == "")
    }

    @Test func repairsAMissingCommaAndATrailingComma() {
        let answer = """
            {
              "decisions": ["Move launch to May",],
              "actionItems": [],
              "openQuestions": ["Pricing page?"],
              "tldr": "Launch moves to May."
              "title": "Launch Planning"
            }
            """
        let summary = JSONSummary.summary(from: answer, template: .standup)
        #expect(summary?.decisions == ["Move launch to May"])
        #expect(summary?.overview == "Launch moves to May.")
        #expect(summary?.title == "Launch Planning")
    }

    @Test func repairLeavesValidJSONAlone() {
        let json = "{\"a\": [\"x, y\"],\n \"b\": \"z\"}"
        #expect(JSONSummary.repaired(json) == json)
    }

    // MARK: - Reading odd answers

    @Test func readsTheFirstOfTwoObjects() {
        let answer = """
            {"keyPoints": ["First"], "overview": "The first {draft}.", "title": "One"}
            {"keyPoints": ["Second"], "overview": "Again.", "title": "Two"}
            """
        let summary = JSONSummary.summary(from: answer, template: .general)
        #expect(summary?.title == "One")
        #expect(summary?.overview == "The first {draft}.")
    }

    @Test func skipsBracesAroundTheObject() {
        let before = #"Here it is {as asked}: {"title": "Budget", "overview": "Quote \" and } inside."}"#
        #expect(JSONSummary.summary(from: before, template: .general)?.overview == #"Quote " and } inside."#)
        let after = #"{"title": "Budget"} {note: I kept it short}"#
        #expect(JSONSummary.summary(from: after, template: .general)?.title == "Budget")
    }

    @Test func readsAnAnswerCutOffInAList() {
        let answer = #"{"keyPoints": ["Launch moves to May", "Budget appro"#
        let summary = JSONSummary.summary(from: answer, template: .general)
        #expect(summary?.keyPoints == ["Launch moves to May"])
        #expect(summary?.title == "")
        let inAKey = #"{"keyPoints": ["Launch moves to May"], "action"#
        #expect(JSONSummary.summary(from: inAKey, template: .general)?.keyPoints == ["Launch moves to May"])
        let afterAValue = #"{"keyPoints": [], "title": "Launch""#
        #expect(JSONSummary.summary(from: afterAValue, template: .general)?.title == "Launch")
    }

    @Test func answerCutOffBeforeAnyValueIsNone() {
        #expect(JSONSummary.summary(from: #"{"keyPo"#, template: .general) == nil)
        #expect(SpeakerNaming.guesses(fromJSON: "{}") == [:])
    }

    @Test func listsDropRepeatsAndKeepAtMostEight() {
        let items = (1...12).map { "\"Point \($0 % 10)\"" }.joined(separator: ", ")
        let summary = JSONSummary.summary(from: "{\"keyPoints\": [\(items), \"point 1\"]}", template: .general)
        #expect(summary?.keyPoints == (1...8).map { "Point \($0)" })
    }

    @Test func answerInstructionsAskForTheLanguage() {
        #expect(
            SummaryPrompt.languageRule("fr", verb: "answer", fallback: "the question") == "You MUST answer in French."
        )
        #expect(
            SummaryPrompt.languageRule(nil, verb: "answer", fallback: "the question")
                == "You MUST answer in the language of the question."
        )
    }
}
