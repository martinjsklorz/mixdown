import Foundation

extension RecordingCoordinator {
    /// Shown only once the note is written.
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
    /// transcribe.
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

    /// Added to the failure of `recording`, now one of `unfinishedRecordings`.
    nonisolated static func keptRecordingMessage(for recording: UnfinishedRecording) -> String {
        recording.isOnDisk
            ? "Mixdown kept the recording, so you can transcribe it again from Record."
            : "Mixdown kept the recording until it quits, so you can transcribe it again from Record."
    }

    /// Shown when an unfinished recording's audio can't be read back.
    nonisolated static func unreadableRecordingMessage(for error: any Error) -> String {
        "Couldn't read the recording. \(error.localizedDescription)"
    }

    nonisolated static let tooShortMessage =
        "The recording was too short to save. Record for at least half a second."
}
