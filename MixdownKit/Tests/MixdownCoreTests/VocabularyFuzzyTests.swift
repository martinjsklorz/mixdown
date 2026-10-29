import Foundation
import Testing

@testable import MixdownCore

struct VocabularyFuzzyTests {
    // The scores Muesli's matcher gives these, which made fuzzy matching opt-in: the last four
    // are ordinary words that come as close to the names as the misspellings do.
    @Test(arguments: [
        ("kubernetis", "Kubernetes", 0.960),
        ("sklortz", "Sklorz", 0.971),
        ("postgress", "Postgres", 0.978),
        ("mixtown", "Mixdown", 0.933),
        ("clause", "Claude", 0.933),
        ("marketing", "Martin", 0.922),
        ("posters", "Postgres", 0.946),
        ("cloud", "Claude", 0.858),
    ])
    func scoresLikeJaroWinkler(word: String, term: String, expected: Double) {
        let score = Vocabulary.FuzzyMatcher.jaroWinkler(word, term.lowercased())
        #expect(abs(score - expected) < 0.0005)
    }

    @Test func jaroWinklerOfEqualAndEmptyWords() {
        #expect(Vocabulary.FuzzyMatcher.jaroWinkler("same", "same") == 1)
        #expect(Vocabulary.FuzzyMatcher.jaroWinkler("", "word") == 0)
        #expect(Vocabulary.FuzzyMatcher.jaroWinkler("abc", "xyz") == 0)
    }

    private func correct(
        _ text: String,
        _ entries: [Vocabulary.Entry],
        knownWords: Set<String> = []
    ) -> (String, [Vocabulary.FuzzyMatch]) {
        let transcript = Transcript(segments: [TranscriptSegment(start: 0, end: 1, text: text)])
        let (corrected, matches) = Vocabulary(entries: entries).correct(transcript) {
            knownWords.contains($0.lowercased())
        }
        return (corrected.text, matches)
    }

