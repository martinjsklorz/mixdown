import AppKit

/// Whether macOS's spell checker knows a word, so fuzzy vocabulary entries leave words that were
/// right alone, like "clause" near "Claude" or "marketing" near "Martin".
@MainActor
enum KnownWords {
    /// Whether `word` is spelled right in `language` or in any of the user's languages. Checking
    /// more of them leaves more words alone, which is the safe side to err on.
    static func contains(_ word: String, language: String?) -> Bool {
        let checker = NSSpellChecker.shared
        return languages(for: language).contains { language in
            let misspelled = checker.checkSpelling(
                of: word,
                startingAt: 0,
                language: language,
                wrap: false,
                inSpellDocumentWithTag: 0,
                wordCount: nil
            )
            return misspelled.location == NSNotFound
        }
    }

    /// `language`, as the spell checker names it, then the user's languages. `language` is a
    /// BCP 47 code like `"de"`, which matches the checker's `"de"` or `"de_DE"`.
    private static func languages(for language: String?) -> [String] {
        let checker = NSSpellChecker.shared
        var languages = checker.userPreferredLanguages
        if let language {
            let code = Locale.Language(identifier: language).languageCode?.identifier ?? language
            if let match = checker.availableLanguages.first(where: { $0 == code || $0.hasPrefix(code + "_") }) {
                languages.insert(match, at: 0)
            }
        }
        if languages.isEmpty { languages = [checker.language()] }
        var seen = Set<String>()
        return languages.filter { seen.insert($0).inserted }
    }
}
