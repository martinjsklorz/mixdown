import Foundation
import Testing

@testable import MixdownCore

struct SpeakerAssignmentTests {
    @Test func splitsTimedWordsWhereTheSpeakerChanges() {
        let segment = TranscriptSegment(start: 0, end: 4, text: "Shall we start? Yes, let's go.")
        let words = [
            LiveWord(text: "Shall", start: 0, end: 0.4),
            LiveWord(text: "we", start: 0.5, end: 0.7),
            LiveWord(text: "start?", start: 0.8, end: 1.2),
            LiveWord(text: "Yes,", start: 2, end: 2.4),
            LiveWord(text: "let's", start: 2.6, end: 3),
            LiveWord(text: "go.", start: 3.2, end: 4),
        ]
        let turns = [
            SpeakerTurn(start: 0, end: 1.3, speaker: 3),
            SpeakerTurn(start: 1.9, end: 4, speaker: 5),
        ]

        let labeled = SpeakerAssignment.label([segment], words: [words], turns: turns)

        #expect(
            labeled == [
                TranscriptSegment(start: 0, end: 1.2, text: "Shall we start?", speaker: "Speaker 1"),
                TranscriptSegment(start: 2, end: 4, text: "Yes, let's go.", speaker: "Speaker 2"),
            ]
        )
    }

    @Test func timedCutsALateWordIntoTheNextTurnMoveToTheSentenceEnd() {
        // The live model timed "NVIDIA." a little late, into the next speaker's turn.
        let first = TranscriptSegment(start: 0, end: 4, text: "I'm Chris from NVIDIA. Hi everybody!")
        let firstWords = [
            LiveWord(text: "I'm", start: 0, end: 0.4),
            LiveWord(text: "Chris", start: 0.5, end: 1),
            LiveWord(text: "from", start: 1.1, end: 1.5),
            LiveWord(text: "NVIDIA.", start: 1.9, end: 2.6),
            LiveWord(text: "Hi", start: 2.8, end: 3.1),
            LiveWord(text: "everybody!", start: 3.2, end: 4),
        ]
        // Likewise "list.", the last word of a segment.
        let second = TranscriptSegment(start: 5, end: 7, text: "I made the guest list.")
        let secondWords = [
            LiveWord(text: "I", start: 5, end: 5.2),
            LiveWord(text: "made", start: 5.3, end: 5.6),
            LiveWord(text: "the", start: 5.7, end: 5.9),
            LiveWord(text: "guest", start: 6, end: 6.4),
            LiveWord(text: "list.", start: 6.6, end: 7),
        ]
        let turns = [
            SpeakerTurn(start: 0, end: 1.8, speaker: 0),
            SpeakerTurn(start: 1.8, end: 4, speaker: 1),
            SpeakerTurn(start: 5, end: 6.5, speaker: 2),
            SpeakerTurn(start: 6.5, end: 8, speaker: 0),
        ]

        let labeled = SpeakerAssignment.label([first, second], words: [firstWords, secondWords], turns: turns)

        #expect(labeled.map(\.text) == ["I'm Chris from NVIDIA.", "Hi everybody!", "I made the guest list."])
        #expect(labeled.map(\.speaker) == ["Speaker 1", "Speaker 2", "Speaker 3"])
        #expect(labeled.map(\.end) == [2.6, 4, 7])
    }

    @Test func estimatedCutsMoveToTheNearestSentenceEnd() {
        // Evenly paced, "Bye" is said mostly before the turn changes at 3.3 s.
        let segment = TranscriptSegment(start: 0, end: 4, text: "Is everyone here? Sure thing. Bye now.")
        let turns = [
            SpeakerTurn(start: 0, end: 3.3, speaker: 0),
            SpeakerTurn(start: 3.3, end: 4, speaker: 1),
        ]

        let labeled = SpeakerAssignment.label([segment], turns: turns)

        #expect(labeled.map(\.text) == ["Is everyone here? Sure thing.", "Bye now."])
        #expect(labeled.map(\.speaker) == ["Speaker 1", "Speaker 2"])
        #expect(labeled.first?.start == 0)
        #expect(labeled.last?.end == 4)
    }

    @Test func aLoneEstimatedWordStaysWithItsSentence() {
        let segment = TranscriptSegment(start: 0, end: 3, text: "We ship it on Monday then")
        // A blip of another speaker over one word in the middle.
        let turns = [
            SpeakerTurn(start: 0, end: 1.2, speaker: 0),
            SpeakerTurn(start: 1.2, end: 1.6, speaker: 1),
            SpeakerTurn(start: 1.6, end: 3, speaker: 0),
            SpeakerTurn(start: 5, end: 6, speaker: 1),
        ]
        let other = TranscriptSegment(start: 5, end: 6, text: "Great.")

        let labeled = SpeakerAssignment.label([segment, other], turns: turns)

        #expect(labeled.map(\.text) == ["We ship it on Monday then", "Great."])
        #expect(labeled.map(\.speaker) == ["Speaker 1", "Speaker 2"])
    }

    @Test func speakersAreNumberedByFirstAppearance() {
        let segments = [
            TranscriptSegment(start: 0, end: 1, text: "First."),
            TranscriptSegment(start: 2, end: 3, text: "Second."),
            TranscriptSegment(start: 4, end: 5, text: "First again."),
        ]
        let turns = [
            SpeakerTurn(start: 0, end: 1, speaker: 7),
            SpeakerTurn(start: 2, end: 3, speaker: 2),
            SpeakerTurn(start: 4, end: 5, speaker: 7),
        ]

        let labeled = SpeakerAssignment.label(segments, turns: turns)

        #expect(labeled.map(\.speaker) == ["Speaker 1", "Speaker 2", "Speaker 1"])
    }

    @Test func oneSpeakerOrNoTurnsLeaveTheSegmentsUnlabeled() {
        let segments = [
            TranscriptSegment(start: 0, end: 1, text: "Hello.", speaker: "S01"),
            TranscriptSegment(start: 2, end: 3, text: "Anyone there?", speaker: "S02"),
        ]

        let alone = SpeakerAssignment.label(segments, turns: [SpeakerTurn(start: 0, end: 3, speaker: 0)])
        #expect(alone.map(\.speaker) == [nil, nil])
        #expect(alone.map(\.text) == ["Hello.", "Anyone there?"])

        #expect(SpeakerAssignment.label(segments, turns: []) == segments)
    }

    @Test func segmentsWithoutATurnTakeTheNearestSpeaker() {
        let segments = [
            TranscriptSegment(start: 0, end: 1, text: "Hi."),
            // The diarizer heard nobody here.
            TranscriptSegment(start: 10, end: 11, text: "Mhm."),
        ]
        let turns = [
            SpeakerTurn(start: 0, end: 1, speaker: 0),
            SpeakerTurn(start: 3, end: 4, speaker: 1),
        ]

        let labeled = SpeakerAssignment.label(segments, turns: turns)

        #expect(labeled.map(\.speaker) == ["Speaker 1", "Speaker 2"])
    }

    @Test func wordsThatDontMatchTheTextArePlacedEvenly() {
        let segment = TranscriptSegment(start: 0, end: 2, text: "One two. Three four.")
        // Stale words, e.g. from before a correction.
        let words = [LiveWord(text: "Won", start: 0, end: 1)]
        let turns = [
            SpeakerTurn(start: 0, end: 1, speaker: 0),
            SpeakerTurn(start: 1, end: 2, speaker: 1),
        ]

        let labeled = SpeakerAssignment.label([segment], words: [words], turns: turns)

        #expect(labeled.map(\.text) == ["One two.", "Three four."])
    }
}

