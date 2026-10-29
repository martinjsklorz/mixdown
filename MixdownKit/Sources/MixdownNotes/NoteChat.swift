import Foundation
import MixdownCore
import Observation
import os

/// Chat across all notes: answers questions with Apple Intelligence from the lines of the notes
/// that match them best, citing each so it opens at that line. Questions that ask how many notes
/// there are, like "How many 1:1s did I have in September?", are counted by Mixdown itself (see
/// `NoteQuestion`), so the number is exact.
///
/// The notes are read into a `NoteChatIndex` once the chat is first shown, and kept up to date
/// from then on. The chat lasts until the app quits or it's cleared.
@MainActor @Observable
public final class NoteChat {
    /// A line of a note an answer is from, or a note a count counted.
    public struct Source: Identifiable, Equatable, Sendable {
        /// What the answer cites it as, like `[3]`.
        public var number: Int
        public var noteURL: URL
        public var noteTitle: String
        public var date: Date
        public var section: String?
        /// When it was said, like `00:12:34`.
        public var time: String?
        /// The number of the line in `NoteSearchIndex.lines(of:)` to open the note at; `nil` for
        /// the top.
        public var line: Int?
        /// The lines; empty for a counted note.
        public var text: String

        public var id: Int { number }
    }

    public struct Message: Identifiable, Sendable {
        public enum Role: Sendable {
            case question
            case answer
        }

        public let id = UUID()
        public let role: Role
        /// Markdown, with citations like `[2]` of `sources`.
        public var text: String
        /// What the answer had to go on, by number.
        public var sources: [Source] = []
        /// Whether every source is shown under the answer, not only the cited ones: the notes a
        /// count counted, or lines found without Apple Intelligence.
        public var showsAllSources = false
        /// Says how the answer came about, e.g. that it was counted on this Mac.
        public var footnote: String?
        public var isWriting = false
        public var isError = false
        /// Whether it's Mixdown saying it has nothing to answer with, like that it found nothing,
        /// rather than an answer. Left out of the chat so far that later questions hand the model.
        var isNonAnswer = false
    }

    public private(set) var messages: [Message] = []
    /// How many notes have been read for Chat so far, while reading them.
    public private(set) var indexProgress: (done: Int, total: Int)?
    public var isAnswering: Bool { answering != nil }

    public let answerer: any NoteAnswerer
    private let index: NoteChatIndexStore
    /// The notes in the notes folder, newest first.
    @ObservationIgnored private var notes: [NoteDocument] = []
    @ObservationIgnored private var indexing: Task<Void, Never>?
    private var answering: Task<Void, Never>?
    /// Counts the questions asked, so an answer cancelled by `clear()` that's still winding down
    /// doesn't mark the next one as done.
    @ObservationIgnored private var questionCount = 0

    /// Most passages looked at for an answer, before trimming to what fits the model.
    static let maxExcerpts = 12
    /// Shown when Apple Intelligence isn't there to answer.
    static let fallbackSourceCount = 5
    /// Notes listed under a count; the count itself covers them all.
    static let maxCountedSources = 50

    /// - Parameters:
    ///   - indexDirectory: Where the notes read for Chat are saved, a file per note; see
    ///     `NoteChatIndex.save(in:)`.
    ///   - legacyIndexFile: Where earlier versions saved the whole index, moved into
    ///     `indexDirectory` when first read.
    public init(
        answerer: any NoteAnswerer,
        embedder: any TextEmbedder,
        indexDirectory: URL,
        legacyIndexFile: URL? = nil
    ) {
        self.answerer = answerer
        self.index = NoteChatIndexStore(
            embedder: embedder,
            directoryURL: indexDirectory,
            legacyFileURL: legacyIndexFile
        )
    }

    // MARK: Notes

    /// Reads new and changed notes into the index, after the update already running. Notes
    /// already read stay searchable meanwhile.
    ///
    /// Without notes (none yet, or the folder can't be reached) the index keeps the notes it has,
    /// so a drive that's away for a while doesn't mean reading them all again. Only the notes
    /// given here are searched, so it never answers from notes that are gone.
    public func update(notes: [NoteDocument]) {
        self.notes = notes
        guard !notes.isEmpty else { return }
        let previous = indexing
        previous?.cancel()
        indexing = Task { [index] in
            await previous?.value
            guard !Task.isCancelled else { return }
            await index.update(to: notes) { done, total in
                await MainActor.run { self.indexProgress = done < total ? (done, total) : nil }
            }
            if !Task.isCancelled { indexProgress = nil }
        }
    }

