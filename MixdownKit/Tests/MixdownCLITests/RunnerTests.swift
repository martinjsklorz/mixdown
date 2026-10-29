import Foundation
import MixdownCore
import Synchronization
import Testing

@testable import MixdownCLI

/// Stands in for the Mixdown app.
private final class FakeApp: Sendable {
    /// The links the commands opened, and whether in the background.
    let opened = Mutex<[(url: URL, inBackground: Bool)]>([])
    let isRunning = Mutex(true)

    var link: AppLink {
        AppLink(
            isRunning: { self.isRunning.withLock { $0 } },
            open: { url, inBackground in self.opened.withLock { $0.append((url, inBackground)) } }
        )
    }
}

/// Runs commands on a notes folder of their own, with the app faked.
final class RunnerTests {
    private let folder: URL
    private let app = FakeApp()

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(
            path: "MixdownCLITests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try write(
            "2026-10-17 0930 Weekly Sync.md",
            title: "Weekly Sync",
            created: "2026-10-17T09:30:00Z",
            text: "Budget talk."
        )
        try write(
            "2026-10-23 1400 Standup.md",
            title: "Standup",
            created: "2026-10-23T14:00:00Z",
            text: "Release on Friday."
        )
        try write(
            "Clients/Acme/2026-10-24 0930 Weekly Sync.md",
            title: "Weekly Sync",
            created: "2026-10-24T09:30:00Z",
            text: "The release moves to Friday."
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    private func write(_ path: String, title: String, created: String, text: String) throws {
        let url = folder.appending(path: path, directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let contents = """
            ---
            title: "\(title)"
            created: \(created)
            duration: 60
            ---

            # \(title)

            ## Summary

            \(text)

            ## Transcript

            **[00:00:00] Me:** \(text)
            """
        try Data(contents.utf8).write(to: url)
    }

    private func run(_ arguments: String...) async throws -> String {
        var runner = Runner(
            try Invocation(arguments: arguments + ["--folder", folder.path(percentEncoded: false)]),
            app: app.link
        )
        runner.pollInterval = .milliseconds(20)
        return try await runner.run()
    }

    private func names(_ output: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            line.firstMatch(of: /\(([^)]+)\)$/).map { String($0.1) }
        }
    }

    @Test func listsTheNewestFirst() async throws {
        #expect(
            names(try await run("list")) == [
                "Clients/Acme/2026-10-24 0930 Weekly Sync.md", "2026-10-23 1400 Standup.md",
                "2026-10-17 0930 Weekly Sync.md",
            ]
        )
        #expect(names(try await run("list", "--limit", "1")) == ["Clients/Acme/2026-10-24 0930 Weekly Sync.md"])
    }

    @Test func listsTheNotesOfSomeDays() async throws {
        // Days in the Mac's time zone, so leave a day either side.
        let notes = try await run("list", "--since", "2026-10-19", "--until", "2026-10-21")
        #expect(notes == "No notes.")
        #expect(names(try await run("list", "--since", "2026-10-22")).count == 2)
        #expect(names(try await run("list", "--until", "2026-10-18")) == ["2026-10-17 0930 Weekly Sync.md"])
    }

    @Test func searchesWithTheMatchingLine() async throws {
        let output = try await run("search", "release", "friday")
        #expect(names(output) == ["Clients/Acme/2026-10-24 0930 Weekly Sync.md", "2026-10-23 1400 Standup.md"])
        #expect(output.contains("\n    The release moves to Friday."))
        #expect(try await run("search", "nothing like it") == "No notes match “nothing like it”.")
    }

    @Test func searchesInJSON() async throws {
        let output = try await run("search", "budget", "--json")
        let notes = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]]
        #expect(notes?.count == 1)
        #expect(notes?.first?["relative_path"] as? String == "2026-10-17 0930 Weekly Sync.md")
        #expect(notes?.first?["match"] as? String == "Budget talk.")
        let none = try await run("search", "nothing", "--json")
        #expect((try JSONSerialization.jsonObject(with: Data(none.utf8)) as? [Any])?.isEmpty == true)
    }

    @Test func showsNotesByTitlePathOrLatest() async throws {
        let latest = try await run("show")
        #expect(latest.hasPrefix("---\ntitle: \"Weekly Sync\"\ncreated: 2026-10-24"))
        #expect(try await run("show", "standup", "--summary") == "Release on Friday.")
        #expect(try await run("show", "2026-10-17 0930 Weekly Sync", "--transcript") == "[00:00:00] Me: Budget talk.")
        let path = try await run("path", "Clients/Acme/2026-10-24 0930 Weekly Sync.md")
        #expect(path.hasSuffix("/Clients/Acme/2026-10-24 0930 Weekly Sync.md"))
        #expect(try await run("path") == folder.path(percentEncoded: false))
    }

    @Test func showsTheWholeNoteInJSON() async throws {
        let output = try await run("show", "Standup", "--json")
        let note = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        #expect(note?["title"] as? String == "Standup")
        #expect((note?["body"] as? String)?.contains("## Summary") == true)
        #expect(note?["transcript"] as? String == "[00:00:00] Me: Release on Friday.")
    }

    @Test func suggestsNotesWhoseTitlesContainTheWords() async throws {
        await #expect {
            try await run("show", "weekly")
        } throws: { error in
            let message = String(describing: error)
            return message.contains("No note “weekly”") && message.contains("  2026-10-17 0930 Weekly Sync.md")
        }
    }

    @Test func saysWhenTheFolderIsMissing() async throws {
        try FileManager.default.removeItem(at: folder)
        await #expect(throws: FolderError.missing(folder.path(percentEncoded: false))) { try await run("list") }
    }

    @Test func opensLinksInTheBackgroundExceptForOpen() async throws {
        _ = try await run("start")
        _ = try await run("mark", "Budget", "&", "dates")
        _ = try await run("open", "latest")
        let links = app.opened.withLock { $0 }
        #expect(
            links.map(\.url.absoluteString) == [
                "mixdown://start", "mixdown://mark?text=Budget%20%26%20dates", "mixdown://open?note=latest",
            ]
        )
        #expect(links.map(\.inBackground) == [true, true, false])
    }

    @Test func doesntLaunchTheAppJustToStop() async throws {
        app.isRunning.withLock { $0 = false }
        await #expect(throws: AppNotRunning.self) { try await run("stop") }
        await #expect(throws: AppNotRunning.self) { try await run("pause") }
        _ = try await run("toggle")
        #expect(app.opened.withLock { $0.map(\.url.absoluteString) } == ["mixdown://toggle"])
    }

    @Test func waitsForTheNoteAfterStopping() async throws {
        let (folder, app) = (folder, app)
        let writer = Task {
            // Once the stop link is sent, like Mixdown saving the note a while later.
            while app.opened.withLock({ $0.isEmpty }) { try await Task.sleep(for: .milliseconds(5)) }
            try await Task.sleep(for: .milliseconds(50))
            try Data("# Fresh\n".utf8).write(to: folder.appending(path: "2026-10-29 1000 Fresh.md"))
        }
        let path = try await run("stop", "--wait", "--timeout", "5")
        try await writer.value
        #expect(path.hasSuffix("/2026-10-29 1000 Fresh.md"))
    }

    @Test func givesUpWaitingAfterTheTimeout() async throws {
        await #expect(throws: WaitTimedOut.self) { try await run("stop", "--wait", "--timeout", "0.1") }
    }
}