struct SpeakerNamingTests {
    private let transcript = Transcript(segments: [
        TranscriptSegment(start: 0, end: 1, text: "Hi, I'm Anna from sales.", speaker: "Others (Speaker 1)"),
        TranscriptSegment(start: 1, end: 2, text: "Thanks Anna. Tom, your update?", speaker: "Me"),
        TranscriptSegment(start: 2, end: 3, text: "Sure, the release is on track.", speaker: "Others (Speaker 2)"),
    ])
    private let speakers = ["Others (Speaker 1)", "Others (Speaker 2)"]

    @Test func namesAreCheckedAgainstTheTranscript() async throws {
        let names = try await SpeakerNaming.names(for: speakers, in: transcript, maxTokens: 1000) { text, asked in
            // Shorter labels, which models keep to better.
            #expect(asked == ["Speaker 1", "Speaker 2"])
            #expect(text.contains("Speaker 1: Hi, I'm Anna from sales."))
            #expect(text.contains("Me: Thanks Anna."))
            // Answered with the labels it was shown, or the full ones. "Bob" is never said.
            return ["Others (Speaker 1)": "Anna.", "speaker 2": "Bob", "Me": "Martin"]
        }

        #expect(names == ["Others (Speaker 1)": "Anna"])
    }

    @Test func theNameGuessedMostOftenWins() async throws {
        let transcript = Transcript(segments: [
            TranscriptSegment(start: 0, end: 1, text: "Hi everyone, I'm Anna.", speaker: "Speaker 1"),
            TranscriptSegment(start: 1, end: 2, text: "Welcome, Anna, glad you could join.", speaker: "Me"),
            TranscriptSegment(start: 2, end: 3, text: "Tom and I prepared the slides.", speaker: "Speaker 1"),
            TranscriptSegment(start: 3, end: 4, text: "Great, go ahead with them please.", speaker: "Me"),
            TranscriptSegment(start: 4, end: 5, text: "Anna again, next slide now.", speaker: "Speaker 1"),
        ])
        // One line per piece.
        let calls = LockedValue(0)
        let names = try await SpeakerNaming.names(for: ["Speaker 1"], in: transcript, maxTokens: 15) { text, _ in
            calls.update { $0 += 1 }
            // Wrong where another name is said.
            return ["Speaker 1": text.contains("Tom") ? "Tom" : "Anna"]
        }

        // Pieces without a label to name aren't asked about.
        #expect(calls.current == 3)
        #expect(names == ["Speaker 1": "Anna"])
    }

