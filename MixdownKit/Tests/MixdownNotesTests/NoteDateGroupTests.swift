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

    @Test func groupsByTodayPreviousSevenDaysThenMonth() {
        #expect(group(date(10, 15)) == .today)
        #expect(group(date(10, 14, 0)) == .today)
        #expect(group(date(10, 13, 23)) == .previousSevenDays)
        #expect(group(date(10, 7, 0)) == .previousSevenDays)
        #expect(group(date(10, 6, 23)) == .month(date(10, 1, 0)))
        #expect(group(date(10, 1, 0)) == .month(date(10, 1, 0)))
        #expect(group(date(9, 30, 23)) == .month(date(9, 1, 0)))
        #expect(group(date(1, 1)) == .month(date(1, 1, 0)))
        #expect(group(date(12, 31, year: 2025)) == .month(date(12, 1, 0, year: 2025)))
    }

    @Test func sectionsKeepOrderAndMergeRuns() {
        let notes = [
            date(10, 14, 2), date(10, 14, 1), date(10, 12, 18), date(10, 8, 9), date(10, 2), date(9, 20), date(8, 1),
        ].map {
            NoteDocument(url: URL(filePath: "/\($0.timeIntervalSince1970).md"), contents: "", fileDate: $0)
        }

        let sections = NoteSection.sections(for: notes, now: date(10, 14, 3), calendar: calendar)

        #expect(
            sections.map(\.group) == [
                .date(.today), .date(.previousSevenDays), .date(.month(date(10, 1, 0))),
                .date(.month(date(9, 1, 0))), .date(.month(date(8, 1, 0))),
            ]
        )
        #expect(sections.map(\.notes.count) == [2, 2, 1, 1, 1])
    }

    @Test func pinnedNotesComeFirstInTheirOwnSection() {
        let notes = [(date(10, 14, 2), false), (date(10, 14, 1), true), (date(10, 12), false), (date(8, 1), true)]
            .map { date, isPinned in
                var note = NoteDocument(
                    url: URL(filePath: "/\(date.timeIntervalSince1970).md"),
                    contents: "",
                    fileDate: date
                )
                note.isPinned = isPinned
                return note
            }

        let sections = NoteSection.sections(for: notes, now: date(10, 14, 3), calendar: calendar)

        #expect(sections.map(\.group) == [.pinned, .date(.today), .date(.previousSevenDays)])
        #expect(sections[0].notes == [notes[1], notes[3]])
    }
}
