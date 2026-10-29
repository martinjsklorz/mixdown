import Foundation
import MixdownCore
import MixdownNotes

/// Does what an `Invocation` asks and returns what to print.
struct Runner {
    var invocation: Invocation
    /// The notes folder, worked out only by commands that need it.
    var folder: () throws -> URL
    var app: AppLink = .system
    /// How often `stop --wait` looks for the note.
    var pollInterval: Duration = .seconds(1)

    init(_ invocation: Invocation, app: AppLink = .system) {
        self.invocation = invocation
        self.app = app
        folder = { try NotesFolder.url(option: invocation.folder) }
    }

    func run() async throws -> String {
        switch invocation.command {
        case .help:
            return Help.text
        case .path(nil):
            return try folder().path(percentEncoded: false)
        case .path(let reference?):
            return try note(reference).url.path(percentEncoded: false)
        case .list(let limit, let since, let until):
            let notes = try loadNotes().filter { note in
                if let since, note.createdAt < since { return false }
                if let until, note.createdAt >= until { return false }
                return true
            }
            return output(Array(notes.prefix(limit ?? .max)), empty: "No notes.")
        case .search(let query, let limit):
            let notes = try loadNotes()
            let matches = try NoteLibrary.search(notes, for: query)
            // Newest first, like the list.
            let found = Array(notes.filter { matches[$0.id] != nil }.prefix(limit ?? .max))
            return output(found, matches: matches, empty: "No notes match “\(query)”.")
        case .show(let reference, let part):
            return try show(note(reference), part: part)
        case .app(let command, let wait):
            return try await perform(command, wait: wait)
        }
    }

    // MARK: - Notes

    private func loadNotes() throws -> [NoteDocument] {
        let directory = try folder()
        try NotesFolder.checkExists(directory)
        var cache = NoteLibrary.Cache()
        return try NoteLibrary.loadNotes(in: directory, cache: &cache)
    }

    /// The note `reference` names, as `mixdown://open?note=…` finds it.
    private func note(_ reference: String) throws -> NoteDocument {
        let notes = try loadNotes()
        if let note = NoteLibrary.note(for: reference, in: notes, directory: try folder()) { return note }
        throw NoteNotFound(
            reference: reference,
            similar: notes.filter { $0.title.localizedStandardContains(reference) }
        )
    }

    private func output(
        _ notes: [NoteDocument],
        matches: [NoteDocument.ID: String] = [:],
        empty: String
    ) -> String {
        guard invocation.json else { return notes.isEmpty ? empty : NoteOutput.lines(for: notes, matches: matches) }
        return NoteOutput.json(
            notes.map { note in
                var fields = NoteOutput.Fields(note)
                fields.match = matches[note.id]
                return fields
            }
        )
    }

    private func show(_ note: NoteDocument, part: Invocation.NotePart) throws -> String {
        switch part {
        case .file where invocation.json:
            var fields = NoteOutput.Fields(note)
            fields.body = note.body
            fields.transcript = note.transcriptText
            return NoteOutput.json(fields)
        case .file:
            return String(decoding: try Data(contentsOf: note.url), as: UTF8.self)
        case .transcript:
            return note.transcriptText
        case .section(let name):
            return try NoteOutput.section(name, in: note.body)
        }
    }

    // MARK: - The app

    private func perform(_ command: URLCommand, wait: Bool) async throws -> String {
        // Starting and opening launch Mixdown; the rest would only launch it to do nothing.
        switch command {
        case .startRecording, .toggleRecording, .open: break
        default: guard try app.isRunning() else { throw AppNotRunning() }
        }
        guard wait else {
            // Only opening brings Mixdown forward, so the terminal stays in front for the rest.
            try app.open(command.url, inBackground: command.isInBackground)
            return ""
        }

        let directory = try folder()
        try NotesFolder.checkExists(directory)
        var cache = NoteLibrary.Cache()
        let before = Set(try NoteLibrary.loadNotes(in: directory, cache: &cache).map(\.url))
        try app.open(command.url, inBackground: true)

        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(invocation.timeout)
        while clock.now < deadline {
            try await Task.sleep(for: pollInterval)
            let notes = try NoteLibrary.loadNotes(in: directory, cache: &cache)
            if let note = notes.first(where: { !before.contains($0.url) }) {
                return invocation.json ? NoteOutput.json(NoteOutput.Fields(note)) : note.url.path(percentEncoded: false)
            }
        }
        throw WaitTimedOut(seconds: invocation.timeout)
    }
}

extension URLCommand {
    /// Whether the link is opened without bringing Mixdown forward.
    fileprivate var isInBackground: Bool {
        if case .open = self { false } else { true }
    }
}

/// How the tool reaches the Mixdown app.
struct AppLink: Sendable {
    var isRunning: @Sendable () throws -> Bool
    var open: @Sendable (_ url: URL, _ inBackground: Bool) throws -> Void

    func open(_ url: URL, inBackground: Bool) throws {
        try open(url, inBackground)
    }

    /// Through Launch Services, which hands `mixdown://` links to the app and launches it if need be.
    static let system = AppLink(
        isRunning: {
            let pgrep = try run("/usr/bin/pgrep", ["-x", "-u", "\(getuid())", "Mixdown"], allowFailure: true)
            return pgrep == 0
        },
        open: { url, inBackground in
            _ = try run("/usr/bin/open", (inBackground ? ["-g"] : []) + [url.absoluteString], allowFailure: false)
        }
    )

    /// Runs the tool at `path` and returns its exit status. Throws if it can't run, or if it fails
    /// and `allowFailure` is false.
    private static func run(_ path: String, _ arguments: [String], allowFailure: Bool) throws -> Int32 {
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard allowFailure || process.terminationStatus == 0 else {
            throw AppLinkFailed(command: ([path] + arguments).joined(separator: " "), status: process.terminationStatus)
        }
        return process.terminationStatus
        #else
        throw AppLinkFailed(command: path, status: -1)
        #endif
    }
}

// MARK: - Errors

struct NoteNotFound: Error, CustomStringConvertible {
    var reference: String
    /// Notes whose titles contain `reference`.
    var similar: [NoteDocument]

    var description: String {
        var message = "No note “\(reference)”. Give its path in the notes folder, its full title, or latest."
        if !similar.isEmpty {
            message +=
                " Did you mean:\n"
                + similar.prefix(5).map { "  \(NoteOutput.relativePath(of: $0))" }
                .joined(separator: "\n")
        }
        return message
    }
}

struct AppNotRunning: Error, CustomStringConvertible {
    var description: String { "Mixdown isn't running, so it isn't recording." }
}

struct WaitTimedOut: Error, CustomStringConvertible {
    var seconds: TimeInterval

    var description: String {
        "No new note after \(Int(seconds)) seconds. Mixdown may still be transcribing (try --timeout), "
            + "or it wasn't recording."
    }
}

struct AppLinkFailed: Error, CustomStringConvertible {
    var command: String
    var status: Int32

    var description: String {
        #if os(macOS)
        "\(command) failed (exit status \(status)). Is Mixdown installed?"
        #else
        "Controlling Mixdown needs macOS."
        #endif
    }
}