    // MARK: Asking

    /// Asks `question`, unless an answer is still being written.
    public func ask(_ question: String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, answering == nil else { return }
        let history = turns
        messages.append(Message(role: .question, text: question))
        let answer = Message(role: .answer, text: "", isWriting: true)
        messages.append(answer)
        questionCount += 1
        let count = questionCount
        answering = Task {
            await self.answer(question, history: history, messageID: answer.id)
            // After `clear()`, a newer question may be being answered by now.
            if questionCount == count { answering = nil }
        }
    }

    /// Stops writing the answer, keeping what's written so far.
    public func stopAnswering() {
        answering?.cancel()
    }

    /// Stops reading notes and answering, and starts a new chat, as Chat was turned off. The notes
    /// read so far stay saved, so turning it on again only reads what changed meanwhile.
    public func stop() {
        indexing?.cancel()
        indexing = nil
        indexProgress = nil
        clear()
    }

    /// Starts a new chat.
    public func clear() {
        answering?.cancel()
        answering = nil
        messages = []
    }

    /// The questions asked so far and their answers, oldest first. Leaves out the questions that
    /// weren't answered: errors, non-answers, and answers stopped before they began.
    var turns: [ChatTurn] {
        zip(messages, messages.dropFirst()).compactMap { question, answer in
            guard question.role == .question, answer.role == .answer, !answer.isError, !answer.isNonAnswer,
                !answer.text.isEmpty
            else { return nil }
            return ChatTurn(question: question.text, answer: answer.text)
        }
    }

    private func answer(_ question: String, history: [ChatTurn], messageID: Message.ID) async {
        let now = Date.now
        let parsed = NoteQuestion.parse(question, now: now)
        let notes = self.notes

        if parsed.asksForCount {
            // Reads every note in the folder the first time.
            let counted = await Task.detached(priority: .userInitiated) { notes.filter(parsed.counts) }.value
            updateMessage(messageID) { message in
                message.text = parsed.countAnswer(for: counted)
                message.sources = counted.prefix(Self.maxCountedSources).enumerated().map { offset, note in
                    Source(
                        number: offset + 1,
                        noteURL: note.url,
                        noteTitle: note.title,
                        date: note.createdAt,
                        text: ""
                    )
                }
                message.showsAllSources = true
                message.footnote = "Counted on this Mac from the notes’ dates, titles and summary templates."
                message.isWriting = false
            }
            return
        }

        // A short follow-up like "And what about Ben?" is about what was asked before.
        var searchText = parsed.searchText
        if let previous = history.last, searchText.split(separator: " ").count <= 4 {
            searchText = NoteQuestion.parse(previous.question, now: now).searchText + " " + searchText
        }
        let passages = await index.search(searchText, in: notes.filter(parsed.isInScope), limit: Self.maxExcerpts)
        // Embedding the question doesn't stop when cancelled.
        guard !Task.isCancelled else {
            updateMessage(messageID) { $0.isWriting = false }
            return
        }
        let excerpts = self.excerpts(of: passages)
        guard !excerpts.isEmpty else {
            updateMessage(messageID) { message in
                message.text = "I couldn’t find anything about that in your notes."
                message.isNonAnswer = true
                message.isWriting = false
            }
            return
        }
        let sources = excerpts.map(\.source)
        updateMessage(messageID) { $0.sources = sources }

        if case .unavailable(let reason) = answerer.availability {
            updateMessage(messageID) { message in
                message.text =
                    "Apple Intelligence can’t answer right now. \(reason) These lines of your notes match best:"
                message.sources = Array(sources.prefix(Self.fallbackSourceCount))
                message.showsAllSources = true
                message.isNonAnswer = true
                message.isWriting = false
            }
            return
        }

        do {
            let stream = answerer.answer(question, excerpts: excerpts.map(\.excerpt), history: history, now: now)
            for try await text in stream {
                updateMessage(messageID) { $0.text = text }
            }
            updateMessage(messageID) { $0.isWriting = false }
        } catch is CancellationError {
            updateMessage(messageID) { $0.isWriting = false }
        } catch {
            Logger(subsystem: "app.mixdown", category: "chat")
                .error("Answering failed: \(error.localizedDescription, privacy: .public)")
            updateMessage(messageID) { message in
                message.text = error.localizedDescription
                message.sources = []
                message.isError = true
                message.isWriting = false
            }
        }
    }

