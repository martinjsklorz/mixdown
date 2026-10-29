import Foundation
import Testing

@testable import MixdownCore

struct VocabularyFileTests {
    @Test func writesEntriesWithoutIDsOrBlanks() {
        let vocabulary = Vocabulary(entries: [
            .init(term: " Kubernetes ", soundsLike: ["cooper netties", " ", "kuber/nettis"]),
            .init(term: "", soundsLike: ["unfinished"]),
            .init(term: "Sklorz \"the\" name", soundsLike: [], fuzzy: .strict),
        ])
        let text = String(decoding: vocabulary.fileContents(), as: UTF8.self)
        #expect(
            text == """
                [
                  {
                    "term": "Kubernetes",
                    "soundsLike": ["cooper netties", "kuber/nettis"]
                  },
                  {
                    "term": "Sklorz \\"the\\" name",
                    "soundsLike": [],
                    "fuzzy": "strict"
                  }
                ]

                """
        )
        #expect(String(decoding: Vocabulary().fileContents(), as: UTF8.self) == "[]\n")
    }

    @Test func readsWhatItWrites() throws {
        let vocabulary = Vocabulary(entries: [
            .init(term: "Kubernetes", soundsLike: ["cooper netties"]),
            .init(term: "Sklorz", soundsLike: [], fuzzy: .loose),
        ])
        #expect(
            try Vocabulary.fileEntries(from: vocabulary.fileContents()) == [
                .init(term: "Kubernetes", soundsLike: ["cooper netties"]),
                .init(term: "Sklorz", soundsLike: [], fuzzy: .loose),
            ]
        )
    }

    @Test func readsMuesliDictionaries() throws {
        let json = """
            [
              {"word": "museli", "replacement": "muesli", "matching_threshold": 0.85},
              {"word": "Kubernetes"},
              {"word": "postgres", "replacement": "Postgres"},
              {"replacement": "no word"}
            ]
            """
        #expect(
            try Vocabulary.fileEntries(from: Data(json.utf8)) == [
                .init(term: "muesli", soundsLike: ["museli"]),
                .init(term: "Kubernetes", soundsLike: []),
                .init(term: "Postgres", soundsLike: []),
            ]
        )
    }

    @Test func readsStoredSettingsAndHandWrittenEntries() throws {
        let stored = #"{"entries": [{"id": "x", "term": "Acme", "soundsLike": "ack me", "fuzzy": "maybe"}, 3]}"#
        #expect(try Vocabulary.fileEntries(from: Data(stored.utf8)) == [.init(term: "Acme", soundsLike: ["ack me"])])
    }

    @Test(arguments: ["", "not json", #"{"words": []}"#, "42"])
    func refusesFilesThatAreNoVocabulary(contents: String) {
        #expect(throws: Vocabulary.FileError.notAVocabulary) {
            try Vocabulary.fileEntries(from: Data(contents.utf8))
        }
    }

    @Test func mergesByTermIgnoringCase() {
        let kubernetes = Vocabulary.Entry(term: "Kubernetes", soundsLike: ["cooper netties", ""])
        let mixdown = Vocabulary.Entry(term: "Mixdown", soundsLike: ["mix down"])
        let sklorz = Vocabulary.Entry(term: "Sklorz", soundsLike: [])
        let merge = Vocabulary(entries: [kubernetes, mixdown, sklorz]).merging([
            .init(term: "kubernetes", soundsLike: ["Cooper Netties", "kuber nettis"]),
            .init(term: "MIXDOWN", soundsLike: ["mix down"]),
            .init(term: "Sklorz", soundsLike: [], fuzzy: .strict),
            .init(term: "Postgres", soundsLike: ["post grass", "post grass"]),
            .init(term: "postgres", soundsLike: ["post gress"]),
            .init(term: " ", soundsLike: ["ignored"]),
        ])

        #expect(merge.vocabulary.entries.map(\.term) == ["Kubernetes", "Mixdown", "Sklorz", "Postgres"])
        #expect(Array(merge.vocabulary.entries.map(\.id).prefix(3)) == [kubernetes.id, mixdown.id, sklorz.id])
        #expect(
            merge.vocabulary.entries.map(\.soundsLike) == [
                ["cooper netties", "kuber nettis"], ["mix down"], [], ["post grass", "post gress"],
            ]
        )
        #expect(merge.vocabulary.entries.map(\.fuzzy) == [.off, .off, .strict, .off])
        #expect((merge.added, merge.updated, merge.unchanged) == (1, 2, 1))
        #expect(merge.summary == "1 added, 2 updated, 1 unchanged.")
        #expect(
            merge.newWords.entries.map { [$0.term] + $0.soundsLike } == [
                ["Kubernetes", "kuber nettis"], ["Postgres", "post grass", "post gress"],
            ]
        )
    }

    @Test func fuzzyIsKeptWhenTheFileDoesntSay() {
        let entry = Vocabulary.Entry(term: "Sklorz", soundsLike: [], fuzzy: .loose)
        let merge = Vocabulary(entries: [entry]).merging([.init(term: "Sklorz", soundsLike: [])])
        #expect(merge.vocabulary.entries == [entry])
        #expect(merge.summary == "0 added, 0 updated, 1 unchanged.")
        #expect(Vocabulary().merging([]).summary == "There were no words in the file.")
    }
}
