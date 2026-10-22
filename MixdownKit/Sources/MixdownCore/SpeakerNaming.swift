import Foundation
import os

/// Names the speakers a `SpeakerDiarizer` told apart, such as "Speaker 2", after what's said in
/// the recording: people introduce themselves, and others address them by name. Whatever the
/// backend, a language model reads the transcript in pieces and guesses; the guesses are checked
/// against the transcript and counted here.
public enum SpeakerNaming {
    private static let logger = Logger(subsystem: "app.mixdown", category: "speakers")

    /// Most words of a name, e.g. "Anna Maria Schmidt".
    static let maximumNameWords = 4
    static let maximumNameLength = 40
    /// Answers that aren't names, compared case-insensitively.
    static let nonNames: Set<String> = [
        "unknown", "none", "null", "n/a", "na", "speaker", "unclear", "not mentioned", "nobody", "someone",
        "me", "you", "i", "others", "other", "everyone", "host", "moderator", "user",
    ]

    /// Instructions for naming speakers in one piece of a transcript.
    public static let instructions = """
        You find out the names of the people speaking in a transcript of a meeting or call. Each line \
        starts with the speaker's label, such as "Speaker 1", then a colon and what they said.
        Give a label's name only if the transcript makes clear who that speaker is:
        - they introduce themselves, as in "I'm Anna" or "Anna here";
        - someone asks them by name and they answer next, as in "Anna, what do you think?" followed by \
        their line;
        - someone greets or thanks them by name as they start or finish speaking.
        A name a speaker says is usually someone else's, not their own. Only use names that appear in \
        the transcript, written as they appear there. Leave out every label you're not sure about: \
        leaving one out is much better than a wrong name.
        """

