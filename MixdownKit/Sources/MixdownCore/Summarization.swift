import Foundation

/// The shape of a summary, chosen per kind of recording.
public enum SummaryTemplate: String, Sendable, Codable, CaseIterable, Identifiable {
    /// An overview, key points and action items, for any recording.
    case general
    case oneOnOne
    case standup
    case clientCall

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .general: "General"
        case .oneOnOne: "1:1"
        case .standup: "Standup"
        case .clientCall: "Client Call"
        }
    }

    /// Whether summaries have the fixed sections TL;DR, Decisions, Action Items and Open
    /// Questions, instead of an overview and key points. All but `general` do; they differ in what
    /// the summarizer looks out for.
    public var hasFixedSections: Bool { self != .general }
}

/// What a summarizer makes of a transcript. Any part may be empty.
public struct NoteSummary: Sendable, Codable, Equatable {
    /// The template the summary was made with, which decides its sections.
    public var template: SummaryTemplate
    /// The topic in a few words, to name the note after.
    public var title: String
    /// A few sentences on what the recording was about; the TL;DR of templates with fixed
    /// sections.
    public var overview: String
    /// Only made with the `general` template.
    public var keyPoints: [String]
    /// Only made with templates with fixed sections.
    public var decisions: [String]
    /// Tasks someone agreed to do, naming the person where the transcript does.
    public var actionItems: [String]
    /// Questions left unanswered. Only made with templates with fixed sections.
    public var openQuestions: [String]
    /// ISO 639-1 code of the language the summary is written in, if known.
    public var language: String?

    public init(
        template: SummaryTemplate = .general,
        title: String = "",
        overview: String = "",
        keyPoints: [String] = [],
        decisions: [String] = [],
        actionItems: [String] = [],
        openQuestions: [String] = [],
        language: String? = nil
    ) {
        self.template = template
        self.title = title
        self.overview = overview
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.language = language
    }

    public var isEmpty: Bool {
        Self.isBlank(title) && Self.isBlank(overview)
            && [keyPoints, decisions, actionItems, openQuestions].allSatisfy { $0.allSatisfy(Self.isBlank) }
    }

