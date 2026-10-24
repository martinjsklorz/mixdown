import Foundation
import MixdownCore
import Testing

@testable import MixdownNotes

struct NoteQuestionTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        calendar.firstWeekday = 2
        return calendar
    }()

    /// Wednesday, 21 October 2026, at noon.
    private static let now = date(2026, 10, 21, hour: 12)

    private static func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)) ?? .distantPast
    }

    private func parse(_ question: String) -> NoteQuestion {
        NoteQuestion.parse(question, now: Self.now, calendar: Self.calendar)
    }

    private func note(
        title: String = "Weekly Sync",
        created: Date = NoteQuestionTests.date(2026, 9, 10, hour: 9),
        duration: Int = 1800,
        frontmatter: [String] = [],
        body: String = "Hello everyone."
    ) -> NoteDocument {
        let contents = (["---", "title: \"\(title)\"", "duration: \(duration)"] + frontmatter + ["---", "", body])
            .joined(separator: "\n")
        return NoteDocument(url: URL(filePath: "/notes/\(title).md"), contents: contents, fileDate: created)
    }

    // MARK: Parsing

    @Test func readsCountOfKindInMonth() {
        let question = parse("How many 1:1s did I have in September?")

        #expect(question.asksForCount)
        #expect(question.kind == .oneOnOne)
        #expect(question.dates == DateInterval(start: Self.date(2026, 9, 1), end: Self.date(2026, 10, 1)))
        #expect(question.datePhrase == "in September 2026")
        #expect(question.topic.isEmpty)
    }

    @Test func monthsAheadOfNowAreLastYears() {
        let question = parse("how many standups in December?")

        #expect(question.kind == .standup)
        #expect(question.dates?.start == Self.date(2025, 12, 1))
        #expect(question.datePhrase == "in December 2025")
    }

    @Test func monthWithYear() {
        #expect(parse("How many calls in March 2025").dates?.start == Self.date(2025, 3, 1))
        #expect(parse("How many calls in Sept 2024?").dates?.start == Self.date(2024, 9, 1))
    }

    @Test func monthNamesThatAreWordsNeedAPreposition() {
        #expect(parse("How many notes may mention pricing?").dates == nil)
        #expect(parse("How many notes in May?").dates?.start == Self.date(2026, 5, 1))
    }

    @Test func readsRelativeDates() {
        #expect(
            parse("how many calls today").dates
                == DateInterval(start: Self.date(2026, 10, 21), end: Self.date(2026, 10, 22))
        )
        #expect(parse("how many calls yesterday").datePhrase == "yesterday")
        // Monday to Monday.
        #expect(
            parse("how many calls last week").dates
                == DateInterval(start: Self.date(2026, 10, 12), end: Self.date(2026, 10, 19))
        )
        #expect(parse("how many calls this week").dates?.start == Self.date(2026, 10, 19))
        #expect(parse("how many calls last month").dates?.start == Self.date(2026, 9, 1))
        #expect(parse("how many calls this year").dates?.start == Self.date(2026, 1, 1))
        #expect(
            parse("how many calls in the last 7 days").dates
                == DateInterval(start: Self.date(2026, 10, 15), end: Self.date(2026, 10, 22))
        )
        #expect(
            parse("how many calls in 2025").dates
                == DateInterval(start: Self.date(2025, 1, 1), end: Self.date(2026, 1, 1))
        )
        #expect(
            parse("how many calls since August").dates
                == DateInterval(start: Self.date(2026, 8, 1), end: Self.date(2026, 10, 22))
        )
        #expect(
            parse("how many calls in the last 2 years").dates
                == DateInterval(start: Self.date(2024, 10, 21, hour: 12), end: Self.date(2026, 10, 22))
        )
        #expect(parse("how many calls in the last 2 years").datePhrase == "in the last 2 years")
        #expect(parse("Wie viele Anrufe in den letzten 3 Jahren?").dates?.start == Self.date(2023, 10, 21, hour: 12))
        #expect(parse("how many calls since 2024").dates?.start == Self.date(2024, 1, 1))
        #expect(parse("Wie viele Anrufe im Jahr 2025?").dates?.start == Self.date(2025, 1, 1))
    }

    @Test func numbersWithoutPrepositionArentYears() {
        let question = parse("How many notes mention 2000 users?")

        #expect(question.dates == nil)
        #expect(question.topic == ["2000", "users"])
    }

    @Test func readsGerman() {
        let question = parse("Wie viele Einzelgespräche hatte ich im September?")

        #expect(question.asksForCount)
        #expect(question.kind == .oneOnOne)
        #expect(question.dates?.start == Self.date(2026, 9, 1))
        #expect(parse("Wie viele Anrufe letzte Woche?").kind == .call)
        #expect(parse("Wie viele Anrufe letzte Woche?").dates?.start == Self.date(2026, 10, 12))
        #expect(parse("Wie viele Notizen im März?").dates?.start == Self.date(2026, 3, 1))
    }

    @Test func readsKinds() {
        #expect(parse("how many one-on-ones").kind == .oneOnOne)
        #expect(parse("how many 1-on-1s").kind == .oneOnOne)
        #expect(parse("how many client calls").kind == .clientCall)
        #expect(parse("how many stand-ups").kind == .standup)
        #expect(parse("how many calls").kind == .call)
        #expect(parse("how many notes").kind == nil)
        // Not a 1:1.
        #expect(parse("how many notes at 11:15").kind == nil)
    }

    @Test func readsTopicOfCount() {
        #expect(parse("How many calls mentioned the budget last week?").topic == ["budget"])
        #expect(parse("How many 1:1s with Anna in September?").topic == ["Anna"])
        #expect(parse("How many notes about the Q3 roadmap?").topic == ["Q3", "roadmap"])
        #expect(parse("How many meetings did I have?").topic.isEmpty)
    }

    @Test func questionsWithoutCount() {
        let question = parse("What did we decide about pricing last week?")

        #expect(!question.asksForCount)
        #expect(question.topic.isEmpty)
        #expect(question.dates?.start == Self.date(2026, 10, 12))
        #expect(question.searchText == "What did we decide about pricing ?")
    }

    // MARK: Counting

    @Test func countsByTemplateOrTitle() {
        let question = parse("How many 1:1s did I have in September?")
        let notes = [
            note(title: "Career goals", frontmatter: ["template: oneOnOne"]),
            note(title: "1:1 Anna"),
            note(title: "Release planning", frontmatter: ["template: standup"]),
            // Its template says it isn't one.
            note(title: "Prep for 1:1", frontmatter: ["template: standup"]),
            note(title: "1:1 Ben", created: Self.date(2026, 10, 2)),
        ]

        let counted = notes.filter(question.counts)

        #expect(counted.map(\.title) == ["Career goals", "1:1 Anna"])
        #expect(question.countAnswer(for: counted) == "You recorded **2** 1:1s in September 2026, 1 h 0 min in all.")
    }

    @Test func countsCalls() {
        let question = parse("how many calls this year?")
        let notes = [
            note(title: "A", frontmatter: ["call: true"]),
            note(title: "B", frontmatter: ["trigger: automatic"]),
            note(title: "Call about Pricing"),
            note(title: "Anruf zu Budget"),
            note(title: "Voice memo"),
        ]

        #expect(notes.filter(question.counts).map(\.title) == ["A", "B", "Call about Pricing", "Anruf zu Budget"])
    }

    @Test func countsNotesMentioningTopic() {
        let question = parse("How many notes mention the budget?")
        let notes = [note(title: "A", body: "The Budget is tight."), note(title: "B", body: "No money talk.")]

        let counted = notes.filter(question.counts)

        #expect(counted.map(\.title) == ["A"])
        #expect(question.countAnswer(for: counted) == "You recorded **1** note that mentions “budget”, 30 min in all.")
    }

    @Test func countsTopicAsWholeWords() {
        let notes = [
            note(title: "A", body: "She said it again."),
            note(title: "B", body: "Our AI roadmap."),
            note(title: "C", body: "A benefit for everyone."),
            note(title: "D", body: "Ben's budgets."),
        ]

        #expect(notes.filter(parse("How many notes mention AI?").counts).map(\.title) == ["B"])
        #expect(notes.filter(parse("How many notes with Ben?").counts).map(\.title) == ["D"])
        #expect(notes.filter(parse("How many notes about the budget?").counts).map(\.title) == ["D"])
    }

    @Test func answersNone() {
        let question = parse("How many standups last week?")

        #expect(question.countAnswer(for: []) == "You didn't record any standups last week.")
    }

    @Test func scopeIgnoresCallsAndTopic() {
        let question = parse("How many calls about pricing in September?")
        let memo = note(title: "Voice memo")

        #expect(question.isInScope(memo))
        #expect(!question.counts(memo))
        #expect(!question.isInScope(note(created: Self.date(2026, 8, 1))))
    }
}
