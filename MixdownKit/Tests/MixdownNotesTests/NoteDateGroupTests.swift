import Foundation
import MixdownNotes
import Testing

struct NoteDateGroupTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .gmt
        return calendar
    }()

    private func date(_ month: Int, _ day: Int, _ hour: Int = 12, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)) ?? .distantPast
    }

    private func group(_ date: Date) -> NoteDateGroup {
        NoteDateGroup(date: date, now: self.date(10, 14, 3), calendar: calendar)
    }

    @Test func groupsByCalendarDay() {
        #expect(group(date(10, 15)) == .today)
        #expect(group(date(10, 14, 0)) == .today)
        #expect(group(date(10, 13, 23)) == .yesterday)
        #expect(group(date(10, 13, 0)) == .yesterday)
        #expect(group(date(10, 12, 23)) == .day(date(10, 12, 0)))
        #expect(group(date(10, 12, 0)) == .day(date(10, 12, 0)))
        #expect(group(date(1, 1)) == .day(date(1, 1, 0)))
        #expect(group(date(12, 31, year: 2025)) == .day(date(12, 31, 0, year: 2025)))
    }

    @Test func sectionsKeepOrderAndMergeRuns() {
        let notes = [date(10, 14, 2), date(10, 14, 1), date(10, 10, 18), date(10, 10, 9), date(8, 1)].map {
            NoteDocument(url: URL(filePath: "/\($0.timeIntervalSince1970).md"), contents: "", fileDate: $0)
        }

        let sections = NoteSection.sections(for: notes, now: date(10, 14, 3), calendar: calendar)

        #expect(sections.map(\.group) == [.today, .day(date(10, 10, 0)), .day(date(8, 1, 0))])
        #expect(sections.map(\.notes.count) == [2, 2, 1])
    }
}
