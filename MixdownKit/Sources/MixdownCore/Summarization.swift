import Foundation
import os

/// The shape of a summary and what the summarizer looks out for, chosen per kind of recording.
///
/// Mixdown comes with the built-in templates below. The user can edit them, add templates of their
/// own and delete those again; built-ins can only be restored to how they came.
public struct SummaryTemplate: Sendable, Hashable, Identifiable, Codable {
    /// Which sections a summary has.
    public enum Layout: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
        /// An overview, then key points and action items.
        case overview
        /// TL;DR, Decisions, Action Items and Open Questions, each shown even when empty.
        case sections

        public var id: Self { self }

        public var displayName: String {
            switch self {
            case .overview: "Overview, Key Points, Action Items"
            case .sections: "TL;DR, Decisions, Action Items, Open Questions"
            }
        }
    }

    /// Stable across edits. A built-in's is a word like `oneOnOne`, written to notes' frontmatter.
    public let id: String
    public var name: String
    /// What kind of recording the template is for and what matters in one, for the model. May be
    /// empty.
    public var instructions: String
    public var layout: Layout

    public init(id: String, name: String, instructions: String = "", layout: Layout = .overview) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.layout = layout
    }

    /// The name, or a stand-in while it's blank.
    public var displayName: String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Untitled Template" : name
    }

    /// Whether summaries have the fixed sections TL;DR, Decisions, Action Items and Open
    /// Questions, instead of an overview and key points.
    public var hasFixedSections: Bool { layout == .sections }

    public var isBuiltIn: Bool { Self.builtIn(id: id) != nil }

    /// Whether this is a built-in the user changed.
    public var isEdited: Bool { Self.builtIn(id: id).map { $0 != self } ?? false }

    /// Most characters of `instructions`, so they leave the model room for the transcript.
    public static let maximumInstructionsLength = 1000

    // MARK: Built-in templates

    /// An overview, key points and action items, for any recording. The fallback when a chosen
    /// template is gone.
    public static let general = SummaryTemplate(id: "general", name: "General")
    public static let oneOnOne = SummaryTemplate(
        id: "oneOnOne",
        name: "1:1",
        instructions: "The recording is a one-on-one meeting between two people, such as a manager and a team "
            + "member. Look out for feedback, goals, concerns and what the two agreed on.",
        layout: .sections
    )
    public static let standup = SummaryTemplate(
        id: "standup",
        name: "Standup",
        instructions: "The recording is a team standup. Look out for what each person finished, what they'll "
            + "work on next and what blocks them, naming the person.",
        layout: .sections
    )
    public static let clientCall = SummaryTemplate(
        id: "clientCall",
        name: "Client Call",
        instructions: "The recording is a call with a client. Look out for the client's needs and requirements, "
            + "what was promised to them, and the next steps on both sides.",
        layout: .sections
    )

    public static let builtIns = [general, oneOnOne, standup, clientCall]

    /// The built-in template with `id`, as it came.
    public static func builtIn(id: String) -> SummaryTemplate? {
        builtIns.first { $0.id == id }
    }

    // MARK: Lists of templates

    /// `stored` as a list to offer: every built-in, edited or not, first in their own order, then
    /// the user's templates in theirs. Templates with an id already in the list are dropped.
    public static func list(from stored: [SummaryTemplate]) -> [SummaryTemplate] {
        let builtIns = builtIns.map { builtIn in stored.first { $0.id == builtIn.id } ?? builtIn }
        var ids = Set(builtIns.map(\.id))
        return builtIns + stored.filter { ids.insert($0.id).inserted }
    }

    /// A new template of the user's, named so it stands out from those in `templates`, e.g.
    /// "New Template 2".
    public static func new(in templates: [SummaryTemplate]) -> SummaryTemplate {
        let names = Set(templates.map(\.displayName))
        let name =
            (1...).lazy.map { $0 == 1 ? "New Template" : "New Template \($0)" }.first { !names.contains($0) }
            ?? "New Template"
        return SummaryTemplate(id: "custom-\(UUID().uuidString)", name: name)
    }

    /// A template of the user's with the same layout and instructions as `template`, named as a
    /// copy, e.g. "Standup Copy".
    public static func copy(of template: SummaryTemplate, in templates: [SummaryTemplate]) -> SummaryTemplate {
        let names = Set(templates.map(\.displayName))
        let base = "\(template.displayName) Copy"
        let name = (1...).lazy.map { $0 == 1 ? base : "\(base) \($0)" }.first { !names.contains($0) } ?? base
        return SummaryTemplate(
            id: "custom-\(UUID().uuidString)",
            name: name,
            instructions: template.instructions,
            layout: template.layout
        )
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case id, name, instructions, layout
    }

    /// Lenient, so one odd field doesn't lose all of the user's templates.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        instructions = try container.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        layout = (try? container.decodeIfPresent(Layout.self, forKey: .layout)) ?? .overview
    }
}

