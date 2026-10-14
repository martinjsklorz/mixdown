import Foundation

/// Where an input device gets its audio from.
public enum AudioSourceKind: String, Codable, Sendable, CaseIterable {
    /// A hardware or virtual CoreAudio input device (built-in mic, USB interface, …).
    case microphone
    /// Everything the Mac is playing back, captured via ScreenCaptureKit.
    case systemAudio
}

/// A selectable audio source shown in the menu bar device picker.
public struct AudioInputDevice: Identifiable, Hashable, Sendable, Codable {
    /// Identifier for the system-audio pseudo device.
    public static let systemAudioID = "mixdown.system-audio"

    /// Stable identifier. The CoreAudio device UID for microphones, `systemAudioID` for system audio.
    public let id: String
    public let name: String
    public let kind: AudioSourceKind
    /// Whether this is the current system default input device.
    public let isDefault: Bool

    public init(id: String, name: String, kind: AudioSourceKind, isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isDefault = isDefault
    }

    public static let systemAudio = AudioInputDevice(
        id: systemAudioID,
        name: "System Audio",
        kind: .systemAudio
    )
}

/// A block of captured audio in the format every `TranscriptionEngine` consumes:
/// 16 kHz, mono, Float32 PCM in the range -1...1.
public struct AudioChunk: Sendable, Equatable {
    public static let sampleRate: Double = 16_000

    public let samples: [Float]
    /// Offset of the first sample relative to the start of the capture session.
    public let startTime: TimeInterval

    public init(samples: [Float], startTime: TimeInterval) {
        self.samples = samples
        self.startTime = startTime
    }

    public var duration: TimeInterval { Double(samples.count) / Self.sampleRate }
}

/// Enumerates input devices and reports when the set changes (plug/unplug, default switch).
public protocol AudioDeviceProvider: Sendable {
    /// Current devices, including `AudioInputDevice.systemAudio` when system capture is supported.
    func availableDevices() async -> [AudioInputDevice]
    /// Emits the full device list whenever it changes. Finishes when the consumer cancels.
    func deviceUpdates() -> AsyncStream<[AudioInputDevice]>
}

/// A single capture session for one device. Instances are single-use: start once, stop once.
public protocol AudioCapturing: AnyObject, Sendable {
    /// Starts capturing and returns a stream of 16 kHz mono chunks.
    /// Throws `AudioCaptureError` if permission is missing or the device can't be opened.
    /// The stream finishes after `stop()` or throws if the device fails mid-session.
    func start() async throws -> AsyncThrowingStream<AudioChunk, any Error>
    func stop() async
}

/// Creates the right capture implementation for a device.
public protocol AudioCaptureFactory: Sendable {
    func makeCapture(for device: AudioInputDevice) throws -> any AudioCapturing
}

public enum AudioCaptureError: LocalizedError, Equatable, Sendable {
    case microphonePermissionDenied
    case screenCapturePermissionDenied
    case deviceNotFound(String)
    case deviceUnavailable(String)
    case alreadyRunning

    public var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            "Mixdown needs microphone access. Enable it in System Settings › Privacy & Security › Microphone."
        case .screenCapturePermissionDenied:
            "Capturing system audio needs Screen & System Audio Recording access. Enable it in System Settings › Privacy & Security."
        case .deviceNotFound(let name):
            "The audio device “\(name)” is no longer connected."
        case .deviceUnavailable(let reason):
            "The audio device couldn't be opened: \(reason)"
        case .alreadyRunning:
            "A recording is already in progress."
        }
    }
}
