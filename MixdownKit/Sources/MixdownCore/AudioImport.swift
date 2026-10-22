import Foundation

/// The audio of a file, ready to transcribe like a recording's.
public struct DecodedAudio: Sendable, Equatable {
    /// 16 kHz mono Float32 samples (see `AudioChunk.sampleRate`), all of the file's audio tracks
    /// mixed together.
    public var samples: [Float]
    /// When the file was recorded, if it says, else when it was created.
    public var recordedAt: Date?

    public init(samples: [Float], recordedAt: Date? = nil) {
        self.samples = samples
        self.recordedAt = recordedAt
    }

    public var duration: TimeInterval { Double(samples.count) / AudioChunk.sampleRate }
}

/// Reads audio and video files for `RecordingCoordinator.importAudio(from:)`.
public protocol AudioFileDecoding: Sendable {
    /// The audio of the file at `url`. Throws `AudioImportError` if it has none or can't be read.
    /// Honors task cancellation.
    func decode(_ url: URL) async throws -> DecodedAudio
}

public enum AudioImportError: LocalizedError, Equatable, Sendable {
    /// The file has no audio track, e.g. a video without sound.
    case noAudio(String)
    /// The file isn't in a format macOS can read, or is damaged.
    case unreadable(String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .noAudio(let name):
            "“\(name)” has no audio."
        case .unreadable(let name, let reason):
            "“\(name)” couldn't be read. \(reason)"
        }
    }
}

extension AudioInputDevice {
    /// The source of a note imported from the file at `url`, named after it.
    public static func importedFile(at url: URL) -> AudioInputDevice {
        AudioInputDevice(id: url.absoluteString, name: url.lastPathComponent, kind: .file)
    }
}