/// What a summarizer makes of a transcript. Any part may be empty.
public struct NoteSummary: Sendable, Equatable {
    /// The template the summary was made with, which decides its sections.
    public var template: SummaryTemplate
    /// The topic in a few words, to name the note after.
    public var title: String
    /// A few sentences on what the recording was about; the TL;DR of the `sections` layout.
    public var overview: String
    /// Only made with the `overview` layout.
    public var keyPoints: [String]
    /// Only made with the `sections` layout.
    public var decisions: [String]
    /// Tasks someone agreed to do, naming the person where the transcript does.
    public var actionItems: [String]
    /// Questions left unanswered. Only made with the `sections` layout.
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

    /// Summarizes a transcript, which isn't empty, in the shape of `template`, making sure to
    /// cover `moments`, the ones the user marked while recording. Honors task cancellation.
    func summarize(_ transcript: Transcript, moments: [Moment], template: SummaryTemplate) async throws -> NoteSummary

    /// Tells someone who drifted off what they missed in `transcript`, the last few minutes of a
    /// recording still under way, which isn't empty: a few short points, in the order they came
    /// up. Written in `language`, a BCP 47 identifier, or with `nil` in the transcript's. Honors
    /// task cancellation.
    func catchUp(on transcript: Transcript, language: String?) async throws -> [String]

    /// Names for `speakers`, labels in `transcript` such as "Speaker 2", after what's said in it,
    /// by label; see `SpeakerNaming`. Labels the model can't name are left out. Honors task
    /// cancellation.
    func nameSpeakers(_ speakers: [String], in transcript: Transcript) async throws -> [String: String]
}

extension Summarizer {
    /// The key points of a general summary, or else its overview, for a backend without a
    /// catch-up of its own. Ignores `language`.
    public func catchUp(on transcript: Transcript, language: String?) async throws -> [String] {
        let summary = try await summarize(transcript, moments: [], template: .general)
        let points = summary.keyPoints.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let overview = summary.overview.trimmingCharacters(in: .whitespacesAndNewlines)
        return points.isEmpty && !overview.isEmpty ? [overview] : points
    }

    /// No names, for a backend that can't tell.
    public func nameSpeakers(_ speakers: [String], in transcript: Transcript) async throws -> [String: String] {
        [:]
    }
}

public enum SummarizationError: LocalizedError, Sendable, Equatable {
    case unavailable(String)
    case failed(String)
    /// The text handed to a model didn't fit its context window.
    case tooLong

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): "Summaries aren't available: \(reason)"
        case .failed(let reason): "Summarizing failed: \(reason)"
        case .tooLong: "Summarizing failed: part of the recording is too long for the model."
        }
    }
}

/// Summarizes transcripts too long for a model's context window in passes: each piece of the
/// transcript on its own, then those summaries together, until one summary is left.
///
/// Knows nothing about the model. A backend supplies the size of a piece and runs each step.
///
/// A piece whose step fails is left out, so the summary covers the rest of the recording. Only
/// when every piece of a pass fails does the summary fail.
public struct ChunkedSummarizer: Sendable {
    public enum Step: Sendable, Equatable {
        /// The text is consecutive lines of the transcript, `Speaker: text` where known, with the
        /// moments the user marked among them.
        case transcript
        /// The text is summaries of consecutive parts of one recording, in order.
        case combine
    }

    private static let logger = Logger(subsystem: "app.mixdown", category: "summary")

    /// Most estimated tokens (see `estimatedTokens(in:)`) of text handed to one step.
    private let maxTokens: Int
    /// Pieces aren't split smaller than this when a step finds them too long; they're left out
    /// instead.
    private let minTokens: Int
    /// Combining passes before giving up, in case summaries don't get shorter.
    private let maxCombinePasses: Int

    public init(maxTokens: Int, minTokens: Int = 1, maxCombinePasses: Int = 4) {
        self.maxTokens = max(maxTokens, 1)
        self.minTokens = max(minTokens, 1)
        self.maxCombinePasses = max(maxCombinePasses, 0)
    }

    /// - Parameter moments: Marked in the transcript where they were, for the model to cover.
    /// - Parameter step: Summarizes one piece of text of the given kind; called one at a time.
    ///   Throws `SummarizationError.tooLong` if the text doesn't fit the model, and the piece is
    ///   summarized in smaller pieces instead.
    public func summarize(
        _ transcript: Transcript,
        moments: [Moment] = [],
        step: (_ text: String, _ kind: Step) async throws -> NoteSummary
    ) async throws -> NoteSummary {
        var separator = "\n"
        var pieces = Self.groups(
            of: Self.lines(of: transcript, moments: moments),
            maxTokens: maxTokens,
            separator: separator
        )
        var kind = Step.transcript
        for _ in 0...maxCombinePasses {
            if pieces.count == 1 {
                do {
                    return try await step(pieces[0].joined(separator: separator), kind)
                } catch SummarizationError.tooLong {
                    guard let smaller = halves(of: pieces[0], separator: separator) else {
                        throw SummarizationError.tooLong
                    }
                    pieces = smaller
                }
            }
            guard !pieces.isEmpty else { return NoteSummary() }
            let texts = try await summaries(of: pieces, kind: kind, separator: separator, step: step)
            let parts = texts.enumerated().compactMap { index, text in
                text.isEmpty ? nil : "Part \(index + 1) of \(texts.count):\n\(text)"
            }
            separator = "\n\n"
            pieces = Self.groups(of: parts, maxTokens: maxTokens, separator: separator)
            kind = .combine
        }
        throw SummarizationError.failed("The recording is too long to summarize.")
    }

