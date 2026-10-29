import Foundation
import MixdownCore

/// What the command line asks for: a command and the options that go with it.
struct Invocation: Equatable {
    enum Command: Equatable {
        /// The newest notes, from `since` (inclusive) until `until` (exclusive), at most `limit`.
        case list(limit: Int?, since: Date?, until: Date?)
        case search(query: String, limit: Int?)
        case show(note: String, part: NotePart)
        /// A note's file, or the notes folder without one.
        case path(note: String?)
        /// A `mixdown://` link for the app. With `wait`, only for stopping, waits until the note is
        /// saved and prints it.
        case app(URLCommand, wait: Bool)
        case help
    }

    /// Which part of a note `show` prints.
    enum NotePart: Equatable {
        /// The whole file, frontmatter and all.
        case file
        /// The transcript as plain text.
        case transcript
        /// The Markdown under a heading, such as `Summary` or `Action Items`.
        case section(String)
    }

    var command: Command
    /// The notes folder, instead of the one Mixdown uses.
    var folder: String?
    var json = false
    /// How long `stop --wait` waits for the note.
    var timeout: TimeInterval = Self.defaultTimeout

    static let defaultLimit = 20
    /// Ten minutes: long enough to transcribe and summarize an hour's recording on most Macs.
    static let defaultTimeout: TimeInterval = 600

    /// Reads `arguments`, without the program's name. Options can come before or after the
    /// command, and `--` ends them, so a search can start with `-`.
    init(arguments: [String]) throws(UsageError) {
        var words: [String] = []
        var folder: String?
        var json = false
        var limit: Int?? = nil
        var since: Date?
        var until: Date?
        var part: NotePart = .file
        var wait = false
        var timeout = Self.defaultTimeout
        var help = false

        var remaining = arguments[...]
        var optionsEnded = false
        while let argument = remaining.popFirst() {
            guard !optionsEnded, argument.hasPrefix("-"), argument != "-" else {
                words.append(argument)
                continue
            }
            // `--name=value` or `--name value`.
            let (name, inlineValue) =
                argument.firstIndex(of: "=").map {
                    (String(argument[..<$0]), String(argument[argument.index(after: $0)...]))
                }
                ?? (argument, nil)
            func value() throws(UsageError) -> String {
                if let inlineValue { return inlineValue }
                guard let next = remaining.popFirst() else { throw UsageError("\(name) needs a value.") }
                return next
            }
            switch name {
            case "--": optionsEnded = true
            case "-h", "--help": help = true
            case "--json": json = true
            case "--folder": folder = try value()
            case "--all": limit = .some(nil)
            case "--limit":
                let text = try value()
                guard let number = Int(text), number >= 0 else {
                    throw UsageError("--limit needs a number, not “\(text)”.")
                }
                limit = number == 0 ? .some(nil) : number
            case "--since": since = try Self.day(try value(), option: name)
            case "--until":
                // The whole day, up to the start of the next.
                let day = try Self.day(try value(), option: name)
                until = Self.calendar.date(byAdding: .day, value: 1, to: day)
            case "--transcript": part = .transcript
            case "--summary": part = .section("Summary")
            case "--section": part = .section(try value())
            case "--wait": wait = true
            case "--timeout":
                let text = try value()
                guard let seconds = TimeInterval(text), seconds > 0, seconds.isFinite else {
                    throw UsageError("--timeout needs a number of seconds, not “\(text)”.")
                }
                timeout = seconds
            default: throw UsageError("Unknown option \(name).")
            }
        }

        self.folder = folder
        self.json = json
        self.timeout = timeout
        if help {
            command = .help
            return
        }
        guard let word = words.first else {
            command = .help
            return
        }
        let name = Self.aliases[word.lowercased()] ?? word.lowercased()
        let rest = words.dropFirst().joined(separator: " ")
        let text = rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : rest
        // Options only some commands take are refused by the others, so a typo isn't ignored.
        func refuse(_ isGiven: Bool, _ option: String) throws(UsageError) {
            if isGiven { throw UsageError("\(option) doesn't go with \(name).") }
        }
        func noArguments() throws(UsageError) {
            if text != nil { throw UsageError("\(name) takes no arguments.") }
        }
        if name != "list" { try refuse(since != nil || until != nil, "--since/--until") }
        if name != "list" && name != "search" { try refuse(limit != nil, "--limit/--all") }
        if name != "show" { try refuse(part != .file, "--transcript/--summary/--section") }
        if name != "stop" { try refuse(wait, "--wait") }
        if json && part != .file {
            throw UsageError("--json has the whole note, so leave out --transcript, --summary and --section.")
        }

        switch name {
        case "list":
            try noArguments()
            command = .list(limit: limit ?? Self.defaultLimit, since: since, until: until)
        case "search":
            guard let text else { throw UsageError("search needs words to look for.") }
            command = .search(query: text, limit: limit ?? Self.defaultLimit)
        case "show": command = .show(note: text ?? "latest", part: part)
        case "path": command = .path(note: text)
        case "start":
            try noArguments()
            command = .app(.startRecording, wait: false)
        case "stop":
            try noArguments()
            command = .app(.stopRecording, wait: wait)
        case "toggle":
            try noArguments()
            command = .app(.toggleRecording, wait: false)
        case "pause":
            try noArguments()
            command = .app(.pauseRecording, wait: false)
        case "resume":
            try noArguments()
            command = .app(.resumeRecording, wait: false)
        case "toggle-pause":
            try noArguments()
            command = .app(.togglePause, wait: false)
        case "mark": command = .app(.markMoment(text: text), wait: false)
        case "open": command = .app(.open(note: text), wait: false)
        case "help": command = .help
        default: throw UsageError("Unknown command “\(word)”.")
        }
    }

    /// Other names for commands, the ones `ls`, `grep` and `cat` would suggest.
    static let aliases = ["ls": "list", "find": "search", "grep": "search", "cat": "show"]

    /// The calendar `--since` and `--until` dates are days of: the Mac's, in its time zone.
    static let calendar = Calendar.current

    /// The start of the day `text`, in `yyyy-MM-dd` form, names.
    private static func day(_ text: String, option: String) throws(UsageError) -> Date {
        guard let match = text.wholeMatch(of: /(\d{4})-(\d{2})-(\d{2})/),
            let year = Int(match.1), let month = Int(match.2), let day = Int(match.3),
            let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
            calendar.dateComponents([.month, .day], from: date) == DateComponents(month: month, day: day)
        else { throw UsageError("\(option) needs a date like 2026-10-24, not “\(text)”.") }
        return date
    }
}

/// The command line doesn't make sense. Exits with 2, after the message and a hint to `--help`.
struct UsageError: Error, Equatable {
    var message: String

    init(_ message: String) {
        self.message = message
    }
}
