import MixdownCore

/// Creates device IO proc captures for microphones and Core Audio tap captures for system audio.
public struct DefaultAudioCaptureFactory: AudioCaptureFactory {
    public init() {}

    public func makeCapture(for device: AudioInputDevice) throws -> any AudioCapturing {
        switch device.kind {
        case .microphone:
            try MicrophoneCapture(device: device)
        case .systemAudio:
            try SystemAudioCapture()
        }
    }
}
