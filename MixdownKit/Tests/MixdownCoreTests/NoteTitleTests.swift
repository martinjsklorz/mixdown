import Foundation
import Testing

@testable import MixdownCore

struct NoteTitleTests {
    private let date = Fixtures.startDate

    private func title(_ summaryTitle: String?, isCall: Bool = false, language: String? = nil) -> String {
        NoteTitle.make(for: date, summaryTitle: summaryTitle, isCall: isCall, language: language)
    }

    @Test func fallsBackToDate() {
        let dated = title(nil)
        #expect(dated.hasPrefix("Recording "))
        #expect(title(" \n ", isCall: true) == dated)
        #expect(title("Anruf zu ", isCall: true, language: "de") == dated)
    }

    @Test func cleansSummaryTitle() {
        #expect(title("“Hiring a\ndesigner.”") == "Hiring a designer")
    }

    @Test func wordsCallsInTheirLanguage() {
        #expect(title("Q3 budget", isCall: true) == "Call about Q3 budget")
        #expect(title("Budgetplanung Q3", isCall: true, language: "de") == "Anruf zu Budgetplanung Q3")
        #expect(title("Budgetplanung Q3", isCall: true, language: "de-DE") == "Anruf zu Budgetplanung Q3")
        #expect(title("预算", isCall: true, language: "zh-Hans") == "关于预算的通话")
        #expect(title("予算", isCall: true, language: "ja") == "予算についての通話")
        // Languages without a wording get English.
        #expect(title("Бюджет", isCall: true, language: "ru") == "Call about Бюджет")
        // Not a call: no wording.
        #expect(title("Budgetplanung Q3", language: "de") == "Budgetplanung Q3")
    }

    @Test func doesNotRepeatWordingTheModelAdded() {
        #expect(title("call about \"Q3 budget\"", isCall: true) == "Call about Q3 budget")
        #expect(title("Anruf zu Budget", isCall: true, language: "de") == "Anruf zu Budget")
        #expect(title("关于预算的通话", isCall: true, language: "zh") == "关于预算的通话")
        // Only a whole word counts.
        #expect(title("Anruf zum Abschluss", isCall: true, language: "de") == "Anruf zu Anruf zum Abschluss")
        // Not a call: the title is kept as it is.
        #expect(title("Call about Q3 budget") == "Call about Q3 budget")
    }
}
