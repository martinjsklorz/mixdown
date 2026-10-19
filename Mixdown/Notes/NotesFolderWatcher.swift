import CoreServices
import Foundation
import MixdownNotes
import os

/// Reports changes to the notes in a folder as they happen, from FSEvents: notes added, removed,
/// renamed or edited, by Mixdown or any other app.
///
/// FSEvents rather than a `DispatchSource` on the folder, which only notices files being added,
/// removed or renamed, not edits inside one. It works in the sandbox for any folder the app can
/// access, so the notes folder's bookmark is enough.
enum NotesFolderWatcher {
    private static let logger = Logger(subsystem: "app.mixdown", category: "NotesFolderWatcher")

    /// An element per batch of changes, at most one per `latency` seconds, until the task
    /// iterating it is cancelled. Covers subfolders too. Changes to files that aren't notes, like
    /// `.DS_Store` or an editor's temporary files, and to hidden folders like `.obsidian` are
    /// left out. Batches that arrive while the last one is still being handled are merged into one.
    static func changes(in directory: URL, latency: TimeInterval = 0.3) -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            guard let stream = EventStream(directory: directory, latency: latency, continuation: continuation) else {
                logger.error("Couldn't watch the notes folder for changes")
                continuation.finish()
                return
            }
            continuation.onTermination = { _ in stream.stop() }
        }
    }
}

/// An `FSEventStream` with per-file events on one folder, delivered on a queue of its own.
///
/// Kept alive by the stream's `onTermination` until `stop()`, so the event stream's context
/// doesn't retain it.
private final class EventStream: @unchecked Sendable {
    private let continuation: AsyncStream<Void>.Continuation
    private let directory: URL
    private let queue = DispatchQueue(label: "app.mixdown.NotesFolderWatcher")
    /// Only touched on `queue` once started.
    private var stream: FSEventStreamRef?

    init?(directory: URL, latency: TimeInterval, continuation: AsyncStream<Void>.Continuation) {
        self.continuation = continuation
        self.directory = directory
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, count, paths, flags, _ in
                guard let info else { return }
                Unmanaged<EventStream>.fromOpaque(info).takeUnretainedValue()
                    .handle(count: count, paths: paths, flags: flags)
            },
            &context,
            [directory.path(percentEncoded: false)] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        )
        guard let created else { return nil }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return nil
        }
        stream = created
    }

    /// Stops and releases the event stream. On its queue, so no callback runs during or after.
    func stop() {
        queue.async {
            guard let stream = self.stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    private func handle(
        count: Int,
        paths: UnsafeMutableRawPointer,
        flags: UnsafePointer<FSEventStreamEventFlags>
    ) {
        // A `CFArray` of `CFString`s, with `kFSEventStreamCreateFlagUseCFTypes`.
        let paths = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
        // Events were dropped or coalesced, so the folder has to be read again whatever the paths.
        let mustRescan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
        let isDirectory = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)
        let changesNotes = (0..<count).contains { index in
            guard flags[index] & mustRescan == 0 else { return true }
            guard paths.indices.contains(index) else { return false }
            return NoteLibrary.affectsNotes(
                URL(fileURLWithPath: paths[index]),
                isDirectory: flags[index] & isDirectory != 0,
                in: directory
            )
        }
        if changesNotes { continuation.yield() }
    }
}
