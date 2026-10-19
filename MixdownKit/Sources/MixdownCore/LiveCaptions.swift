import Foundation

/// The live text's lines translated into another language while recording, so a call in a
/// language the user doesn't speak can be followed as it happens. Lines are translated one at a
/// time, again whenever they've grown, and keep their previous translation meanwhile.
///
/// A line already in the target language has no translation. Neither does one that couldn't be
/// translated, until it grows. The note is translated afresh once the recording ends, from the
/// whole transcript.
public struct LiveCaptions: Sendable, Equatable {
    /// A line too short to tell its language yet is translated once it has this many words, or
    /// once it's ended.
    static let minimumWordCount = 3

    private struct Caption: Sendable, Equatable {
        /// The line's text as it was translated.
        var source: String
        /// `nil` for a line in the target language already, or that couldn't be translated.
        var translation: String?
    }

    /// The BCP 47 identifier of the language lines are translated into, e.g. `"de"`.
    public let language: String
    /// Why lines can't be translated, such as missing languages, until one is; else `nil`.
    public private(set) var problem: String?
    /// Advances whenever a translation changes.
    public private(set) var revision = 0

    /// By line ID.
    private var captions: [Int: Caption] = [:]

    public init(language: String) {
        self.language = language
    }

    /// The latest translation of `line`, if it has one. It may be of fewer words than the line
    /// has by now.
    public func translation(of line: LiveTranscript.Line) -> String? {
        captions[line.id]?.translation
    }

    /// Like `LiveTranscript.recentWords(_:)`, but translated. Lines in the target language, or
    /// that couldn't be translated, are shown as they are; lines not translated yet are left out.
    public func recentWords(_ count: Int, of transcript: LiveTranscript) -> [LiveTranscript.RecentWord] {
        transcript.recentWords(count) { line in
            guard let caption = captions[line.id] else { return nil }
            return caption.translation.map(Self.words(of:)) ?? line.words
        }
    }

    /// The lines of `transcript` to translate next, oldest first: those that have changed since
    /// they were translated and are long enough to tell their language.
    func linesToTranslate(in transcript: LiveTranscript) -> [LiveTranscript.Line] {
        let lines = transcript.lines
        return lines.indices.compactMap { index in
            let line = lines[index]
            let hasEnded = index < lines.count - 1
            guard line.words.count >= Self.minimumWordCount || hasEnded,
                captions[line.id]?.source != line.text
            else { return nil }
            return line
        }
    }

    /// Records the translation of `source`, a line's text, or that it's in the target language
    /// already, with `nil`.
    mutating func setTranslation(_ translation: String?, of source: String, forLine id: Int) {
        captions[id] = Caption(source: source, translation: translation)
        problem = nil
        revision += 1
    }

    /// Records that `source`, a line's text, couldn't be translated, so it isn't tried again
    /// until the line grows. `problem` is shown until a line is translated.
    mutating func setFailure(of source: String, forLine id: Int, problem: String?) {
        // Keeps the previous translation, which is still closer than none.
        captions[id] = Caption(source: source, translation: captions[id]?.translation)
        if let problem { self.problem = problem }
        revision += 1
    }

    private static func words(of text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
