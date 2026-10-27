import Foundation

/// Splits text into words, also where it's in a script written without spaces.
///
/// Chinese, Japanese, Thai and other scripts written without spaces can't be split into words
/// without a dictionary, so each of their characters is a word of its own, weighted by how many of
/// them a word typically takes.
enum TextTokens {
    struct Token: Equatable {
        /// The word, with the punctuation around it.
        var text: Substring
        /// Whether a space comes before it in the text; never for the first.
        var spaceBefore: Bool
        /// How much of a typical word this is: 1, or less for a single character of a script
        /// written without spaces.
        var weight: Double
    }

    /// The words of `text`: split at whitespace, and between the characters of a script written
    /// without spaces. Punctuation stays with the word before it, an opening quote or bracket
    /// with the word after it.
    static func tokens(in text: String) -> [Token] {
        var tokens: [Token] = []
        for chunk in text.split(whereSeparator: \.isWhitespace) {
            let spaceBefore = !tokens.isEmpty
            var start = chunk.startIndex
            // Where the word so far ends, if the next one starts here.
            var cut = chunk.startIndex
            // The weight of the word so far; `nil` until it has a letter or number.
            var weight: Double?
            var isUnspaced = false
            for index in chunk.indices {
                let character = chunk[index]
                let unspaced = unspacedWeight(of: character)
                guard unspaced != nil || character.isLetter || character.isNumber else {
                    if !isOpening(character) { cut = chunk.index(after: index) }
                    continue
                }
                if let weight, unspaced != nil || isUnspaced {
                    tokens.append(
                        Token(
                            text: chunk[start..<cut],
                            spaceBefore: spaceBefore && start == chunk.startIndex,
                            weight: weight
                        )
                    )
                    start = cut
                }
                weight = unspaced ?? 1
                isUnspaced = unspaced != nil
                cut = chunk.index(after: index)
            }
            tokens.append(
                Token(text: chunk[start...], spaceBefore: spaceBefore && start == chunk.startIndex, weight: weight ?? 1)
            )
        }
        return tokens
    }

    /// The weight of one character of a script written without spaces, or `nil` for any other
    /// character.
    static func unspacedWeight(of character: Character) -> Double? {
        guard let scalar = character.unicodeScalars.first else { return nil }
        switch scalar.value {
        // Chinese characters, also used in Japanese: a word is usually two.
        case 0x3005...0x3007, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x323AF:
            return 1 / 2
        // Japanese kana, then Thai, Lao, Myanmar and Khmer: a word is usually three or more.
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F,
            0x0E00...0x0EFF, 0x1000...0x109F, 0x1780...0x17FF:
            return 1 / 3
        default:
            return nil
        }
    }

    private static func isOpening(_ character: Character) -> Bool {
        switch character.unicodeScalars.first?.properties.generalCategory {
        case .openPunctuation, .initialPunctuation: true
        default: false
        }
    }
}
