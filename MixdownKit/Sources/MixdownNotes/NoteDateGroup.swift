import Foundation

/// The section a note is listed under, by creation date, like Apple Notes: Today, Yesterday,
/// Previous 7 Days, Previous 30 Days, then earlier months of this year, then years.
public enum NoteDateGroup: Hashable, Sendable {
    case today
    case yesterday
    case previous7Days
    case previous30Days
    /// An earlier month of the current year, 1–12.
    case month(Int)
    case year(Int)

    /// Dates in the future count as today.
    public init(date: Date, now: Date = .now, calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: today).day ?? 0
        switch days {
        case ...0: self = .today
        case 1: self = .yesterday
        case 2...7: self = .previous7Days
        case 8...30: self = .previous30Days
        default:
            let year = calendar.component(.year, from: date)
            self =
                year == calendar.component(.year, from: now)
                ? .month(calendar.component(.month, from: date))
                : .year(year)
        }
    }
}

/// A run of notes that share a `NoteDateGroup`.
public struct NoteSection: Sendable, Equatable, Identifiable {
    public var group: NoteDateGroup
    public var notes: [NoteDocument]

    public var id: NoteDateGroup { group }

    /// Groups notes that are already sorted newest first, keeping their order.
    public static func sections(
        for notes: [NoteDocument],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [NoteSection] {
        var sections: [NoteSection] = []
        for note in notes {
            let group = NoteDateGroup(date: note.createdAt, now: now, calendar: calendar)
            if sections.last?.group == group {
                sections[sections.count - 1].notes.append(note)
            } else {
                sections.append(NoteSection(group: group, notes: [note]))
            }
        }
        return sections
    }
}
