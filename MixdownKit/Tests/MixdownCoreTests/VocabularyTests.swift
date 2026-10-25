import Foundation
import Testing

@testable import MixdownCore

struct VocabularyTests {
    private let vocabulary = Vocabulary(entries: [
        .init(term: "Kubernetes", soundsLike: ["cooper netties", "kuber nettis"]),
        .init(term: "Mixdown", soundsLike: ["mix down"]),
        .init(term: "C++", soundsLike: ["see plus plus"]),
    ])

    @Test(arguments: [
        ("We run cooper netties.", "We run Kubernetes."),
        ("Cooper Netties and KUBER NETTIS", "Kubernetes and Kubernetes"),
        ("cooper   netties", "Kubernetes"),
        ("mix down, mix downs, remix down", "Mixdown, mix downs, remix down"),
        ("I write see plus plus", "I write C++"),
        ("nothing to change", "nothing to change"),
    ])
    func replacesWholeWordsIgnoringCase(text: String, expected: String) {
        #expect(vocabulary.apply(to: text) == expected)
    }

    @Test func longerMatchesWinAndTermsAreNotMatchedAgain() {
        let vocabulary = Vocabulary(entries: [
            .init(term: "New York", soundsLike: ["york"]),
            .init(term: "New Yorker", soundsLike: ["york ah"]),
        ])
        #expect(vocabulary.apply(to: "york ah from york") == "New Yorker from New York")
    }

    @Test func termsContainingWhatAnEntrySoundsLikeAreLeftAlone() {
        let vocabulary = Vocabulary(entries: [
            .init(term: "New York", soundsLike: ["york"]),
            .init(term: "Hugging Face", soundsLike: ["hugging"]),
        ])
        let text = "From New York, new york and york to Hugging Face and hugging."
        let once = vocabulary.apply(to: text)
        #expect(once == "From New York, new york and New York to Hugging Face and Hugging Face.")
        #expect(vocabulary.apply(to: once) == once)
    }

    @Test func whatAnEntrySoundsLikeWinsOverAnotherEntrysTerm() {
        let vocabulary = Vocabulary(entries: [
            .init(term: "Mixdown", soundsLike: ["mix down"]),
            .init(term: "MixDown Pro", soundsLike: ["mixdown"]),
        ])
        #expect(vocabulary.apply(to: "mixdown and mix down") == "MixDown Pro and Mixdown")
    }

    @Test func termsAreListedOnceEach() {
        let vocabulary = Vocabulary(entries: [
            .init(term: " Kubernetes ", soundsLike: ["cooper netties"]),
            .init(term: "", soundsLike: ["word"]),
            .init(term: "kubernetes", soundsLike: ["kuber nettis"]),
            .init(term: "Acme", soundsLike: []),
        ])
        #expect(vocabulary.terms == ["Kubernetes", "Acme"])
    }

    @Test func flagsShortAndCommonSingleWords() {
        #expect(Vocabulary.isCommonWord("the"))
        #expect(Vocabulary.isCommonWord(" Und "))
        #expect(Vocabulary.isCommonWord("ok"))
        #expect(!Vocabulary.isCommonWord("netties"))
        #expect(!Vocabulary.isCommonWord("and so"))
        #expect(!Vocabulary.isCommonWord(""))
    }

    @Test func blankEntriesReplaceNothing() {
        let vocabulary = Vocabulary(entries: [
            .init(term: " ", soundsLike: ["word"]),
            .init(term: "Term", soundsLike: ["", "  "]),
        ])
        #expect(vocabulary.isEmpty)
        #expect(vocabulary.apply(to: "word") == "word")
        #expect(Vocabulary().isEmpty)
    }

    @Test func escapesWhatItMatchesAndPutsIn() {
        let vocabulary = Vocabulary(entries: [.init(term: "snake_case", soundsLike: ["snake case", "my_var"])])
        let escape = { (text: String) in text.replacingOccurrences(of: "_", with: #"\_"#) }
        let replacer = Vocabulary.Replacer(vocabulary, escaping: escape)
        #expect(replacer.replace(in: #"snake case and my\_var"#) == #"snake\_case and snake\_case"#)
    }

    @Test func appliesToEachSegment() {
        let transcript = Transcript(
            segments: [
                TranscriptSegment(start: 0, end: 1, text: "mix down", speaker: "Me"),
                TranscriptSegment(start: 1, end: 2, text: "on cooper netties"),
            ],
            language: "en"
        )
        let corrected = vocabulary.apply(to: transcript)
        #expect(corrected.segments.map(\.text) == ["Mixdown", "on Kubernetes"])
        #expect(corrected.segments.map(\.speaker) == ["Me", nil])
        #expect(corrected.language == "en")
    }

    @Test func addingJoinsTheEntryForTheSameTerm() {
        var vocabulary = Vocabulary().adding("cooper netties", for: " Kubernetes ")
        #expect(vocabulary.entries.map(\.term) == ["Kubernetes"])

        vocabulary = vocabulary.adding("kuber nettis", for: "kubernetes")
        vocabulary = vocabulary.adding("Cooper  Netties", for: "Kubernetes")
        vocabulary = vocabulary.adding("mix down", for: "Mixdown")
        #expect(vocabulary.entries.map(\.term) == ["Kubernetes", "Mixdown"])
        #expect(vocabulary.entries[0].soundsLike == ["cooper netties", "kuber nettis"])
        #expect(vocabulary.entries[1].soundsLike == ["mix down"])
    }
}
