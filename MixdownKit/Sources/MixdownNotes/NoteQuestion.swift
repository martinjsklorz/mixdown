import Foundation
import MixdownCore

/// What a chat question asks of the notes, as far as Mixdown can tell without a model: whether it
/// asks how many notes there are, and which notes it's about by date, kind and topic. Mixdown
/// counts those notes itself, so the numbers are exact; a language model would guess.
///
/// Reads English and German, e.g. "How many 1:1s did I have in September?" or "Wie viele Anrufe
/// hatte ich letzte Woche?".
public struct NoteQuestion: Sendable, Equatable {
    /// A kind of recording a question can ask about.
    public enum Kind: String, Sendable, CaseIterable {
        case oneOnOne
        case standup
        case clientCall
        case call

        /// The id of the built-in template that makes a note this kind, if one does.
        var templateID: String? {
            switch self {
            case .oneOnOne: SummaryTemplate.oneOnOne.id
            case .standup: SummaryTemplate.standup.id
            case .clientCall: SummaryTemplate.clientCall.id
            case .call: nil
            }
        }

        /// For answers, e.g. "1:1" and "1:1s".
        var names: (singular: String, plural: String) {
            switch self {
            case .oneOnOne: ("1:1", "1:1s")
            case .standup: ("standup", "standups")
            case .clientCall: ("client call", "client calls")
            case .call: ("call", "calls")
            }
        }
    }

    /// Whether the question asks how many notes there are, e.g. "how many" or "wie viele".
    public var asksForCount = false
    /// The notes the question is about were recorded in this time. `nil` for any time.
    public var dates: DateInterval?
    /// How the answer puts `dates`, e.g. "in September 2026" or "last week".
    public var datePhrase: String?
    public var kind: Kind?
    /// Words a note has to contain to count, e.g. `["budget"]` for "how many calls mentioned the
    /// budget?". Only read for questions that ask for a count.
    public var topic: [String] = []
    /// The question without the part saying when, to find the lines that answer it.
    public var searchText: String

    // MARK: Parsing

    /// Reads `question`, asked at `now`. Dates without a year are the latest such date up to
    /// `now`: in October, "September" is this year's and "November" last year's.
    public static func parse(_ question: String, now: Date = .now, calendar: Calendar = .current) -> NoteQuestion {
        var rest = question
        var parsed = NoteQuestion(searchText: question)

        if let range = rest.firstRange(of: Patterns.count) {
            parsed.asksForCount = true
            rest.replaceSubrange(range, with: " ")
        }
        if let (range, dates, phrase) = dateRange(in: rest, now: now, calendar: calendar) {
            parsed.dates = dates
            parsed.datePhrase = phrase
            rest.replaceSubrange(range, with: " ")
            // Only the date goes; the kind and topic still tell which lines answer the question.
            var searchText = question
            if let searchRange = dateRange(in: question, now: now, calendar: calendar)?.range {
                searchText.replaceSubrange(searchRange, with: " ")
            }
            parsed.searchText = searchText
        }
        parsed.searchText = singleLine(parsed.searchText)
        for (kind, pattern) in Patterns.kinds {
            guard let range = rest.firstRange(of: pattern) else { continue }
            parsed.kind = kind
            rest.replaceSubrange(range, with: " ")
            break
        }
        if parsed.asksForCount, let marker = rest.firstMatch(of: Patterns.topicMarker) {
            parsed.topic = NoteChatText.words(in: rest[marker.range.upperBound...])
                .filter { !NoteChatText.isStopword($0) && $0.wholeMatch(of: Patterns.genericNoun) == nil }
        }
        return parsed
    }

    // MARK: Matching

    /// Whether the question is about `note`, by date and kind, to look for answers in. A `call`
    /// isn't held to, as "call" is a verb too.
    public func isInScope(_ note: NoteDocument) -> Bool {
        isInDates(note) && (kind == .call || kind.map { Self.note(note, is: $0) } ?? true)
    }

