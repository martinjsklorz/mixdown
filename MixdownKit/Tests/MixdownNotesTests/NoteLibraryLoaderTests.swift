import Dispatch
import Foundation
import Synchronization
import Testing

@testable import MixdownNotes

/// A notes folder whose reads wait until the test lets them finish. Each read finds one note,
/// titled with the read's number and the folder's name.
private final class StubFolder: Sendable {
    struct Failure: Error {}

    let reads = Mutex<[URL]>([])
    let starts: AsyncStream<URL>
    private let started: AsyncStream<URL>.Continuation
    private let finish = DispatchSemaphore(value: 0)
    private let failing: URL?

    init(failing: URL? = nil) {
        (starts, started) = AsyncStream.makeStream()
        self.failing = failing
    }

    /// Lets the read that's waiting finish.
    func finishRead() {
        finish.signal()
    }

    func load(_ directory: URL, _ cache: inout NoteLibrary.Cache) throws -> [NoteDocument] {
        let number = reads.withLock { reads in
            reads.append(directory)
            return reads.count
        }
        started.yield(directory)
        finish.wait()
        if directory == failing { throw Failure() }
        let title = "Read \(number) of \(directory.lastPathComponent)"
        return [NoteDocument(url: directory.appending(path: "\(number).md"), contents: "# \(title)", fileDate: .now)]
    }
}

/// What the loader published, in order.
@MainActor
private final class Published {
    var titles: [[String]] = []
    var directories: [URL?] = []
    var failures = 0

    func publish(_ result: Result<[NoteDocument], any Error>, _ directory: URL?) {
        switch result {
        case .success(let notes): titles.append(notes.map(\.title))
        case .failure: failures += 1
        }
        directories.append(directory)
    }
}

@MainActor @Suite(.serialized)
struct NoteLibraryLoaderTests {
    private let folder = URL(filePath: "/notes/Main")
    private let otherFolder = URL(filePath: "/notes/Other")

    private func makeLoader(_ stub: StubFolder, _ published: Published) -> NoteLibraryLoader {
        NoteLibraryLoader(load: stub.load) { published.publish($0, $1) }
    }

    /// Waits until `loader` has been asked for `count` reloads in all.
    private func waitForRequests(_ count: Int, of loader: NoteLibraryLoader) async {
        while loader.requested < count { await Task.yield() }
    }

    @Test func reloadsAskedForDuringAReadShareOneMoreAndTheStaleReadIsNotShown() async {
        let stub = StubFolder()
        let published = Published()
        let loader = makeLoader(stub, published)
        var starts = stub.starts.makeAsyncIterator()

        let first = Task { await loader.reload(from: folder) }
        _ = await starts.next()
        let second = Task { await loader.reload(from: folder) }
        let third = Task { await loader.reload(from: folder) }
        await waitForRequests(3, of: loader)
        stub.finishRead()
        _ = await starts.next()
        // The first read is out of date, so nothing is shown yet.
        #expect(published.titles.isEmpty)
        stub.finishRead()
        for task in [first, second, third] { await task.value }

        #expect(stub.reads.withLock { $0.count } == 2)
        #expect(published.titles == [["Read 2 of Main"]])
    }

    @Test func reloadReturnsOnlyAfterAReadThatStartedAfterIt() async {
        let stub = StubFolder()
        let published = Published()
        let loader = makeLoader(stub, published)
        var starts = stub.starts.makeAsyncIterator()

        let first = Task { await loader.reload(from: folder) }
        _ = await starts.next()
        let second = Task {
            await loader.reload(from: folder)
            // What's shown by the time it returns.
            return published.titles.last
        }
        await waitForRequests(2, of: loader)
        stub.finishRead()
        _ = await starts.next()
        stub.finishRead()

        #expect(await second.value == ["Read 2 of Main"])
        await first.value
    }

    @Test func reloadAfterAReadIsDoneReadsAgain() async {
        let stub = StubFolder()
        let published = Published()
        let loader = makeLoader(stub, published)
        var starts = stub.starts.makeAsyncIterator()

        for _ in 1...2 {
            let reload = Task { await loader.reload(from: folder) }
            _ = await starts.next()
            stub.finishRead()
            await reload.value
        }

        #expect(published.titles == [["Read 1 of Main"], ["Read 2 of Main"]])
    }

    @Test func changingTheFolderDropsWhatWasReadOfTheOldOne() async {
        let stub = StubFolder()
        let published = Published()
        let loader = makeLoader(stub, published)
        var starts = stub.starts.makeAsyncIterator()

        let old = Task { await loader.reload(from: folder) }
        _ = await starts.next()
        let new = Task { await loader.reload(from: otherFolder) }
        await waitForRequests(2, of: loader)
        stub.finishRead()
        #expect(await starts.next() == otherFolder)
        stub.finishRead()
        await old.value
        await new.value

        #expect(published.titles == [["Read 2 of Other"]])
        #expect(published.directories == [otherFolder])
    }

    @Test func withoutAFolderThereAreNoNotes() async {
        let stub = StubFolder()
        let published = Published()
        let loader = makeLoader(stub, published)

        await loader.reload(from: nil)

        #expect(stub.reads.withLock { $0.isEmpty })
        #expect(published.titles == [[]])
        #expect(published.directories == [nil])
    }

    @Test func aFolderThatCantBeReadIsPublishedAsAFailure() async {
        let stub = StubFolder(failing: folder)
        let published = Published()
        let loader = makeLoader(stub, published)
        var starts = stub.starts.makeAsyncIterator()

        let reload = Task { await loader.reload(from: folder) }
        _ = await starts.next()
        stub.finishRead()
        await reload.value

        #expect(published.failures == 1)
        #expect(published.titles.isEmpty)
    }
}
