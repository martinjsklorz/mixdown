import MixdownCore
import NaturalLanguage

/// Which language a transcript is in, for telling a model which language to write in.
public enum TranscriptLanguage {
    /// The language the transcript was made in, or else the one most of its text is in, as an ISO
    /// 639-1 code. Speech models that detect the language themselves don't report it.
    public static func code(of transcript: Transcript) -> String? {
        if let language = transcript.language, !language.isEmpty { return language }
        let recognizer = NLLanguageRecognizer()
        // Plenty to tell the language from, without reading an hour of text.
        recognizer.processString(String(transcript.text.prefix(4000)))
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        return language.rawValue
    }
}