    /// Whether `note` counts towards the answer: it's from `dates`, of `kind` and contains every
    /// word of `topic`.
    public func counts(_ note: NoteDocument) -> Bool {
        isInDates(note) && (kind.map { Self.note(note, is: $0) } ?? true)
            && topic.allSatisfy { note.title.localizedStandardContains($0) || note.body.localizedStandardContains($0) }
    }

    private func isInDates(_ note: NoteDocument) -> Bool {
        dates.map { $0.start <= note.createdAt && note.createdAt < $0.end } ?? true
    }

    /// Whether `note` is of `kind`: summarized with its template, titled as one, or for calls,
    /// recorded as one.
    static func note(_ note: NoteDocument, is kind: Kind) -> Bool {
        switch kind {
        case .call:
            return note.isCall
        case .oneOnOne, .standup, .clientCall:
            if let template = note.template { return template == kind.templateID }
            return Patterns.kinds.first { $0.kind == kind }.map { note.title.firstRange(of: $0.pattern) != nil }
                ?? false
        }
    }

    // MARK: Answering

    /// The answer to a question that asks for a count, given the notes that `counts(_:)`, as
    /// Markdown. E.g. "You recorded **4** 1:1s in September 2026, 3 h 12 min in all."
    public func countAnswer(for notes: [NoteDocument]) -> String {
        let names = kind?.names ?? (singular: "note", plural: "notes")
        let noun = notes.count == 1 ? names.singular : names.plural
        var description = noun
        if !topic.isEmpty {
            let words = topic.map { "“\($0)”" }.joined(separator: " and ")
            description += notes.count == 1 ? " that mentions \(words)" : " that mention \(words)"
        }
        if let datePhrase { description += " \(datePhrase)" }

        guard !notes.isEmpty else { return "You didn't record any \(description)." }
        let total = notes.compactMap(\.duration).reduce(0, +)
        let length = total >= 60 ? ", \(Self.hoursAndMinutes(total)) in all" : ""
        return "You recorded **\(notes.count)** \(description)\(length)."
    }

    /// E.g. `3 h 12 min`, or `45 min` under an hour.
    static func hoursAndMinutes(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }

    // MARK: Dates

    /// The first date range `text` names, where it says so, and how an answer puts it.
    private static func dateRange(
        in text: String,
        now: Date,
        calendar: Calendar
    ) -> (range: Range<String.Index>, dates: DateInterval, phrase: String)? {
        guard let today = calendar.dateInterval(of: .day, for: now) else { return nil }
        var found: [(range: Range<String.Index>, dates: DateInterval, phrase: String)] = []

        if let match = text.firstMatch(of: Patterns.today) {
            found.append((match.range, today, "today"))
        }
        if let match = text.firstMatch(of: Patterns.yesterday),
            let day = calendar.date(byAdding: .day, value: -1, to: now),
            let yesterday = calendar.dateInterval(of: .day, for: day)
        {
            found.append((match.range, yesterday, "yesterday"))
        }
        if let match = text.firstMatch(of: Patterns.thisUnit), let unit = Patterns.unit(String(match.output.1)),
            let interval = calendar.dateInterval(of: unit, for: now)
        {
            found.append((match.range, interval, "this \(Patterns.unitName(unit))"))
        }
        if let match = text.firstMatch(of: Patterns.lastUnit), let unit = Patterns.unit(String(match.output.2)) {
            let name = Patterns.unitName(unit)
            let isRolling = match.output.1.lowercased() == "past"
            if isRolling, let start = calendar.date(byAdding: unit, value: -1, to: now) {
                found.append((match.range, DateInterval(start: start, end: today.end), "in the past \(name)"))
            } else if let previous = calendar.date(byAdding: unit, value: -1, to: now),
                let interval = calendar.dateInterval(of: unit, for: previous)
            {
                found.append((match.range, interval, "last \(name)"))
            }
        }
        if let match = text.firstMatch(of: Patterns.lastCount),
            let count = Int(match.output.2), count > 0,
            let unit = Patterns.unit(String(match.output.3))
        {
            // Counting today as one of the days.
            let start =
                unit == .day
                ? calendar.date(byAdding: .day, value: 1 - count, to: today.start)
                : calendar.date(byAdding: unit, value: -count, to: now)
            if let start {
                let name = Patterns.unitName(unit) + (count == 1 ? "" : "s")
                found.append((match.range, DateInterval(start: start, end: today.end), "in the last \(count) \(name)"))
            }
        }
        if let month = Patterns.month(in: text) {
            let year =
                month.year
                ?? calendar.component(.year, from: now)
                - (calendar.component(.month, from: now) < month.month ? 1 : 0)
            if let start = calendar.date(from: DateComponents(year: year, month: month.month, day: 1)),
                let interval = calendar.dateInterval(of: .month, for: start)
            {
                let phrase = "\(Self.monthName(month.month)) \(year)"
                if month.isSince {
                    found.append(
                        (month.range, DateInterval(start: start, end: max(today.end, start)), "since \(phrase)")
                    )
                } else {
                    found.append((month.range, interval, "in \(phrase)"))
                }
            }
        }
        if let match = text.firstMatch(of: Patterns.year), let year = Int(match.output.2) {
            let isSince = match.output.1.map { ["since", "seit"].contains($0.lowercased()) } ?? false
            if let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
                let interval = calendar.dateInterval(of: .year, for: start)
            {
                found.append(
                    isSince
                        ? (match.range, DateInterval(start: start, end: max(today.end, start)), "since \(year)")
                        : (match.range, interval, "in \(year)")
                )
            }
        }
        // The one said first; a month's year isn't taken for a year of its own.
        return found.min { $0.range.lowerBound < $1.range.lowerBound }
    }