    /// The summary as plain text, for handing it back to a model. Leaves out the title, which the
    /// overview covers.
    public var plainText: String {
        var blocks: [String] = []
        if !Self.isBlank(overview) {
            blocks.append(overview.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let lists = [
            ("Key points", keyPoints), ("Decisions", decisions), ("Action items", actionItems),
            ("Open questions", openQuestions),
        ]
        for (heading, items) in lists {
            let lines = items.filter { !Self.isBlank($0) }.map {
                "- \($0.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
            if !lines.isEmpty {
                blocks.append(([heading + ":"] + lines).joined(separator: "\n"))
            }
        }
        return blocks.joined(separator: "\n\n")
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Identifies a summarizer for UI.
public struct SummarizerInfo: Sendable, Equatable {
    /// Stable identifier, e.g. `"apple-intelligence"`.
    public let id: String
    /// Human-readable name, e.g. `"Apple Intelligence"`.
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

public enum SummarizerAvailability: Sendable, Equatable {
    case available
    /// `reason` is a sentence for the UI, e.g. what to turn on.
    case unavailable(reason: String)
}

/// The seam between Mixdown and a summarization backend.
///
/// Implementations must run entirely on-device. The rest of the app only ever talks to this
/// protocol, so offering another backend means adding a new conforming type and constructing it
/// where the summarizer is chosen.
public protocol Summarizer: Sendable {
    var info: SummarizerInfo { get }

    /// Whether `summarize` can run right now. May change while the app runs, e.g. when the user
    /// turns a system feature on. Read on the main actor; keep it cheap.
    var availability: SummarizerAvailability { get }

    /// Summarizes a transcript, which isn't empty, in the shape of `template`. Honors task
    /// cancellation.
    func summarize(_ transcript: Transcript, template: SummaryTemplate) async throws -> NoteSummary
}

public enum SummarizationError: LocalizedError, Sendable, Equatable {
    case unavailable(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): "Summaries aren't available: \(reason)"
        case .failed(let reason): "Summarizing failed: \(reason)"
        }
    }
}

/// Summarizes transcripts too long for a model's context window in passes: each piece of the
/// transcript on its own, then those summaries together, until one summary is left.
///
/// Knows nothing about the model. A backend supplies the size of a piece and runs each step.
public struct ChunkedSummarizer: Sendable {
    public enum Step: Sendable, Equatable {
        /// The text is consecutive lines of the transcript, `Speaker: text` where known.
        case transcript
        /// The text is summaries of consecutive parts of one recording, in order.
        case combine
    }

    /// Most estimated tokens (see `estimatedTokens(in:)`) of text handed to one step.
    public var maxTokens: Int
    /// Combining passes before giving up, in case summaries don't get shorter.
    public var maxCombinePasses: Int

    public init(maxTokens: Int, maxCombinePasses: Int = 4) {
        self.maxTokens = max(maxTokens, 1)
        self.maxCombinePasses = maxCombinePasses
    }

    /// - Parameter step: Summarizes one piece of text of the given kind; called one at a time.
    public func summarize(
        _ transcript: Transcript,
        step: (_ text: String, _ kind: Step) async throws -> NoteSummary
    ) async throws -> NoteSummary {
        var pieces = Self.chunks(of: Self.lines(of: transcript), maxTokens: maxTokens, separator: "\n")
        var kind = Step.transcript
        for _ in 0...maxCombinePasses {
            guard pieces.count > 1 else {
                guard let piece = pieces.first else { return NoteSummary() }
                return try await step(piece, kind)
            }
            var parts: [String] = []
            for (index, piece) in pieces.enumerated() {
                try Task.checkCancellation()
                let text = try await step(piece, kind).plainText
                if !text.isEmpty {
                    parts.append("Part \(index + 1) of \(pieces.count):\n\(text)")
                }
            }
            pieces = Self.chunks(of: parts, maxTokens: maxTokens, separator: "\n\n")
            kind = .combine
        }
        throw SummarizationError.failed("The recording is too long to summarize.")
    }

    // MARK: - Pieces

    /// One line per turn: consecutive segments of the same speaker are joined.
    static func lines(of transcript: Transcript) -> [String] {
        var turns: [(speaker: String?, text: String)] = []
        for segment in transcript.segments {
            let text = singleLine(segment.text)
            guard !text.isEmpty else { continue }
            let speaker = segment.speaker.map(singleLine).flatMap { $0.isEmpty ? nil : $0 }
            if let last = turns.last, last.speaker == speaker {
                turns[turns.count - 1].text += " " + text
            } else {
                turns.append((speaker, text))
            }
        }
        return turns.map { turn in turn.speaker.map { "\($0): \(turn.text)" } ?? turn.text }
    }

    /// Joins `items` into as few pieces as fit `maxTokens` each, in order. An item that doesn't
    /// fit on its own is split, at spaces where possible.
    static func chunks(of items: [String], maxTokens: Int, separator: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        for item in items.flatMap({ split($0, maxTokens: maxTokens) }) {
            let candidate = current.isEmpty ? item : current + separator + item
            if estimatedTokens(in: candidate) <= maxTokens {
                current = candidate
            } else {
                pieces.append(current)
                current = item
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    /// `text` in pieces of at most `maxTokens`, cut at the last space that keeps a piece within
    /// the limit, else mid-word.
    static func split(_ text: String, maxTokens: Int) -> [String] {
        let budget = max(maxTokens, 1) * 3
        var pieces: [String] = []
        var rest = Substring(text)
        while estimatedTokens(in: rest) > maxTokens {
            var cost = 0
            var end = rest.startIndex
            var lastSpace: Substring.Index?
            for index in rest.indices {
                cost += thirds(rest[index])
                guard cost <= budget else { break }
                if rest[index] == " " { lastSpace = index }
                end = rest.index(after: index)
            }
            var cut = lastSpace.flatMap { $0 > rest.startIndex ? $0 : nil } ?? end
            // A single character over the limit still has to go somewhere.
            if cut == rest.startIndex { cut = rest.index(after: cut) }
            pieces.append(rest[..<cut].trimmingCharacters(in: .whitespaces))
            rest = rest[cut...].drop { $0 == " " }
        }
        if !rest.isEmpty { pieces.append(String(rest)) }
        return pieces
    }

    /// A deliberately high guess at how many tokens a model needs for `text`: a third of a token
    /// per character, or a whole one for Chinese, Japanese and Korean, which tokenize densely.
    public static func estimatedTokens(in text: some StringProtocol) -> Int {
        let total = text.reduce(0) { $0 + thirds($1) }
        return (total + 2) / 3
    }

    /// The estimated cost of `character` in thirds of a token.
    private static func thirds(_ character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first else { return 1 }
        switch scalar.value {
        case 0x1100...0x11FF, 0x3040...0x30FF, 0x3130...0x318F, 0xAC00...0xD7AF: return 3
        default: return scalar.properties.isIdeographic ? 3 : 1
        }
    }

    private static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
