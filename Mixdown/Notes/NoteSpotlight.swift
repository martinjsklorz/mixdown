import CoreSpotlight
import Foundation
import MixdownNotes
import UniformTypeIdentifiers
import os

/// Keeps the notes in Spotlight, so a search there finds them down to the line, without opening
/// Mixdown. See `NoteSearchIndex` for what each note becomes; clicking a result opens it (see
/// `AppDelegate`).
///
/// Watches the notes folder for as long as the app runs, not just while the main window is open,
/// so notes recorded with it closed show up too. Only notes that changed since the last update
/// are sent to Spotlight again, across launches too.
@MainActor
final class NoteSpotlight {
    private let index = NoteSpotlightIndex()
    /// The running update, or the watch for changes. Each call to `update(directory:isEnabled:)`
    /// stops it and starts the next once it's done.
    private var task: Task<Void, Never>?

    /// Adds the notes in `directory` to Spotlight and keeps them up to date, or with `isEnabled`
    /// off, takes them out. Without a `directory` (none chosen, or it can't be reached) Spotlight
    /// keeps the notes it has; they're brought up to date once the folder is back.
    func update(directory: URL?, isEnabled: Bool) {
        let previous = task
        previous?.cancel()
        task = Task { [index] in
            await previous?.value
            guard isEnabled else {
                await index.removeAll()
                return
            }
            guard let directory else { return }
            // Started first, so nothing that changes during the first update is missed.
            let changes = NotesFolderWatcher.changes(in: directory)
            await index.update(notesIn: directory)
            for await _ in changes { await index.update(notesIn: directory) }
        }
    }
}

/// The Core Spotlight side of `NoteSpotlight`, off the main thread. Its caller runs one call at a
/// time.
private actor NoteSpotlightIndex {
    /// What the index held after the last update, saved between launches. `token` is also the
    /// index's client state, so an index that was reset, or an update that never finished, is
    /// noticed.
    private struct Saved: Codable {
        var token: String
        var state: NoteSearchIndex.State
    }

    private static let logger = Logger(subsystem: "app.mixdown", category: "Spotlight")
    /// Items go to Spotlight this many at a time; a long meeting has hundreds of lines.
    private static let chunkSize = 500

    private let index = CSSearchableIndex(name: "Notes")
    private let stateURL = URL.applicationSupportDirectory.appending(path: "SpotlightIndex.json")
    /// What the index holds, once checked against it.
    private var state: NoteSearchIndex.State?
    /// The notes read last time, so an update only reads the files that changed.
    private var cache = NoteLibrary.Cache()

    /// Brings the index in line with the notes in `directory`: adds new and changed notes, and
    /// removes notes that are gone. Leaves it alone if the folder can't be read.
    func update(notesIn directory: URL) async {
        let notes: [NoteDocument]
        do {
            notes = try NoteLibrary.loadNotes(in: directory, cache: &cache)
        } catch {
            Self.logger.error("Couldn't read the notes folder for Spotlight: \(error.localizedDescription)")
            return
        }
        let update = NoteSearchIndex.update(from: await checkedState(), to: notes)
        guard !update.isEmpty else { return }

        let token = UUID().uuidString
        // One batch, so the index and its client state change together.
        index.beginBatch()
        if !update.deletedIDs.isEmpty {
            index.deleteSearchableItems(withIdentifiers: update.deletedIDs, completionHandler: nil)
        }
        for start in stride(from: 0, to: update.items.count, by: Self.chunkSize) {
            let chunk = update.items[start..<min(start + Self.chunkSize, update.items.count)]
            index.indexSearchableItems(chunk.map(Self.searchableItem), completionHandler: nil)
        }
        do {
            try await endBatch(clientState: Data(token.utf8))
        } catch {
            Self.logger.error("Couldn't update Spotlight: \(error.localizedDescription)")
            // Some of it may have made it in. The saved state still matches the index's client
            // state, so the next update starts from it and sends the same changes again.
            state = nil
            return
        }
        state = update.state
        save(Saved(token: token, state: update.state))
    }

    /// Takes every note out of Spotlight.
    func removeAll() async {
        state = nil
        try? FileManager.default.removeItem(at: stateURL)
        do {
            try await deleteAll()
        } catch {
            Self.logger.error("Couldn't remove notes from Spotlight: \(error.localizedDescription)")
        }
    }

    // MARK: State

    /// What the index holds: the saved state if the index's client state says it's still right,
    /// else nothing, after emptying the index so it really holds nothing.
    private func checkedState() async -> NoteSearchIndex.State {
        if let state { return state }
        let saved = (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        if let saved, (try? await lastClientState()) == Data(saved.token.utf8) {
            state = saved.state
            return saved.state
        }
        // First run, the index was reset (Spotlight rebuilds its index now and then), or the last
        // update didn't finish: start again.
        do {
            try await deleteAll()
        } catch {
            Self.logger.error("Couldn't empty Spotlight's notes: \(error.localizedDescription)")
        }
        let empty = NoteSearchIndex.State()
        state = empty
        return empty
    }

    private func save(_ saved: Saved) {
        do {
            try FileManager.default.createDirectory(
                at: stateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(saved).write(to: stateURL, options: .atomic)
        } catch {
            // The next launch can't trust the index, so it indexes every note again.
            Self.logger.error("Couldn't save the Spotlight state: \(error.localizedDescription)")
        }
    }

    // MARK: Core Spotlight

    private static func searchableItem(_ item: NoteSearchIndex.Item) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = item.title
        attributes.contentDescription = item.description
        attributes.textContent = item.text
        attributes.contentCreationDate = item.date
        attributes.keywords = item.keywords
        let searchable = CSSearchableItem(uniqueIdentifier: item.id, domainIdentifier: nil, attributeSet: attributes)
        // Items expire after a month unless told otherwise; notes stay until they're deleted.
        searchable.expirationDate = .distantFuture
        return searchable
    }

    private func endBatch(clientState: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            index.endBatch(withClientState: clientState) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func lastClientState() async throws -> Data? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, any Error>) in
            index.fetchLastClientState { data, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: data) }
            }
        }
    }

    private func deleteAll() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            index.deleteAllSearchableItems { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}
