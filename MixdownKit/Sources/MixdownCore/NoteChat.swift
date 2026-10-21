import Foundation

// MARK: - Embeddings

/// A vector standing for the meaning of a piece of text: texts that mean similar things get
/// vectors pointing the same way.
public struct TextEmbedding: Sendable, Equatable {
    /// The model that made the vector. Only vectors of the same model can be compared.
    public var model: String
    /// Of unit length, so `similarity(to:)` is a dot product.
    public private(set) var vector: [Float]

    /// `vector` is scaled to unit length.
    public init(model: String, vector: [Float]) {
        self.model = model
        self.vector = Self.normalized(vector)
    }

    /// The cosine similarity with `other`, another unit vector of the same model: 1 for the same
    /// direction, 0 for unrelated. 0 if the lengths differ.
    public func similarity(to other: [Float]) -> Float {
        guard other.count == vector.count else { return 0 }
        var sum: Float = 0
        for index in vector.indices { sum += vector[index] * other[index] }
        return sum
    }

    /// `vector` scaled to unit length; all zeros stays all zeros.
    public static func normalized(_ vector: [Float]) -> [Float] {
        let length = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard length > 0, length.isFinite else { return vector }
        return vector.map { $0 / length }
    }
}

extension TextEmbedding: Codable {
    private enum CodingKeys: String, CodingKey {
        case model, vector
    }

    // The vector as raw bytes: a note has hundreds of them, of hundreds of numbers each.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decode(String.self, forKey: .model)
        let data = try container.decode(Data.self, forKey: .vector)
        // Copied, as the bytes needn't be aligned for `Float`.
        let count = data.count / MemoryLayout<Float>.size
        vector = [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
            initialized = data.copyBytes(to: buffer) / MemoryLayout<Float>.size
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(vector.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: .vector)
    }
}

/// The seam between Mixdown and a text embedding model, used to find the lines of notes a chat
/// question is about.
///
/// Implementations must run entirely on-device.
public protocol TextEmbedder: Sendable {
    /// The embedding of each of `texts`, in order, each by the model for its language; `nil` for
    /// text no model covers. Throws if no model can be used right now, e.g. as it isn't
    /// downloaded yet. Honors task cancellation.
    func embed(_ texts: [String]) async throws -> [TextEmbedding?]

    /// The embedding of `text` by `model`, the `TextEmbedding.model` of earlier embeddings, to
    /// compare with them. `nil` if that model can't be used.
    func embed(_ text: String, model: String) async throws -> TextEmbedding?
}

// MARK: - Answering

/// A passage of a note handed to a `NoteAnswerer`, numbered so the answer can cite it.
public struct NoteExcerpt: Sendable, Equatable {
    /// What the answer cites it as, like `[3]`.
    public var number: Int
    public var noteTitle: String
    /// When the note was recorded.
    public var date: Date
    /// The heading of the section it's from, like "Action Items" or "Transcript".
    public var section: String?
    /// When it was said, like `00:12:34`, for a transcript line.
    public var time: String?
    /// One line per line of the note.
    public var text: String

    public init(number: Int, noteTitle: String, date: Date, section: String?, time: String?, text: String) {
        self.number = number
        self.noteTitle = noteTitle
        self.date = date
        self.section = section
        self.time = time
        self.text = text
    }
}

/// An earlier question in the chat and its answer, so a follow-up can refer to it.
public struct ChatTurn: Sendable, Equatable {
    public var question: String
    public var answer: String

    public init(question: String, answer: String) {
        self.question = question
        self.answer = answer
    }
}

/// The seam between Mixdown and a language model that answers questions about notes.
///
/// Implementations must run entirely on-device. Counting notes is left to Mixdown (see
/// `NoteQuestion`), as models get numbers wrong.
public protocol NoteAnswerer: Sendable {
    /// Whether `answer` can run right now. May change while the app runs. Read on the main
    /// actor; keep it cheap.
    var availability: SummarizerAvailability { get }

    /// About how many tokens of excerpts fit in one answer, by
    /// `ChunkedSummarizer.estimatedTokens(in:)`.
    var excerptTokenBudget: Int { get }

    /// Answers `question` from `excerpts`, citing them by number like `[2]`, in the language of the
    /// question. `history` is the chat so far, oldest first, and `now` is when it's asked, for
    /// questions like "last week". Yields the whole answer so far each time it grows. Honors
    /// task cancellation.
    func answer(
        _ question: String,
        excerpts: [NoteExcerpt],
        history: [ChatTurn],
        now: Date
    ) -> AsyncThrowingStream<String, any Error>
}

public enum NoteAnswerError: LocalizedError, Sendable, Equatable {
    case unavailable(String)
    /// The model wouldn't answer, e.g. for its safety rules.
    case refused
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): "Apple Intelligence isn't available: \(reason)"
        case .refused: "Apple Intelligence wouldn't answer that question."
        case .failed(let reason): "Answering failed: \(reason)"
        }
    }
}

// MARK: - Citations

/// Finds the citations an answer makes, like `[2]`, `[1, 3]` or `[Excerpt 4]`.
public enum ChatCitations {
    public enum Piece: Sendable, Equatable {
        case text(String)
        /// One number per citation; `[1, 3]` is two.
        case citation(Int)
    }

    private nonisolated(unsafe) static let pattern =
        #/\[(?:excerpts?\s*)?(\d{1,3}(?:\s*[,;]\s*(?:excerpts?\s*)?\d{1,3})*)\]/#
        .ignoresCase()

    /// `answer` in text and citations, in order. Brackets citing only numbers not in `valid` are
    /// kept as text; numbers in them that aren't in `valid` are left out.
    public static func pieces(of answer: String, valid: Set<Int>) -> [Piece] {
        var pieces: [Piece] = []
        var rest = answer[...]
        func appendText(_ text: Substring) {
            guard !text.isEmpty else { return }
            if case .text(let previous) = pieces.last {
                pieces[pieces.count - 1] = .text(previous + text)
            } else {
                pieces.append(.text(String(text)))
            }
        }
        while let match = rest.firstMatch(of: pattern) {
            let numbers = match.1.split { !$0.isNumber }.compactMap { Int($0) }.filter(valid.contains)
            appendText(rest[..<match.range.lowerBound])
            if numbers.isEmpty {
                appendText(rest[match.range])
            } else {
                pieces += numbers.map(Piece.citation)
            }
            rest = rest[match.range.upperBound...]
        }
        appendText(rest)
        return pieces
    }

    /// The numbers `answer` cites from `valid`, each once, in the order first cited.
    public static func numbers(in answer: String, valid: Set<Int>) -> [Int] {
        var seen = Set<Int>()
        return pieces(of: answer, valid: valid).compactMap { piece in
            guard case .citation(let number) = piece, seen.insert(number).inserted else { return nil }
            return number
        }
    }
}
