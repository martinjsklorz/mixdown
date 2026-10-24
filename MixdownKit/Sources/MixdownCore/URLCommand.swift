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
}
