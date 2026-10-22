import Foundation

extension RecordingCoordinator {
    /// Shown only once the note is written; the audio itself is never kept.
    nonisolated static func interruptedMessage(for error: any Error) -> String {
        "Recording stopped early. \(error.localizedDescription) The note has what was recorded until then."
    }

    /// Says the note wasn't saved because of `error`, and will be.
    nonisolated static func unsavedMessage(for error: any Error) -> String {
        let reason =
            if case NoteWritingError.noFolder = error {
                "The notes folder isn't available, so the note hasn't been saved yet."
            } else {
                "The note couldn't be saved yet. \(error.localizedDescription)"
            }
        return "\(reason) Mixdown saves it as soon as it can, or once you choose another folder. "
            + "Keep Mixdown open until then."
    }

    /// Shown once a note is written without the speech of `devices`, whose tracks failed to
    /// transcribe; the audio itself is never kept.
    nonisolated static func untranscribedMessage(for devices: [AudioInputDevice], error: any Error) -> String {
        let names = devices.map(\.name).formatted(.list(type: .and))
        return "Couldn't transcribe \(names). \(error.localizedDescription) The note has the other inputs."
    }

    /// Shown once a note is written without the translation that was asked for.
    nonisolated static func untranslatedMessage(for error: any Error) -> String {
        "The note has no translation. \(error.localizedDescription)"
    }

    /// Shown for an imported file with less audio than a recording needs.
    nonisolated static func tooShortImportMessage(for name: String) -> String {
        "“\(name)” is too short to transcribe. It needs at least half a second of audio."
    }

    nonisolated static let tooShortMessage =
        "The recording was too short to save. Record for at least half a second."
}