    @Test func aNameTwoSpeakersGotGoesToTheMoreLikelyOne() async throws {
        let transcript = Transcript(segments: [
            TranscriptSegment(start: 0, end: 1, text: "Anna here.", speaker: "Speaker 1"),
            TranscriptSegment(start: 1, end: 2, text: "Hi Anna.", speaker: "Speaker 2"),
            TranscriptSegment(start: 2, end: 3, text: "Anna again.", speaker: "Speaker 1"),
        ])
        let names = try await SpeakerNaming.names(
            for: ["Speaker 1", "Speaker 2"],
            in: transcript,
            maxTokens: 8
        ) { _, asked in
            Dictionary(uniqueKeysWithValues: asked.map { ($0, "Anna") })
        }

        #expect(names == ["Speaker 1": "Anna"])
    }

    @Test func failingPiecesAreLeftOutUnlessAllFail() async throws {
        let error = SummarizationError.failed("broken")
        let calls = LockedValue(0)
        // One line per piece.
        let names = try await SpeakerNaming.names(for: speakers, in: transcript, maxTokens: 20) { _, asked in
            calls.update { $0 += 1 }
            if calls.current == 1 { throw error }
            return asked.contains("Speaker 2") ? ["Speaker 2": "Tom"] : [:]
        }
        // "Tom" isn't said in the second piece asked about.
        #expect(calls.current == 2)
        #expect(names == [:])

        await #expect(throws: SummarizationError.self) {
            try await SpeakerNaming.names(for: speakers, in: transcript, maxTokens: 1000) { _, _ in throw error }
        }
    }

    @Test func notNamesAreDropped() {
        #expect(SpeakerNaming.cleanedName(" “Anna Schmidt”. ") == "Anna Schmidt")
        #expect(SpeakerNaming.cleanedName("Unknown") == nil)
        #expect(SpeakerNaming.cleanedName("Speaker 2") == nil)
        #expect(SpeakerNaming.cleanedName("") == nil)
        #expect(SpeakerNaming.cleanedName("the person who presented the quarterly numbers") == nil)
        #expect(SpeakerNaming.cleanedName("Chris, the Nemotron voice") == nil)
    }

    @Test func namesAreSpelledAsTheyreSaid() {
        #expect(SpeakerNaming.name("anna", in: "Hi, I'm Anna.") == "Anna")
        #expect(SpeakerNaming.name("Zoë", in: "Thanks, Zoe!") == "Zoe")
        #expect(SpeakerNaming.name("Chris", in: "It's Chris's turn.") == "Chris")
        #expect(SpeakerNaming.name("Ludwig van Beethoven", in: "By Ludwig van Beethoven.") == "Ludwig van Beethoven")
        #expect(SpeakerNaming.name("王芳", in: "我是王芳。") == "王芳")
        // Not said, only partly said, or not a name.
        #expect(SpeakerNaming.name("Bob", in: "Hi, I'm Anna.") == nil)
        #expect(SpeakerNaming.name("Anna Schmidt", in: "Anna said") == nil)
        #expect(SpeakerNaming.name("Ann", in: "Announcements first.") == nil)
        #expect(SpeakerNaming.name("Great", in: "great crowd") == nil)
    }

    @Test func labelsAreShortenedAndMatchedLoosely() {
        let speakers = ["Others (Speaker 1)", "Others (Speaker 3)"]
        #expect(
            SpeakerNaming.aliases(for: speakers, among: ["Me"] + speakers)
                == ["Others (Speaker 1)": "Speaker 1", "Others (Speaker 3)": "Speaker 2"]
        )
        // Not when another speaker has that label already.
        #expect(
            SpeakerNaming.aliases(for: ["Me (Speaker 1)"], among: ["Speaker 1", "Me (Speaker 1)"])
                == ["Me (Speaker 1)": "Me (Speaker 1)"]
        )

        let asked = ["Speaker 1", "Speaker 2"]
        #expect(SpeakerNaming.matchingLabel(" \"speaker 2\": ", among: asked) == "Speaker 2")
        #expect(SpeakerNaming.matchingLabel("Others (Speaker 1)", among: asked) == "Speaker 1")
        #expect(SpeakerNaming.matchingLabel("Speaker 3", among: asked) == nil)
        #expect(SpeakerNaming.matchingLabel("Speaker 2", among: ["Me (Speaker 2)", "Others (Speaker 2)"]) == nil)
        #expect(SpeakerNaming.matchingLabel("Speaker 2", among: ["Others (Speaker 2)"]) == "Others (Speaker 2)")
    }

    @Test func readsGuessesFromJSON() {
        let answer = "<think>hm</think>\n```json\n{\"Speaker 1\": \"Anna\", \"Speaker 2\": null}\n```"
        #expect(SpeakerNaming.guesses(fromJSON: answer) == ["Speaker 1": "Anna"])
        #expect(SpeakerNaming.guesses(fromJSON: "{}") == [:])
        #expect(SpeakerNaming.guesses(fromJSON: "No idea.") == nil)
    }

    @Test func applyingRenamesOnlyTheNamedSpeakers() {
        let named = SpeakerNaming.applying(["Others (Speaker 1)": "Anna"], to: transcript)

        #expect(named.segments.map(\.speaker) == ["Anna", "Me", "Others (Speaker 2)"])
        #expect(named.segments.map(\.text) == transcript.segments.map(\.text))
    }
}
