import Foundation
import MixdownCore

/// Wording for inputs that stay silent while recording, and whether the fix is a permission,
/// shared by the Record view and the menu. System audio is usually silent for want of permission; a microphone for being muted.
enum SilentInputWarning {
    /// One line per silent input. "No sound from system audio yet. …"
    static func message(for device: AudioInputDevice) -> String {
        switch device.kind {
        case .systemAudio:
            "No sound from system audio yet. If something is playing, allow Mixdown under "
                + "Screen & System Audio Recording › System Audio Recording Only."
        case .microphone, .file:
            "No sound from \(device.name) yet. Check that it isn't muted."
        }
    }

    /// Short form for the menu: "No sound from system audio".
    static func title(for device: AudioInputDevice) -> String {
        switch device.kind {
        case .systemAudio: "No sound from system audio"
        case .microphone, .file: "No sound from \(device.name)"
        }
    }

    /// Whether the fix is in System Settings: `SystemSettings.Pane.screenAndSystemAudioRecording`.
    static func needsPermission(_ devices: [AudioInputDevice]) -> Bool {
        devices.contains { $0.kind == .systemAudio }
    }
}
