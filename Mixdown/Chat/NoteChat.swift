import Foundation
import MixdownCore
import MixdownNotes
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
final class NoteChat {
    /// A line of a note an answer is from, or a note a count counted.
    struct Source: Identifiable, Equatable {
        /// What the answer cites it as, like `[3]`.
        var number: Int
        var noteURL: URL
        var noteTitle: String
        var date: Date
        var section: String?
        /// When it was said, like `00:12:34`.
        var time: String?
        /// The number of the line in `NoteSearchIndex.lines(of:)` to open the note at; `nil` for
        /// the top.
        var line: Int?
        /// The lines; empty for a counted note.
        var text: String

        var id: Int { number }
    }

    struct Message: Identifiable {
        enum Role {
            case question
            case answer
        }

        let id = UUID()
        let role: Role
        /// Markdown, with citations like `[2]` of `sources`.
        var text: String
        /// What the answer had to go on, by number.
        var sources: [Source] = []
        /// Whether every source is shown under the answer, not only the cited ones: the notes a
        /// count counted, or lines found without Apple Intelligence.
        var showsAllSources = false
        /// Says how the answer came about, e.g. that it was counted on this Mac.
        var footnote: String?
        var isWriting = false
        var isError = false
    }

    private(set) var messages: [Message] = []
    /// How many notes have been read for Chat so far, while reading them.
    private(set) var indexProgress: (done: Int, total: Int)?
    var isAnswering: Bool { answering != nil }

    let answerer: any NoteAnswerer
    private let index: NoteChatIndexStore
    /// The notes in the notes folder, newest first.
    @ObservationIgnored private var notes: [NoteDocument] = []
    @ObservationIgnored private var indexing: Task<Void, Never>?
    private var answering: Task<Void, Never>?

    /// Most passages looked at for an answer, before trimming to what fits the model.
    private static let maxExcerpts = 12
    /// Shown when Apple Intelligence isn't there to answer.
    private static let fallbackSourceCount = 5
    /// Notes listed under a count; the count itself covers them all.
    private static let maxCountedSources = 50

    init(answerer: any NoteAnswerer, embedder: any TextEmbedder) {
        self.answerer = answerer
        self.index = NoteChatIndexStore(embedder: embedder)
    }

    // MARK: Notes

    /// Reads new and changed notes into the index, after the update already running. Notes
    /// already read stay searchable meanwhile.
    ///
    /// Without notes (none yet, or the folder can't be reached) the index keeps the notes it has,
    /// so a drive that's away for a while doesn't mean reading them all again. Only the notes
    /// given here are searched, so it never answers from notes that are gone.
    func update(notes: [NoteDocument]) {
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
    func ask(_ question: String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, answering == nil else { return }
        let history = turns
        messages.append(Message(role: .question, text: question))
        let answer = Message(role: .answer, text: "", isWriting: true)
        messages.append(answer)
        answering = Task {
            await self.answer(question, history: history, messageID: answer.id)
            answering = nil
        }
    }

    /// Stops writing the answer, keeping what's written so far.
    func stopAnswering() {
        answering?.cancel()
    }

    /// Starts a new chat.
    func clear() {
        answering?.cancel()
        answering = nil
        messages = []
    }

    /// The questions asked so far and their answers, oldest first.
    private var turns: [ChatTurn] {
        zip(messages, messages.dropFirst()).compactMap { question, answer in
            guard question.role == .question, answer.role == .answer, !answer.isError else { return nil }
            return ChatTurn(question: question.text, answer: answer.text)
        }
    }

    private func answer(_ question: String, history: [ChatTurn], messageID: Message.ID) async {
        let now = Date.now
        let parsed = NoteQuestion.parse(question, now: now)
        let notes = self.notes

        if parsed.asksForCount {
            let counted = notes.filter(parsed.counts)
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
        let excerpts = self.excerpts(of: passages)
        guard !excerpts.isEmpty else {
            updateMessage(messageID) { message in
                message.text = "I couldn’t find anything about that in your notes."
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
private actor NoteChatIndexStore {
    private static let logger = Logger(subsystem: "app.mixdown", category: "chat")
    /// The index is saved every so many notes while reading many, so quitting loses little.
    private static let notesPerSave = 50

    private let embedder: any TextEmbedder
    private let fileURL = URL.applicationSupportDirectory.appending(path: "ChatIndex.plist")
    /// Read from `fileURL` when first needed.
    private var index: NoteChatIndex?

    init(embedder: any TextEmbedder) {
        self.embedder = embedder
    }

    /// Brings the index in line with `notes`, calling `progress` after each note it reads with how
    /// many are done. Stops early when cancelled, keeping the notes read so far.
    func update(to notes: [NoteDocument], progress: @Sendable (_ done: Int, _ total: Int) async -> Void) async {
        var index = loaded()
        let noteCount = index.noteCount
        index.removeNotes(notIn: notes)
        let pending = index.notesToIndex(notes, canEmbed: true)
        self.index = index
        guard !pending.isEmpty else {
            if index.noteCount != noteCount { save() }
            return
        }

        var embedder: (any TextEmbedder)? = self.embedder
        for (done, note) in pending.enumerated() {
            guard let indexed = try? await NoteChatIndex.index(note, embedder: embedder) else { break }
            if indexed.embedderFailed {
                Self.logger.info("Indexing notes for Chat without embeddings, as the embedder failed")
                embedder = nil
            }
            self.index?.insert(indexed)
            await progress(done + 1, pending.count)
            if (done + 1) % Self.notesPerSave == 0 { save() }
        }
        save()
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
        let loaded = (try? Data(contentsOf: fileURL)).map(NoteChatIndex.decoded(from:)) ?? NoteChatIndex()
        index = loaded
        return loaded
    }

    private func save() {
        guard let index else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try index.encoded().write(to: fileURL, options: .atomic)
        } catch {
            // The next launch reads the notes again.
            Self.logger.error("Couldn't save the Chat index: \(error.localizedDescription, privacy: .public)")
        }
    }
}