    /// The summary of each piece as plain text, in order. A piece that's too long for `step` is
    /// summarized in smaller pieces, each with an entry of its own. A piece that fails gets an
    /// empty entry; if all of them fail, the first error is thrown.
    private func summaries(
        of pieces: [[String]],
        kind: Step,
        separator: String,
        step: (_ text: String, _ kind: Step) async throws -> NoteSummary
    ) async throws -> [String] {
        var queue = ArraySlice(pieces)
        var texts: [String] = []
        var firstError: (any Error)?
        var anySucceeded = false
        while let piece = queue.popFirst() {
            try Task.checkCancellation()
            do {
                texts.append(try await step(piece.joined(separator: separator), kind).plainText)
                anySucceeded = true
            } catch {
                if error is CancellationError || Task.isCancelled { throw error }
                if case SummarizationError.tooLong = error, let smaller = halves(of: piece, separator: separator) {
                    Self.logger.info("A piece was too long, summarizing it in \(smaller.count) pieces")
                    queue = ArraySlice(smaller) + queue
                    continue
                }
                Self.logger.error("Leaving a piece out of the summary: \(error, privacy: .public)")
                firstError = firstError ?? error
                texts.append("")
            }
        }
        if !anySucceeded, let firstError { throw firstError }
        return texts
    }

    /// `piece` in pieces of about half its size, or nil if those would be smaller than `minTokens`.
    private func halves(of piece: [String], separator: String) -> [[String]]? {
        let half = (Self.estimatedTokens(in: piece.joined(separator: separator)) + 1) / 2
        guard half >= minTokens else { return nil }
        let smaller = Self.groups(of: piece, maxTokens: half, separator: separator)
        return smaller.count > 1 ? smaller : nil
    }

    // MARK: - Pieces

    /// One line per turn: consecutive segments of the same speaker are joined. Each of `moments`
    /// is a line of its own (see `SummaryPrompt.momentLine(for:)`) after the segments that started
    /// by then, as `Transcript.segment(at:)` reckons what it's about, so it stays in the piece
    /// with what was said.
    static func lines(of transcript: Transcript, moments: [Moment] = []) -> [String] {
        var lines: [String] = []
        var turn: (speaker: String?, text: String)?
        func endTurn() {
            if let turn { lines.append(turn.speaker.map { "\($0): \(turn.text)" } ?? turn.text) }
            turn = nil
        }
        var moments = moments.sorted { $0.time < $1.time }[...]
        for segment in transcript.segments {
            let text = singleLine(segment.text)
            guard !text.isEmpty else { continue }
            while let moment = moments.first, moment.time < segment.start {
                endTurn()
                lines.append(SummaryPrompt.momentLine(for: moment))
                moments.removeFirst()
            }
            let speaker = segment.speaker.map(singleLine).flatMap { $0.isEmpty ? nil : $0 }
            if let current = turn, current.speaker == speaker {
                turn?.text += " " + text
            } else {
                endTurn()
                turn = (speaker, text)
            }
        }
        endTurn()
        return lines + moments.map(SummaryPrompt.momentLine(for:))
    }

    /// Packs `items` into as few pieces as fit `maxTokens` each, in order, keeping each piece's
    /// items apart so it can be split again between them. An item that doesn't fit on its own is
    /// split, at spaces where possible.
    static func groups(of items: [String], maxTokens: Int, separator: String) -> [[String]] {
        var pieces: [[String]] = []
        var current: [String] = []
        var currentText = ""
        for item in items.flatMap({ split($0, maxTokens: maxTokens) }) {
            let candidate = current.isEmpty ? item : currentText + separator + item
            if current.isEmpty || estimatedTokens(in: candidate) <= maxTokens {
                current.append(item)
                currentText = candidate
            } else {
                pieces.append(current)
                current = [item]
                currentText = item
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
                cost += rest[index].utf8.count
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
    /// per UTF-8 byte. That's a third per ASCII letter; two thirds per letter of Cyrillic, Greek,
    /// Hebrew or Arabic; and a whole token per Chinese, Japanese, Korean, Thai or Indic letter or
    /// vowel sign. Tokenizers fall back to bytes for text they've seen little of, so scripts
    /// further from English take more tokens.
    public static func estimatedTokens(in text: some StringProtocol) -> Int {
        (text.utf8.count + 2) / 3
    }

    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