    @Test func correctsCloseSpellingsOfFuzzyEntriesOnly() {
        let sklorz = Vocabulary.Entry(term: "Sklorz", soundsLike: [], fuzzy: .strict)
        let mixdown = Vocabulary.Entry(term: "Mixdown", soundsLike: [], fuzzy: .loose)
        let kubernetes = Vocabulary.Entry(term: "Kubernetes", soundsLike: [])
        let (text, matches) = correct("Sklortz said Mixtown runs on kubernetis.", [sklorz, mixdown, kubernetes])
        #expect(text == "Sklorz said Mixdown runs on kubernetis.")
        #expect(
            matches == [
                .init(heard: "sklortz", entryID: sklorz.id, term: "Sklorz"),
                .init(heard: "mixtown", entryID: mixdown.id, term: "Mixdown"),
            ]
        )
    }

    @Test func strictIsStricterThanLoose() {
        // "sklorts" scores 0.91 against "Sklorz".
        let loose = correct("sklorts", [.init(term: "Sklorz", soundsLike: [], fuzzy: .loose)]).0
        let strict = correct("sklorts", [.init(term: "Sklorz", soundsLike: [], fuzzy: .strict)]).0
        #expect(loose == "Sklorz")
        #expect(strict == "sklorts")
    }

    @Test func leavesWordsTheSpellCheckerKnows() {
        let entries: [Vocabulary.Entry] = [
            .init(term: "Claude", soundsLike: [], fuzzy: .loose),
            .init(term: "Martin", soundsLike: [], fuzzy: .loose),
            .init(term: "Postgres", soundsLike: [], fuzzy: .loose),
        ]
        let text = "The clause in marketing posters, and the cloud."
        let known: Set = ["clause", "marketing", "posters", "cloud"]
        #expect(correct(text, entries, knownWords: known) == (text, []))
        // Without the spell checker, they'd all have been changed but "cloud", at 0.86.
        #expect(correct(text, entries).0 == "The Claude in Martin Postgres, and the cloud.")
    }

    @Test func leavesShortAndCommonWords() {
        // "jiri" scores 0.88 against "Jira", and "think" 0.92 against "Thinq".
        let entries: [Vocabulary.Entry] = [
            .init(term: "Jira", soundsLike: [], fuzzy: .loose),
            .init(term: "Thinq", soundsLike: [], fuzzy: .loose),
        ]
        #expect(correct("I think jiri", entries).0 == "I think jiri")
        #expect(!entries[0].canMatchFuzzily)
        #expect(entries[1].canMatchFuzzily)
    }

    @Test func leavesWordsOfOtherEntries() {
        let entries: [Vocabulary.Entry] = [
            .init(term: "Postgres", soundsLike: [], fuzzy: .loose),
            .init(term: "PostgREST", soundsLike: []),
        ]
        #expect(correct("postgrest and postgress", entries).0 == "postgrest and Postgres")
    }

    @Test func exactMatchesComeFirstAndAreNotMatchedAgain() {
        let entries: [Vocabulary.Entry] = [
            .init(term: "Kubernetes", soundsLike: ["kuber nettis"], fuzzy: .loose),
            .init(term: "Kubernetis", soundsLike: ["cuber"]),
        ]
        // "cuber" becomes "Kubernetis", which isn't changed again to "Kubernetes".
        let (text, matches) = correct("kuber nettis, cuber and kubernetiss", entries)
        #expect(text == "Kubernetes, Kubernetis and Kubernetes")
        #expect(matches.map(\.heard) == ["kubernetiss"])
    }

    @Test func multiWordTermsMatchWordByWordWithinPunctuation() {
        let entry = Vocabulary.Entry(term: "Hugging Face", soundsLike: [], fuzzy: .loose)
        #expect(correct("I used huggin face today", [entry]).0 == "I used Hugging Face today")
        #expect(correct("huggin, face", [entry]).0 == "huggin, face")
        #expect(correct("huggin\nface", [entry]).0 == "huggin\nface")
        // Short words of the term have to be the same.
        let newYork = Vocabulary.Entry(term: "New Yorkers", soundsLike: [], fuzzy: .loose)
        #expect(correct("new yorkerz and now yorkerz", [newYork]).0 == "New Yorkers and now yorkerz")
    }

    @Test func leavesTheTermItselfAsItIs() {
        let entry = Vocabulary.Entry(term: "Sklorz", soundsLike: [], fuzzy: .loose)
        #expect(correct("sklorz and SKLORZ", [entry]) == ("sklorz and SKLORZ", []))
    }

    @Test func reportsEachSpellingOnce() {
        let entry = Vocabulary.Entry(term: "Sklorz", soundsLike: [], fuzzy: .loose)
        let (text, matches) = correct("sklortz, Sklortz and sklorts", [entry])
        #expect(text == "Sklorz, Sklorz and Sklorz")
        #expect(matches.map(\.heard) == ["sklortz", "sklorts"])
    }

    @Test func termsWithPunctuationAreNotMatchedFuzzily() {
        #expect(!Vocabulary.Entry(term: "Node.js", soundsLike: []).canMatchFuzzily)
        #expect(!Vocabulary.Entry(term: "C++", soundsLike: []).canMatchFuzzily)
        #expect(Vocabulary.Entry(term: " Sklorz ", soundsLike: []).canMatchFuzzily)
    }

    @Test func learningAddsWhatWasHeardToTheEntry() {
        let entry = Vocabulary.Entry(term: "Sklorz", soundsLike: ["sklorts", " "], fuzzy: .strict)
        let vocabulary = Vocabulary(entries: [entry]).learning([
            .init(heard: "sklortz", entryID: entry.id, term: "Sklorz"),
            .init(heard: "SKLORTS", entryID: entry.id, term: "Sklorz"),
            .init(heard: "removed", entryID: UUID(), term: "Gone"),
        ])
        #expect(vocabulary.entries.map(\.soundsLike) == [["sklorts", "sklortz"]])
    }

    @Test func notesAreOnlyCorrectedExactly() {
        let vocabulary = Vocabulary(entries: [.init(term: "Sklorz", soundsLike: [], fuzzy: .loose)])
        #expect(vocabulary.isEmpty)
        #expect(vocabulary.apply(to: "sklortz") == "sklortz")
    }
}
