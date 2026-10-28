import Foundation

/// Where an input device gets its audio from.
public enum AudioSourceKind: String, Sendable {
    /// A hardware or virtual CoreAudio input device (built-in mic, USB interface, …).
    case microphone
    /// Everything the Mac is playing back, captured via a Core Audio process tap.
    case systemAudio
    /// An audio or video file the user imported. Never in a device list or recorded from.
    case file
}

/// A selectable audio source shown in the menu bar device picker. Several can record at once.
public struct AudioInputDevice: Identifiable, Hashable, Sendable {
    /// Identifier for the system-audio pseudo device.
    public static let systemAudioID = "mixdown.system-audio"
    /// Identifier for the default-microphone pseudo device.
    public static let defaultMicrophoneID = "mixdown.default-microphone"

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

    /// Stands for whichever microphone macOS uses as its default input. Selecting it makes the
    /// selection follow the default, also mid-recording, e.g. to AirPods when they connect. Never
    /// in a device list; the selection holds the actual default microphone instead.
    public static let defaultMicrophone = AudioInputDevice(
        id: defaultMicrophoneID,
        name: "System Default",
        kind: .microphone
    )
}

/// A block of captured audio in the format every `TranscriptionEngine` consumes:
/// 16 kHz, mono, Float32 PCM in the range -1...1.
public struct AudioChunk: Sendable, Equatable {
    public static let sampleRate: Double = 16_000

    public let samples: [Float]
    /// When the first sample was captured, in seconds on the host clock (`mach_absolute_time`).
    /// Lines up chunks from different sources and reveals gaps. `nil` if the capture can't tell.
    public let hostTime: TimeInterval?

    public init(samples: [Float], hostTime: TimeInterval? = nil) {
        self.samples = samples
        self.hostTime = hostTime
    }

    public var duration: TimeInterval { Double(samples.count) / Self.sampleRate }
}

/// Enumerates input devices and reports when the set changes (plug/unplug, default switch).
public protocol AudioDeviceProvider: Sendable {
    /// Current devices, including `AudioInputDevice.systemAudio` when system capture is supported.
    func availableDevices() async -> [AudioInputDevice]
    /// Emits the current device list, then the full list whenever it changes. Finishes when the
    /// consumer cancels.
    func deviceUpdates() -> AsyncStream<[AudioInputDevice]>
}

/// Tells whether other apps are playing audio. A system audio tap delivers silence both when
/// nothing plays and when the permission is missing; this tells the two apart.
public protocol AudioPlaybackMonitoring: Sendable {
    /// Whether a process other than Mixdown is playing audio right now.
    func isOtherAudioPlaying() async -> Bool
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
    case deviceNotFound(String)
    case deviceUnavailable(String)
    /// The macOS audio service (`coreaudiod`) restarted, which ends every capture. The device
    /// itself may still be there.
    case audioServiceRestarted
    case alreadyRunning

    public var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            "Mixdown needs microphone access. Enable it in System Settings › Privacy & Security › Microphone."
        case .deviceNotFound(let name):
            "The audio device “\(name)” is no longer connected."
        case .deviceUnavailable(let reason):
            "The audio device couldn't be opened: \(reason)"
        case .audioServiceRestarted:
            "The macOS audio service restarted."
        case .alreadyRunning:
            "A recording is already in progress."
        }
    }
}
