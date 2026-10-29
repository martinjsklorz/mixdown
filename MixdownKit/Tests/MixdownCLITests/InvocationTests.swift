import Foundation
import MixdownCore
import Testing

@testable import MixdownCLI

struct InvocationTests {
    private func command(_ arguments: String...) throws -> Invocation.Command {
        try Invocation(arguments: arguments).command
    }

    private func usageError(_ arguments: String...) -> String? {
        do {
            _ = try Invocation(arguments: arguments)
            return nil
        } catch {
            return error.message
        }
    }

    @Test func listsTheNewestTwentyByDefault() throws {
        #expect(try command("list") == .list(limit: 20, since: nil, until: nil))
        #expect(try command("ls", "--limit", "5") == .list(limit: 5, since: nil, until: nil))
        #expect(try command("list", "--all") == .list(limit: nil, since: nil, until: nil))
        #expect(try command("list", "--limit=0") == .list(limit: nil, since: nil, until: nil))
    }

    @Test func readsDaysAsWholeDaysInTheMacsTimeZone() throws {
        let calendar = Invocation.calendar
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 20)))
        let end = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 25)))
        #expect(
            try command("list", "--since", "2026-10-20", "--until=2026-10-24")
                == .list(limit: 20, since: start, until: end)
        )
        #expect(
            usageError("list", "--since", "2026-02-30") == "--since needs a date like 2026-10-24, not “2026-02-30”."
        )
        #expect(usageError("list", "--until", "yesterday") != nil)
        #expect(usageError("list", "--since", "2026-1-024") != nil)
    }

    @Test func joinsTheWordsOfSearchesAndTitles() throws {
        #expect(try command("search", "release", "date") == .search(query: "release date", limit: 20))
        #expect(try command("grep", "--", "-v") == .search(query: "-v", limit: 20))
        #expect(try command("show", "Weekly", "Sync") == .show(note: "Weekly Sync", part: .file))
        #expect(try command("show") == .show(note: "latest", part: .file))
        #expect(try command("cat", "latest", "--summary") == .show(note: "latest", part: .section("Summary")))
        #expect(
            try command("show", "--section", "Action Items") == .show(note: "latest", part: .section("Action Items"))
        )
        #expect(try command("show", "--transcript", "Standup") == .show(note: "Standup", part: .transcript))
        #expect(usageError("search") == "search needs words to look for.")
    }

    @Test func readsOptionsAnywhere() throws {
        let invocation = try Invocation(arguments: ["--json", "list", "--folder", "~/Notes"])
        #expect(invocation.json)
        #expect(invocation.folder == "~/Notes")
        #expect(try Invocation(arguments: ["path", "--folder=/tmp/x"]).folder == "/tmp/x")
    }

    @Test func controlsTheAppWithLinks() throws {
        #expect(try command("start") == .app(.startRecording, wait: false))
        #expect(try command("STOP", "--wait") == .app(.stopRecording, wait: true))
        #expect(try command("toggle") == .app(.toggleRecording, wait: false))
        #expect(try command("pause") == .app(.pauseRecording, wait: false))
        #expect(try command("resume") == .app(.resumeRecording, wait: false))
        #expect(try command("toggle-pause") == .app(.togglePause, wait: false))
        #expect(try command("mark") == .app(.markMoment(text: nil), wait: false))
        #expect(try command("mark", "Budget", "approved") == .app(.markMoment(text: "Budget approved"), wait: false))
        #expect(try command("open") == .app(.open(note: nil), wait: false))
        #expect(try command("open", "latest") == .app(.open(note: "latest"), wait: false))
        #expect(try Invocation(arguments: ["stop", "--wait", "--timeout", "90"]).timeout == 90)
    }

    @Test func showsHelpWithoutACommand() throws {
        #expect(try command() == .help)
        #expect(try command("help") == .help)
        #expect(try command("list", "-h") == .help)
    }

    @Test func refusesWhatDoesntFit() {
        #expect(usageError("record") == "Unknown command “record”.")
        #expect(usageError("list", "--verbose") == "Unknown option --verbose.")
        #expect(usageError("list", "--folder") == "--folder needs a value.")
        #expect(usageError("list", "--limit", "-1") == "--limit needs a number, not “-1”.")
        #expect(usageError("list", "extra") == "list takes no arguments.")
        #expect(usageError("start", "--wait") == "--wait doesn't go with start.")
        #expect(usageError("search", "x", "--since", "2026-10-01") == "--since/--until doesn't go with search.")
        #expect(usageError("show", "--limit", "3") == "--limit/--all doesn't go with show.")
        #expect(usageError("list", "--summary") == "--transcript/--summary/--section doesn't go with list.")
        #expect(usageError("show", "--json", "--transcript") != nil)
        #expect(usageError("stop", "--wait", "--timeout", "0") != nil)
    }
}
