import Foundation

/// What a `mixdown://` link asks Mixdown to do, for launchers and automation tools such as
/// Raycast, Stream Deck and Keyboard Maestro. The app registers the scheme in its Info.plist.
///
/// - `mixdown://toggle`, `mixdown://start`, `mixdown://stop`: start or stop recording.
/// - `mixdown://pause`, `mixdown://resume`, `mixdown://toggle-pause`: pause or resume it.
/// - `mixdown://mark`: marks a moment and opens the field under the notch to write about it.
///   `mixdown://mark?text=…` adds the moment with that text straight away.
/// - `mixdown://open`: brings the Mixdown window forward. `mixdown://open?note=…` opens a note by
///   its path in the notes folder or its title, or the newest note for `latest`.
///
/// The action is the link's host, or its path for `mixdown:toggle`, ignoring case.
public enum URLCommand: Equatable, Sendable {
    case toggleRecording
    case startRecording
    case stopRecording
    case pauseRecording
    case resumeRecording
    case togglePause
    /// With `text`, the moment is added with it rather than opening the field.
    case markMoment(text: String?)
    /// A note, by path or title (see `NoteLibrary.note(for:in:directory:)`), or just the window.
    case open(note: String?)

    public static let scheme = "mixdown"

    /// The command `url` asks for, or `nil` if it isn't a `mixdown://` link or Mixdown doesn't know
    /// the action.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        let action = (components.host.flatMap { $0.isEmpty ? nil : $0 } ?? components.path)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        // Blank values count as missing, so a launcher's empty argument still works.
        func value(_ name: String) -> String? {
            let value = components.queryItems?.first { $0.name.lowercased() == name }?.value
            return value.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        }
        switch action {
        case "toggle": self = .toggleRecording
        case "start": self = .startRecording
        case "stop": self = .stopRecording
        case "pause": self = .pauseRecording
        case "resume": self = .resumeRecording
        case "toggle-pause": self = .togglePause
        case "mark": self = .markMoment(text: value("text"))
        case "open": self = .open(note: value("note"))
        default: return nil
        }
    }

    /// The `mixdown://` link for the command, which `init(url:)` reads back, for the `mixdown`
    /// command-line tool.
    public var url: URL {
        let (action, query): (String, (name: String, value: String)?) =
            switch self {
            case .toggleRecording: ("toggle", nil)
            case .startRecording: ("start", nil)
            case .stopRecording: ("stop", nil)
            case .pauseRecording: ("pause", nil)
            case .resumeRecording: ("resume", nil)
            case .togglePause: ("toggle-pause", nil)
            case .markMoment(let text): ("mark", text.map { ("text", $0) })
            case .open(let note): ("open", note.map { ("note", $0) })
            }
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = action
        if let query {
            // `queryItems` would leave `&`, `=` and `+` as they are, which split or change the value.
            let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#"))
            let value = query.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? query.value
            components.percentEncodedQuery = "\(query.name)=\(value)"
        }
        guard let url = components.url else {
            preconditionFailure("A scheme, a host and an encoded query always make a URL.")
        }
        return url
    }
}

/// What to do for a `URLCommand` (or the global recording shortcut), given what the coordinator is
/// doing; see `RecordingCoordinator.action(for:)`.
public enum URLCommandAction: Equatable, Sendable {
    case startRecording
    case stopRecording
    case pauseRecording
    case resumeRecording
    case togglePause
    /// The command can't be done now: nothing to pause, or busy with a note until recording can
    /// start. A beep says so.
    case beep
    /// Recording can't start for something the user has to do, such as choosing a notes folder;
    /// Record says what.
    case showRecorder
    /// Marks a moment and opens the field under the notch to write about it.
    case markMoment
    /// Adds a moment with `text` where the recording is now.
    case addMoment(at: TimeInterval, text: String)
    case showMainWindow
    case openNote(String)
    /// Already done, like starting while recording, so a script can ask without checking first.
    case nothing
}

extension RecordingCoordinator {
    /// What `command` comes to now. Starting and stopping work like the global shortcut. Starting
    /// while recording, stopping while not, and the like do nothing; pausing, resuming and adding
    /// a moment beep when not recording, like the Mark Moment shortcut. Only opening, and starting
    /// when recording can't start, bring the main window forward.
    public func action(for command: URLCommand) -> URLCommandAction {
        switch command {
        case .toggleRecording: canStopRecording ? .stopRecording : startFromOutside
        case .startRecording: canStopRecording ? .nothing : startFromOutside
        case .stopRecording: canStopRecording ? .stopRecording : .nothing
        // Pausing while paused and resuming while recording are ignored by the coordinator.
        case .pauseRecording: isRecording ? .pauseRecording : .beep
        case .resumeRecording: isRecording ? .resumeRecording : .beep
        case .togglePause: isRecording ? .togglePause : .beep
        case .markMoment(nil): .markMoment
        case .markMoment(let text?): momentTime.map { .addMoment(at: $0, text: text) } ?? .beep
        case .open(nil): .showMainWindow
        case .open(let note?): .openNote(note)
        }
    }

    /// Starting from another app. While busy downloading, transcribing, translating or
    /// summarizing, it beeps, as recording can start once that's done. When recording can't start
    /// for something the user has to do (no notes folder, model or input), it opens Record
    /// instead, which says what.
    private var startFromOutside: URLCommandAction {
        if canStartRecording { .startRecording } else if !isIdle { .beep } else { .showRecorder }
    }
}
