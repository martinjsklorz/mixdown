import AVFoundation

public enum PermissionStatus: Sendable {
    case notDetermined
    case granted
    case denied
}

/// Microphone (TCC) permission helpers.
public enum AudioPermissions {
    /// Current microphone authorization. `restricted` is reported as `denied`.
    public static func microphoneStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    /// Shows the system prompt if the user hasn't decided yet. Returns whether access is granted.
    public static func requestMicrophoneAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}