    /// `passages` as numbered excerpts, as many as fit the model, each with what to show for it.
    private func excerpts(of passages: [NoteChatIndex.Passage]) -> [(excerpt: NoteExcerpt, source: Source)] {
        let notesByURL = Dictionary(notes.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        var excerpts: [(excerpt: NoteExcerpt, source: Source)] = []
        var tokens = 0
        for passage in passages {
            guard let note = notesByURL[passage.noteURL] else { continue }
            let excerpt = NoteExcerpt(
                number: excerpts.count + 1,
                noteTitle: note.title,
                date: note.createdAt,
                section: passage.section,
                time: passage.time,
                text: passage.text
            )
            // Plus the line saying where it's from.
            let cost = ChunkedSummarizer.estimatedTokens(in: passage.text + note.title) + 20
            if !excerpts.isEmpty, tokens + cost > answerer.excerptTokenBudget { break }
            tokens += cost
            let source = Source(
                number: excerpt.number,
                noteURL: note.url,
                noteTitle: note.title,
                date: note.createdAt,
                section: passage.section,
                time: passage.time,
                line: passage.line,
                text: passage.text
            )
            excerpts.append((excerpt, source))
        }
        return excerpts
    }

    private func updateMessage(_ id: Message.ID, _ update: (inout Message) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        update(&messages[index])
    }
}

/// The `NoteChatIndex` behind `NoteChat`, off the main thread and saved between launches. Searches
/// can run while an update waits on the embedder.
actor NoteChatIndexStore {
    private static let logger = Logger(subsystem: "app.mixdown", category: "chat")

    private let embedder: any TextEmbedder
    /// A file per note; see `NoteChatIndex.save(in:)`.
    private let directoryURL: URL
    /// Where earlier versions saved the whole index, moved into `directoryURL` when first read.
    private let legacyFileURL: URL?
    /// Read from `directoryURL` when first needed.
    private var index: NoteChatIndex?

    init(embedder: any TextEmbedder, directoryURL: URL, legacyFileURL: URL?) {
        self.embedder = embedder
        self.directoryURL = directoryURL
        self.legacyFileURL = legacyFileURL
    }

    /// Brings the index in line with `notes`, calling `progress` after each note it reads with how
    /// many are done. Each note is saved as soon as it's read, so stopping early, when cancelled or
    /// on quitting, keeps the notes read so far.
    func update(to notes: [NoteDocument], progress: @Sendable (_ done: Int, _ total: Int) async -> Void) async {
        _ = loaded()
        index?.removeNotes(notIn: notes)
        let pending = index?.notesToIndex(notes, canEmbed: true) ?? []
        save()
        guard !pending.isEmpty else { return }

        // Only cancellation ends it early.
        try? await NoteChatIndex.index(pending, embedder: embedder) { indexed, done in
            if indexed.embedderFailed {
                Self.logger.info("Indexing notes for Chat without embeddings, as the embedder failed")
            }
            index?.insert(indexed)
            save()
            await progress(done, pending.count)
        }
    }

    /// The passages of `notes` that best answer `query`, best first.
    func search(_ query: String, in notes: [NoteDocument], limit: Int) async -> [NoteChatIndex.Passage] {
        let models = loaded().embeddingModels
        var queryEmbeddings: [TextEmbedding] = []
        for model in models {
            do {
                if let embedding = try await embedder.embed(query, model: model) { queryEmbeddings.append(embedding) }
            } catch {
                Self.logger.error("Couldn't embed a question: \(error.localizedDescription, privacy: .public)")
            }
        }
        return loaded().search(query, queryEmbeddings: queryEmbeddings, in: notes, limit: limit)
    }

    private func loaded() -> NoteChatIndex {
        if let index { return index }
        var loaded = NoteChatIndex.load(from: directoryURL)
        if loaded.isEmpty, let legacyFileURL, let data = try? Data(contentsOf: legacyFileURL) {
            loaded = NoteChatIndex.decoded(fromLegacyFile: data)
        }
        index = loaded
        save()
        // Moved into `directoryURL`, or left behind by it.
        if let legacyFileURL, index?.hasUnsavedChanges == false {
            try? FileManager.default.removeItem(at: legacyFileURL)
        }
        return index ?? loaded
    }

    /// Writes the notes that changed since the last save.
    private func save() {
        guard index?.hasUnsavedChanges == true else { return }
        do {
            try index?.save(in: directoryURL)
        } catch {
            // Tried again on the next save; if it never works, the next launch reads the notes again.
            Self.logger.error("Couldn't save the Chat index: \(error.localizedDescription, privacy: .public)")
        }
    }
}
