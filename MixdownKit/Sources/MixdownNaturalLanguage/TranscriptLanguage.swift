import MixdownCore
import NaturalLanguage

/// Which language a transcript or other text is in, for telling a model which language to write
/// in, or which language to translate or embed from.
public enum TranscriptLanguage {
    /// Plenty to tell the language from, without reading an hour of text.
    static let maxDetectedLength = 4000

    /// The language the transcript was made in, or else the one most of its text is in, as an ISO
    /// 639-1 code. Speech models that detect the language themselves don't report it.
    public static func code(of transcript: Transcript) -> String? {
        if let language = transcript.language, !language.isEmpty { return language }
        return code(of: transcript.text)
    }

    /// The language most of `text` is in, as an ISO 639-1 code, if it's at least
    /// `minimumConfidence` (0...1) sure.
    public static func code(of text: String, minimumConfidence: Double = 0) -> String? {
        language(of: text, minimumConfidence: minimumConfidence)?.rawValue
    }

    /// The language most of `text` is in, if it's at least `minimumConfidence` (0...1) sure.
    static func language(of text: String, minimumConfidence: Double = 0) -> NLLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(maxDetectedLength)))
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
            language != .undetermined, confidence >= minimumConfidence
        else { return nil }
        return language
    }
}
