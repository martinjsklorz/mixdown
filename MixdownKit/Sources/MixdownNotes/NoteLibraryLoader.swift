import Foundation

/// Reads the notes folder off the main thread whenever it's asked to, and hands what it read to
/// `publish`, for the app's list of notes. Reads asked for while one is running share one more
/// read after it, and a read that's out of date by the time it's done isn't shown.
@MainActor
public final class NoteLibraryLoader {
    /// Reads the notes in a folder, like `NoteLibrary.loadNotes(in:cache:)`.
    public typealias Load = @Sendable (_ directory: URL, _ cache: inout NoteLibrary.Cache) throws -> [NoteDocument]

    private let load: Load
    /// Shows what a read of `directory` found.
    private let publish: (_ result: Result<[NoteDocument], any Error>, _ directory: URL?) -> Void

    /// The notes read last time, so a reload only reads the files that changed.
    private var cache = NoteLibrary.Cache()
    /// The folder the latest `reload(from:)` asked for.
    private var directory: URL?
    /// Counts calls to `reload(from:)`, and the call the published notes are as new as.
    private(set) var requested = 0
    private var loaded = 0
    /// Reads the folder until the published notes catch up with `requested`. Only one runs at a
    /// time.
    private var loading: Task<Void, Never>?

    public init(
        load: @escaping Load = NoteLibrary.loadNotes,
        publish: @escaping (_ result: Result<[NoteDocument], any Error>, _ directory: URL?) -> Void
    ) {
        self.load = load
        self.publish = publish
    }

    /// Reads the folder again and returns once what's published shows it as it was at the time of
    /// the call or later, so a note written just before can be selected. Calls made while a read
    /// is running share one more read after it.
    ///
    /// Without a `directory` (no notes folder, or it can't be reached) the list is empty.
    public func reload(from directory: URL?) async {
        self.directory = directory
        requested += 1
        let task = loading ?? Task { await loadUntilCurrent() }
        loading = task
        await task.value
    }

    private func loadUntilCurrent() async {
        while loaded < requested {
            let target = requested
            let directory = self.directory
            let cache = self.cache
            let load = self.load
            let (result, newCache) = await Task.detached(priority: .userInitiated) {
                var cache = cache
                guard let directory else { return (Result<[NoteDocument], any Error>.success([]), cache) }
                return (Result { try load(directory, &cache) }, cache)
            }.value
            self.cache = newCache
            // Asked again meanwhile: the next pass shows the newer state, without briefly
            // showing this one (e.g. a note just moved to the Trash).
            guard requested == target else { continue }
            publish(result, directory)
            loaded = target
        }
        loading = nil
    }
}
