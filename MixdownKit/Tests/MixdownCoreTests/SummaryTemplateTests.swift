import Foundation
import Testing

@testable import MixdownCore

struct SummaryTemplateTests {
    @Test func listPutsBuiltInsFirstAndKeepsEdits() {
        var standup = SummaryTemplate.standup
        standup.name = "Daily"
        let review = SummaryTemplate(id: "custom-1", name: "Review")
        let list = SummaryTemplate.list(from: [review, standup, SummaryTemplate(id: "custom-1", name: "Duplicate")])

        #expect(list.map(\.id) == ["general", "oneOnOne", "standup", "clientCall", "custom-1"])
        #expect(list[2].name == "Daily")
        #expect(list[4].name == "Review")
        #expect(SummaryTemplate.list(from: []) == SummaryTemplate.builtIns)
    }

    @Test func knowsWhichBuiltInsWereEdited() {
        var oneOnOne = SummaryTemplate.oneOnOne
        #expect(oneOnOne.isBuiltIn && !oneOnOne.isEdited)
        oneOnOne.layout = .overview
        #expect(oneOnOne.isEdited)

        let review = SummaryTemplate(id: "custom-1", name: "Review")
        #expect(!review.isBuiltIn && !review.isEdited)
    }

    @Test func newTemplatesGetNamesNotYetTaken() {
        let first = SummaryTemplate.new(in: SummaryTemplate.builtIns)
        #expect(first.name == "New Template")
        #expect(!first.isBuiltIn)
        let second = SummaryTemplate.new(in: SummaryTemplate.builtIns + [first])
        #expect(second.name == "New Template 2")
        #expect(second.id != first.id)

        let copy = SummaryTemplate.copy(of: .standup, in: SummaryTemplate.builtIns)
        #expect(copy.name == "Standup Copy")
        #expect(copy.instructions == SummaryTemplate.standup.instructions)
        #expect(copy.layout == .sections && !copy.isBuiltIn)
        #expect(SummaryTemplate.copy(of: .standup, in: SummaryTemplate.builtIns + [copy]).name == "Standup Copy 2")
    }

    @Test func blankNamesShowAsUntitled() {
        #expect(SummaryTemplate(id: "custom-1", name: "  ").displayName == "Untitled Template")
        #expect(SummaryTemplate(id: "custom-1", name: " Review ").displayName == "Review")
    }

    @Test func decodesLeniently() throws {
        let json = #"[{"id": "custom-1", "name": "Review", "layout": "columns"}, {"id": "standup"}]"#
        let templates = try JSONDecoder().decode([SummaryTemplate].self, from: Data(json.utf8))
        #expect(templates == [
            SummaryTemplate(id: "custom-1", name: "Review", instructions: "", layout: .overview),
            SummaryTemplate(id: "standup", name: "", instructions: "", layout: .overview),
        ])

        let review = SummaryTemplate(id: "custom-2", name: "Review", instructions: "Demos.", layout: .sections)
        let decoded = try JSONDecoder().decode(SummaryTemplate.self, from: JSONEncoder().encode(review))
        #expect(decoded == review)
    }
}
