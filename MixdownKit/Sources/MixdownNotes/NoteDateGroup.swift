import Foundation

/// The section a note is listed under, like Apple Notes: today, the seven days before, then
/// each earlier month.
public enum NoteDateGroup: Hashable, Sendable {
    case today
    /// The seven calendar days before today.
    case previousSevenDays
    /// An earlier month, as its first day's start.
    case month(Date)

    /// Dates in the future count as today.
    public init(date: Date, now: Date = .now, calendar: Calendar = .current) {
        let day = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: day, to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ...0: self = .today
        case 1...7: self = .previousSevenDays
        default: self = .month(calendar.dateInterval(of: .month, for: day)?.start ?? day)
        }
    }
}

/// A run of notes listed under one heading: the pinned notes, or notes that share a
/// `NoteDateGroup`.
public struct NoteSection: Sendable, Equatable, Identifiable {
    public enum Group: Hashable, Sendable {
        case pinned
        case date(NoteDateGroup)
    }

    public var group: Group
    public var notes: [NoteDocument]

    public var id: Group { group }

    /// The pinned notes first, then the others grouped by date. `notes` must already be sorted
    /// newest first; each section keeps their order.
    public static func sections(
        for notes: [NoteDocument],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [NoteSection] {
        let pinned = notes.filter(\.isPinned)
        var sections = pinned.isEmpty ? [] : [NoteSection(group: .pinned, notes: pinned)]
        for note in notes where !note.isPinned {
            let group = Group.date(NoteDateGroup(date: note.createdAt, now: now, calendar: calendar))
            if sections.last?.group == group {
                sections[sections.count - 1].notes.append(note)
            } else {
                sections.append(NoteSection(group: group, notes: [note]))
            }
        }
        return sections
    }
}
