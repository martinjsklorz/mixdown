import Foundation

/// Names notes: after the summary's title where there is one, in the form of a call for calls, or
/// else after the time recorded.
public enum NoteTitle {
    /// The words put around a call's title, e.g. `Call about ` before it.
    private struct Wording {
        var prefix: String
        var suffix = ""
    }

    /// How a language words a call's title, without the app and with it.
    private struct CallWording {
        var plain: Wording
        /// With `{app}` where the app's name goes, e.g. `{app} call about `.
        var withApp: Wording

        init(prefix: String = "", suffix: String = "", appPrefix: String = "", appSuffix: String = "") {
            plain = Wording(prefix: prefix, suffix: suffix)
            withApp = Wording(prefix: appPrefix, suffix: appSuffix)
        }

        /// `withApp` with `app` in it, or `plain` without an app.
        func wording(for app: String?) -> Wording {
            guard let app else { return plain }
            return Wording(
                prefix: withApp.prefix.replacingOccurrences(of: "{app}", with: app),
                suffix: withApp.suffix.replacingOccurrences(of: "{app}", with: app)
            )
        }
    }

    private static let englishCallWording = CallWording(prefix: "Call about ", appPrefix: "{app} call about ")

    /// By ISO 639-1 code, for the languages Settings offers. The rest get English.
    private static let callWordings: [String: CallWording] = [
        "en": englishCallWording,
        "de": CallWording(prefix: "Anruf zu ", appPrefix: "{app}-Anruf zu "),
        "fr": CallWording(prefix: "Appel concernant ", appPrefix: "Appel {app} concernant "),
        "es": CallWording(prefix: "Llamada sobre ", appPrefix: "Llamada de {app} sobre "),
        "it": CallWording(prefix: "Chiamata su ", appPrefix: "Chiamata {app} su "),
        "pt": CallWording(prefix: "Chamada sobre ", appPrefix: "Chamada de {app} sobre "),
        "nl": CallWording(prefix: "Gesprek over ", appPrefix: "{app}-gesprek over "),
        // A colon, as "o" would need the topic in the locative case.
        "pl": CallWording(prefix: "Rozmowa: ", appPrefix: "Rozmowa przez {app}: "),
        "ja": CallWording(suffix: "についての通話", appSuffix: "についての{app}通話"),
        "zh": CallWording(prefix: "关于", suffix: "的通话", appPrefix: "关于", appSuffix: "的{app}通话"),
    ]

    /// - Parameters:
    ///   - summaryTitle: The summary's title; `nil` or blank without one.
    ///   - isCall: Whether to word the title as a call's.
    ///   - callApp: The name of the app the call was in, e.g. `Zoom`, to name in a call's title.
    ///     Browsers aren't named, as the call was in a website such as Google Meet.
    ///   - language: The language of the recording, e.g. `de` or `zh-Hans`, for a call's wording.
    static func make(
        for date: Date,
        summaryTitle: String?,
        isCall: Bool,
        callApp: String? = nil,
        language: String?
    ) -> String {
        var title = cleaned(summaryTitle ?? "")
        let callWording = isCall ? callWording(for: language) : nil
        let wording = callWording?.wording(for: callApp.flatMap(namedInTitle))
        if let callWording, let wording {
            // The model is asked to leave the wording out, but may not.
            title = cleaned(removing(callWording.plain, from: removing(wording, from: title)))
        }
        guard !title.isEmpty else { return "Recording \(date.formatted(date: .abbreviated, time: .shortened))" }
        guard let wording else { return title }
        return wording.prefix + title + wording.suffix
    }

    /// `app` if a call's title should name it: not blank, and not a browser.
    private static func namedInTitle(_ app: String) -> String? {
        let app = cleaned(app)
        guard !app.isEmpty, !CallApp.known.contains(where: { $0.name == app && $0.isBrowser }) else { return nil }
        return app
    }

    /// Whether `title` is worded as a call's, in any of the languages, e.g. "Anruf zu Budget".
    public static func isWordedAsCall(_ title: String) -> Bool {
        let title = cleaned(title)
        return callWordings.values.contains { wording in
            let stripped = removing(wording.plain, from: title)
            return stripped != title && !cleaned(stripped).isEmpty
        }
    }

    private static func callWording(for language: String?) -> CallWording {
        let code = language?.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)
        return code.flatMap { callWordings[$0] } ?? englishCallWording
    }

    /// `title` on one line, without the quotes or the full stop models like to put around one.
    private static func cleaned(_ title: String) -> String {
        title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”„«». "))
    }

    /// `title` without `wording`'s prefix and suffix, wherever it has them. A prefix ending in a
    /// Latin-style letter only counts before a space, so "Anruf zu" doesn't eat into "Anruf zum
    /// Abschluss"; Chinese and Japanese don't put spaces between words.
    private static func removing(_ wording: Wording, from title: String) -> String {
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
