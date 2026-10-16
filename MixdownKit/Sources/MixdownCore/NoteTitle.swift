import Foundation

/// Names notes: after the summary's title where there is one, in the form of a call for calls, or
/// else after the time recorded.
enum NoteTitle {
    /// The words put around a call's title, e.g. `Call about ` before it.
    struct CallWording: Equatable {
        var prefix: String
        var suffix = ""
    }

    static let englishCallWording = CallWording(prefix: "Call about ")

    /// By ISO 639-1 code, for the languages Settings offers. The rest get English.
    static let callWordings: [String: CallWording] = [
        "en": englishCallWording,
        "de": CallWording(prefix: "Anruf zu "),
        "fr": CallWording(prefix: "Appel concernant "),
        "es": CallWording(prefix: "Llamada sobre "),
        "it": CallWording(prefix: "Chiamata su "),
        "pt": CallWording(prefix: "Chamada sobre "),
        "nl": CallWording(prefix: "Gesprek over "),
        // A colon, as "o" would need the topic in the locative case.
        "pl": CallWording(prefix: "Rozmowa: "),
        "ja": CallWording(prefix: "", suffix: "についての通話"),
        "zh": CallWording(prefix: "关于", suffix: "的通话"),
    ]

    /// - Parameters:
    ///   - summaryTitle: The summary's title; `nil` or blank without one.
    ///   - isCall: Whether to word the title as a call's.
    ///   - language: The language of the recording, e.g. `de` or `zh-Hans`, for a call's wording.
    static func make(for date: Date, summaryTitle: String?, isCall: Bool, language: String?) -> String {
        var title = cleaned(summaryTitle ?? "")
        let wording = isCall ? callWording(for: language) : nil
        if let wording {
            // The model is asked to leave the wording out, but may not.
            title = cleaned(removing(wording, from: title))
        }
        guard !title.isEmpty else { return "Recording \(date.formatted(date: .abbreviated, time: .shortened))" }
        guard let wording else { return title }
        return wording.prefix + title + wording.suffix
    }

    static func callWording(for language: String?) -> CallWording {
        let code = language?.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)
        return code.flatMap { callWordings[$0] } ?? englishCallWording
    }

    /// `title` on one line, without the quotes or the full stop models like to put around one.
    static func cleaned(_ title: String) -> String {
        title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”„«». "))
    }

    /// `title` without `wording`'s prefix and suffix, wherever it has them. A prefix ending in a
    /// Latin-style letter only counts before a space, so "Anruf zu" doesn't eat into "Anruf zum
    /// Abschluss"; Chinese and Japanese don't put spaces between words.
    private static func removing(_ wording: CallWording, from title: String) -> String {
        var title = Substring(title)
        let prefix = wording.prefix.trimmingCharacters(in: .whitespaces)
        let rest = title.dropFirst(prefix.count)
        let endsWord = !(prefix.last?.isCased ?? false) || (rest.first?.isWhitespace ?? true)
        if !prefix.isEmpty, title.prefix(prefix.count).lowercased() == prefix.lowercased(), endsWord {
            title = rest
        }
        let suffix = wording.suffix.trimmingCharacters(in: .whitespaces)
        if !suffix.isEmpty, title.hasSuffix(suffix) {
            title = title.dropLast(suffix.count)
        }
        return String(title)
    }
}
