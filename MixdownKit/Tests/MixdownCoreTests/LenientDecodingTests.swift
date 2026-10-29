import Foundation
import MixdownCore
import Testing

/// Stored settings read by another version, or with one entry gone wrong, keep what can be read.
struct LenientDecodingTests {
    private func decode<Value: Decodable>(_ type: Value.Type, _ json: String) throws -> Value {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    @Test func lossyArraysDropOnlyTheElementsThatCantBeRead() throws {
        let numbers = try decode(LossyArray<Int>.self, #"[1, "two", 3, null, {"four": 4}, 5]"#)
        #expect(numbers.elements == [1, 3, 5])
    }

    @Test func vocabularyKeepsTheEntriesThatCanBeRead() throws {
        let vocabulary = try decode(
            Vocabulary.self,
            """
            {"entries": [
                {"term": "Kubernetes", "soundsLike": ["cooper netties"]},
                "not an entry",
                {"id": "9C2B3A1E-5F7D-4E1A-9B0C-2D3E4F5A6B7C", "term": "Mixdown", "soundsLike": ["mix down", 7]},
                {"term": "Anna"}
            ]}
            """
        )
        #expect(vocabulary.entries.map(\.term) == ["Kubernetes", "Mixdown", "Anna"])
        #expect(vocabulary.entries[1].id.uuidString == "9C2B3A1E-5F7D-4E1A-9B0C-2D3E4F5A6B7C")
        #expect(vocabulary.entries[1].soundsLike == ["mix down"])
        #expect(vocabulary.entries[2].soundsLike == [])
        // Entries without an id get one each.
        #expect(vocabulary.entries[0].id != vocabulary.entries[2].id)
    }

    @Test func vocabularyRoundTrips() throws {
        let vocabulary = Vocabulary(entries: [.init(term: "Kubernetes", soundsLike: ["cooper netties"])])
        let data = try JSONEncoder().encode(vocabulary)
        #expect(try JSONDecoder().decode(Vocabulary.self, from: data) == vocabulary)
    }

    @Test func callAppsFromBeforeIsBrowserStillRead() throws {
        let selection = try decode(
            CallAppSelection.self,
            """
            {"excludedIDs": ["us.zoom.xos"], "added": [
                {"name": "Old App", "bundleIDs": ["com.example.old"]},
                {"name": "No IDs", "bundleIDs": []},
                {"bundleIDs": ["com.example.unnamed"], "isBrowser": true}
            ]}
            """
        )
        #expect(selection.excludedIDs == ["us.zoom.xos"])
        #expect(
            selection.added == [
                CallApp(name: "Old App", bundleIDs: ["com.example.old"]),
                CallApp(name: "com.example.unnamed", bundleIDs: ["com.example.unnamed"], isBrowser: true),
            ]
        )
    }

    @Test func callAppSelectionRoundTrips() throws {
        let selection = CallAppSelection(
            excludedIDs: ["us.zoom.xos"],
            added: [CallApp(name: "Arc Beta", bundleIDs: ["company.thebrowser.Browser.beta"], isBrowser: true)]
        )
        let data = try JSONEncoder().encode(selection)
        #expect(try JSONDecoder().decode(CallAppSelection.self, from: data) == selection)
    }

    @Test func oneOddTemplateDoesntLoseTheOthers() throws {
        let templates = try decode(
            LossyArray<SummaryTemplate>.self,
            #"[{"id": "standup", "name": "Standup"}, {"name": "No ID"}, {"id": "retro", "layout": "nonsense"}]"#
        )
        #expect(templates.elements.map(\.id) == ["standup", "retro"])
    }
}
