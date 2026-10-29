import Foundation
import MixdownNotes
import Testing

struct HelpTopicTests {
    @Test func linksOpenTopicsAndTheSetupAssistant() throws {
        #expect(HelpTopic(url: try #require(URL(string: "mixdown-help:speech-models"))) == .speechModels)
        #expect(HelpTopic(url: try #require(URL(string: "mixdown-help:Recording"))) == .recording)
        #expect(HelpTopic(url: try #require(URL(string: "mixdown-help:nowhere"))) == nil)
        #expect(HelpTopic(url: try #require(URL(string: "https://mixdown.app/recording"))) == nil)

        let setup = try #require(URL(string: "mixdown-help:setup-assistant"))
        #expect(HelpTopic.isSetupAssistantLink(setup))
        #expect(HelpTopic(url: setup) == nil)
    }

    @Test func everyLinkInATopicGoesSomewhere() throws {
        let link = /\]\((mixdown-help:[^)\s]+)\)/
        for topic in HelpTopic.allCases {
            for match in topic.markdown.matches(of: link) {
                let url = try #require(URL(string: String(match.1)))
                #expect(
                    HelpTopic(url: url) != nil || HelpTopic.isSetupAssistantLink(url),
                    "\(topic) links to \(url)"
                )
            }
        }
    }

    @Test func everyTopicHasATitleAndText() {
        for topic in HelpTopic.allCases {
            #expect(!topic.title.isEmpty)
            #expect(!topic.blocks.isEmpty)
        }
    }

    @Test func searchMatchesEveryWordWithTitlesFirst() {
        #expect(HelpTopic.search("  ") == HelpTopic.allCases)
        #expect(HelpTopic.search("zzzz-nothing") == [])

        let results = HelpTopic.search("chat")
        #expect(results.first == .chat)
        // Case and accents don't matter.
        #expect(HelpTopic.search("CHÀT").first == .chat)
    }
}