    /// The prompt for one piece of transcript, `Speaker: text` lines, asking about `speakers`.
    public static func prompt(for text: String, speakers: [String]) -> String {
        "Labels to name: \(speakers.map { "\"\($0)\"" }.joined(separator: ", "))\n\nTranscript:\n\(text)"
    }

    /// How to answer, appended to `instructions` for models without structured output.
    public static let jsonFormat = """
        Answer with only a JSON object that maps each label you could name to the person's name, and \
        no other text, e.g. {"Speaker 1": "Anna", "Speaker 3": "Tom Becker"}. Answer {} if you can't \
        name any.
        """

    /// The guesses in a model's answer to `jsonFormat`, or `nil` if it holds no JSON object.
    public static func guesses(fromJSON answer: String) -> [String: String]? {
        guard let object = JSONSummary.jsonObject(in: answer) else { return nil }
        var guesses: [String: String] = [:]
        for (label, value) in object {
            if let name = value as? String { guesses[label] = name }
        }
        return guesses
    }

    /// Names for `speakers`, labels in `transcript`, by label. Labels without a name the model
    /// was sure enough about are left out.
    ///
    /// The transcript is handed to `step` in pieces of at most `maxTokens` (see
    /// `ChunkedSummarizer.estimatedTokens(in:)`), each with the labels it has, shortened to
    /// "Speaker 1", "Speaker 2" and so on: models shorten labels such as "Others (Speaker 2)" in
    /// their answers anyway. A guess counts only if the name is said in the piece, and it's spelled
    /// as it's said there. The name guessed in most pieces wins, and a name two labels got goes to
    /// the one that got it more often. A piece that fails is left out; if all of them do, the first
    /// error is thrown.
    ///
    /// - Parameter step: Returns names by label for the piece's lines; called one at a time.
    public static func names(
        for speakers: [String],
        in transcript: Transcript,
        maxTokens: Int,
        step: (_ text: String, _ speakers: [String]) async throws -> [String: String]
    ) async throws -> [String: String] {
        guard !speakers.isEmpty else { return [:] }
        let aliases = aliases(for: speakers, among: transcript.speakers)
        let labels = Dictionary(aliases.map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var shown = transcript
        for index in shown.segments.indices {
            if let speaker = shown.segments[index].speaker, let alias = aliases[speaker] {
                shown.segments[index].speaker = alias
            }
        }
        let lines = ChunkedSummarizer.lines(of: shown)
        let pieces = ChunkedSummarizer.groups(of: lines, maxTokens: maxTokens, separator: "\n")
        // Labels, such as the user's own, aren't names to give.
        let otherLabels = Set((transcript.speakers + aliases.values).map { $0.lowercased() })

        var votes: [String: [String: Int]] = [:]
        var spellings: [String: String] = [:]
        var firstError: (any Error)?
        var anySucceeded = false
        for piece in pieces {
            try Task.checkCancellation()
            let text = piece.joined(separator: "\n")
            let asked = speakers.compactMap { aliases[$0] }.filter { alias in
                piece.contains { $0.hasPrefix("\(alias): ") }
            }
            guard !asked.isEmpty else { continue }
            let guesses: [String: String]
            do {
                guesses = try await step(text, asked)
                anySucceeded = true
            } catch {
                if error is CancellationError || Task.isCancelled { throw error }
                logger.error("Leaving a piece out of naming speakers: \(error, privacy: .public)")
                firstError = firstError ?? error
                continue
            }
            var kept = 0
            for (answered, guess) in guesses {
                guard let alias = matchingLabel(answered, among: asked), let speaker = labels[alias],
                    let name = name(guess, in: text), !otherLabels.contains(name.lowercased())
                else { continue }
                let key = name.lowercased()
                spellings[key] = spellings[key] ?? name
                votes[speaker, default: [:]][key, default: 0] += 1
                kept += 1
            }
            logger.info("Kept \(kept) of \(guesses.count) names guessed for \(asked.count) speakers")
        }
        if !anySucceeded, let firstError { throw firstError }

        // Each label's most frequent name; ties go to the name that sorts first, for a stable result.
        var best: [(label: String, name: String, count: Int)] = []
        for label in speakers {
            guard let counts = votes[label],
                let top = counts.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key })
            else { continue }
            best.append((label, top.key, top.value))
        }
        var names: [String: String] = [:]
        var taken = Set<String>()
        for guess in best.sorted(by: { $0.count > $1.count }) where taken.insert(guess.name).inserted {
            names[guess.label] = spellings[guess.name] ?? guess.name
        }
        return names
    }

    /// `transcript` with each speaker in `names` renamed.
    public static func applying(_ names: [String: String], to transcript: Transcript) -> Transcript {
        guard !names.isEmpty else { return transcript }
        var transcript = transcript
        for index in transcript.segments.indices {
            if let speaker = transcript.segments[index].speaker, let name = names[speaker] {
                transcript.segments[index].speaker = name
            }
        }
        return transcript
    }

    /// A short label for each of `speakers`: "Speaker 1", "Speaker 2" and so on, in order. The
    /// labels themselves if one of those is taken by another of `labels`.
    static func aliases(for speakers: [String], among labels: [String]) -> [String: String] {
        let aliases = speakers.indices.map { "Speaker \($0 + 1)" }
        let others = Set(labels.filter { !speakers.contains($0) }.map { $0.lowercased() })
        let isTaken = aliases.contains { others.contains($0.lowercased()) }
        return Dictionary(zip(speakers, isTaken ? speakers : aliases), uniquingKeysWith: { first, _ in first })
    }

    /// The one of `asked` that a model meant by `answered`: the same apart from case, quotes and
    /// spaces, or with the same "Speaker N" in it, as in "Others (Speaker 2)" for "Speaker 2".
    static func matchingLabel(_ answered: String, among asked: [String]) -> String? {
        let key = normalized(answered)
        if let exact = asked.first(where: { normalized($0) == key }) { return exact }
        guard let match = key.firstMatch(of: /speaker\s*(\d+)/) else { return nil }
        let number = "speaker \(match.output.1)"
        let matching = asked.filter { normalized($0) == number || normalized($0).hasSuffix("(\(number))") }
        return matching.count == 1 ? matching[0] : nil
    }

    private static func normalized(_ label: String) -> String {
        label.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”„‘’*:").union(.whitespacesAndNewlines))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }

    /// Lowercase words that may be part of a name, as in "Ludwig van Beethoven".
    static let nameParticles: Set<String> = [
        "van", "von", "der", "den", "de", "da", "di", "del", "della", "du", "la", "le", "ten", "ter", "bin", "al", "el",
    ]

    /// `guess` spelled as `text` says it, or `nil` if it isn't a name said there, so a model can't
    /// make one up or pass off a description as one.
    static func name(_ guess: String, in text: String) -> String? {
        guard let cleaned = cleanedName(guess) else { return nil }
        // Scripts without capitals or spaces between words, such as Chinese, can only be looked for.
        guard cleaned.contains(where: { $0.isUppercase || $0.isLowercase }) else {
            return text.range(of: cleaned) != nil ? cleaned : nil
        }
        let said = words(in: text)
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var spelled: [String] = []
        for word in cleaned.split(separator: " ") {
            let matches = said.filter { $0.compare(word, options: options) == .orderedSame }
            // Capitalized where the transcript has it both ways.
            guard let match = matches.first(where: { $0.first?.isUppercase == true }) ?? matches.first else {
                return nil
            }
            spelled.append(match)
        }
        // Names are capitalized, apart from particles.
        guard spelled.first?.first?.isLowercase == false,
            spelled.allSatisfy({ $0.first?.isLowercase == false || nameParticles.contains($0.lowercased()) })
        else { return nil }
        return spelled.joined(separator: " ")
    }

    /// The words of `text`, with a possessive "'s" also taken off.
    private static func words(in text: String) -> [String] {
        let words = text.split { !($0.isLetter || $0 == "'" || $0 == "’" || $0 == "-") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'’-")) }
            .filter { !$0.isEmpty }
        return words + words.compactMap { word in
            word.hasSuffix("'s") || word.hasSuffix("’s") ? String(word.dropLast(2)) : nil
        }
    }

    /// `guess` without quotes, a trailing period or extra spaces, or `nil` if it can't be a name,
    /// such as a description ("Chris, the Nemotron voice") or a label.
    static func cleanedName(_ guess: String) -> String? {
        let trimmed = CharacterSet(charactersIn: "\"'“”„‘’*.,:;").union(.whitespacesAndNewlines)
        let name = guess
            .trimmingCharacters(in: trimmed)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let words = name.split(separator: " ")
        guard !name.isEmpty, name.count <= maximumNameLength, words.count <= maximumNameWords,
            !nonNames.contains(name.lowercased()),
            !name.lowercased().hasPrefix("speaker"),
            // Names don't have digits; labels and times do.
            !name.contains(where: \.isNumber),
            !name.contains(where: { ",;:!?()[]{}/\\\"“”".contains($0) }),
            name.first?.isLetter == true
        else { return nil }
        return name
    }
}