    private static func monthName(_ month: Int) -> String {
        var english = Calendar(identifier: .gregorian)
        english.locale = Locale(identifier: "en_US_POSIX")
        return english.monthSymbols[month - 1]
    }

    private static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

// MARK: - Patterns

/// The phrases `NoteQuestion` looks for, in English and German. All ignore case.
private enum Patterns {
    nonisolated(unsafe) static let count =
        #/\b(?:how\s+many|how\s+often|number\s+of|count|wie\s+viele|wie\s+oft|anzahl)\b/#.ignoresCase()

    nonisolated(unsafe) static let kinds: [(kind: NoteQuestion.Kind, pattern: Regex<Substring>)] = [
        (
            .clientCall,
            #/\b(?:client|customer)[- ]?(?:calls?|meetings?)\b|\bkunden(?:gespräch|gesprach|termin|call|anruf|telefonat)(?:e|en|s)?\b/#
                .ignoresCase()
        ),
        (
            .oneOnOne,
            #/(?:^|[^\w:])1\s*:\s*1(?:'?s)?(?![\w:])|\b1[- ]?on[- ]?1s?\b|\bone[- ]on[- ]ones?\b|\b(?:einzel|mitarbeiter)gespr(?:ä|a|ae)ch(?:e|en)?\b/#
                .ignoresCase()
        ),
        (.standup, #/\b(?:daily\s+)?(?:stand[- ]?ups?|scrums?)\b|\bdail(?:y|ys|ies)\b/#.ignoresCase()),
        (.call, #/\b(?:(?:phone|video)\s+)?calls?\b|\banrufe?n?\b|\btelefonate?n?\b/#.ignoresCase()),
    ]

    /// Words for notes in general, which don't narrow a count down.
    nonisolated(unsafe) static let genericNoun =
        #/notes?|recordings?|meetings?|memos?|sessions?|notizen?|aufnahmen?|besprechung(?:en)?|termine?n?/#
        .ignoresCase()

    /// Says that what follows is what the counted notes are about.
    nonisolated(unsafe) static let topicMarker =
        #/\b(?:mention(?:s|ed|ing)?|about|regarding|concerning|with|(?:ü|u|ue)ber|zu[mr]?|mit|erw(?:ä|a|ae)hn(?:t|en|ten))\b/#
        .ignoresCase()

    nonisolated(unsafe) static let today = #/\b(?:today|heute)\b/#.ignoresCase()
    nonisolated(unsafe) static let yesterday = #/\b(?:yesterday|gestern)\b/#.ignoresCase()
    nonisolated(unsafe) static let thisUnit =
        #/\b(?:this|current|diese[nmrs]?|aktuelle[nmrs]?)\s+(week|month|year|woche|monat|jahr)\b/#.ignoresCase()
    nonisolated(unsafe) static let lastUnit =
        #/\b(last|previous|past|letzte[nmrs]?|vorige[nmrs]?|vergangene[nmrs]?)\s+(week|month|year|woche|monat|jahr)\b/#
        .ignoresCase()
    nonisolated(unsafe) static let lastCount =
        #/\b(last|previous|past|letzte[nmrs]?|vergangene[nmrs]?)\s+(\d{1,3})\s+(days?|weeks?|months?|tagen?|wochen|monaten?)\b/#
        .ignoresCase()
    nonisolated(unsafe) static let year = #/\b(?:(in|im|during|since|seit)\s+)?((?:19|20)\d{2})\b/#.ignoresCase()

    static func unit(_ word: String) -> Calendar.Component? {
        switch word.lowercased() {
        case "day", "days", "tag", "tage", "tagen": .day
        case "week", "weeks", "woche", "wochen": .weekOfYear
        case "month", "months", "monat", "monate", "monaten": .month
        case "year", "jahr": .year
        default: nil
        }
    }

    static func unitName(_ unit: Calendar.Component) -> String {
        switch unit {
        case .day: "day"
        case .weekOfYear: "week"
        case .month: "month"
        default: "year"
        }
    }

    // MARK: Months

    struct MonthMatch {
        var range: Range<String.Index>
        var month: Int
        var year: Int?
        var isSince: Bool
    }

    /// Month names in English and German, full and short, by number from 1. Names that are
    /// common words too ("may", "march", "jan") only count after a preposition or before a year.
    static let monthNames: [(name: String, month: Int, isAmbiguous: Bool)] = {
        var names: [String: Int] = [:]
        for identifier in ["en_US_POSIX", "de_DE"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = Locale(identifier: identifier)
            for symbols in [calendar.monthSymbols, calendar.shortMonthSymbols, calendar.standaloneMonthSymbols] {
                for (index, symbol) in symbols.enumerated() {
                    let name = symbol.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    if name.count >= 3 { names[name] = index + 1 }
                }
            }
        }
        names["sept"] = 9
        // "März" as typed without an umlaut.
        names["marz"] = 3
        names["maerz"] = 3
        let ambiguous: Set = ["may", "mai", "march", "mar", "jan", "jun", "jul", "aug", "dec", "dez"]
        // Longest first, so "september" wins over "sep".
        return names.map { ($0.key, $0.value, ambiguous.contains($0.key) || $0.key.count <= 3) }
            .sorted { $0.name.count > $1.name.count }
    }()

    /// `nil` only if the names broke it, which tests would catch.
    nonisolated(unsafe) static let monthPattern: Regex<AnyRegexOutput>? = {
        let names = monthNames.map { NSRegularExpression.escapedPattern(for: $0.name) }.joined(separator: "|")
        return try? Regex(
            #"\b(?:(in|im|during|since|for|of|seit|von|ab)\s+)?(?:the\s+month\s+of\s+)?("#
                + names + #")\.?(?:\s+((?:19|20)\d{2}))?\b"#
        ).ignoresCase()
    }()

    static func month(in text: String) -> MonthMatch? {
        guard let monthPattern else { return nil }
        for match in text.matches(of: monthPattern) {
            let preposition = match.output[1].substring.map { $0.lowercased() }
            guard let name = match.output[2].substring?.lowercased(),
                let entry = monthNames.first(where: { $0.name == name })
            else { continue }
            let year = match.output[3].substring.flatMap { Int($0) }
            if entry.isAmbiguous && preposition == nil && year == nil { continue }
            return MonthMatch(
                range: match.range,
                month: entry.month,
                year: year,
                isSince: ["since", "seit", "ab"].contains(preposition ?? "")
            )
        }
        return nil
    }
}
