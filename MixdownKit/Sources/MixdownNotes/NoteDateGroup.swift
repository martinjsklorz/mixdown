import Foundation

/// The section a note is listed under: the calendar day it was created.
public enum NoteDateGroup: Hashable, Sendable {
    case today
    case yesterday
    /// An earlier day, as its start.
    case day(Date)

    /// Dates in the future count as today.
    public init(date: Date, now: Date = .now, calendar: Calendar = .current) {
        let day = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: day, to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ...0: self = .today
        case 1: self = .yesterday
        default: self = .day(day)
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
