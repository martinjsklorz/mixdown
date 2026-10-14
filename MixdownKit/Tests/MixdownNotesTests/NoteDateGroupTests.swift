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
        #expect(group(date(10, 12)) == .previous7Days)
        #expect(group(date(10, 7)) == .previous7Days)
        #expect(group(date(10, 6)) == .previous30Days)
        #expect(group(date(9, 14)) == .previous30Days)
        #expect(group(date(9, 13)) == .month(9))
        #expect(group(date(1, 1, 0)) == .month(1))
        #expect(group(date(12, 31, year: 2025)) == .year(2025))
    }

    @Test func sectionsKeepOrderAndMergeRuns() {
        let notes = [date(10, 14, 2), date(10, 14, 1), date(10, 10), date(8, 1), date(7, 1)].map {
            NoteDocument(url: URL(filePath: "/\($0.timeIntervalSince1970).md"), contents: "", fileDate: $0)
        }

        let sections = NoteSection.sections(for: notes, now: date(10, 14, 3), calendar: calendar)

        #expect(sections.map(\.group) == [.today, .previous7Days, .month(8), .month(7)])
        #expect(sections.map(\.notes.count) == [2, 1, 1, 1])
    }
}
