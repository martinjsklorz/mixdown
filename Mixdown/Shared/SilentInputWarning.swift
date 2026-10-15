import AppKit
import MixdownCore

/// Wording and the fix for inputs that stay silent while recording, shared by the Record view and
/// the menu. System audio is usually silent for want of permission; a microphone for being muted.
enum SilentInputWarning {
    /// One line per silent input. "No sound from system audio yet. …"
    static func message(for device: AudioInputDevice) -> String {
        switch device.kind {
        case .systemAudio:
            "No sound from system audio yet. If something is playing, allow Mixdown under "
                + "Screen & System Audio Recording › System Audio Recording Only."
        case .microphone:
            "No sound from \(device.name) yet. Check that it isn't muted."
        }
    }

    /// Short form for the menu: "No sound from system audio".
    static func title(for device: AudioInputDevice) -> String {
        switch device.kind {
        case .systemAudio: "No sound from system audio"
        case .microphone: "No sound from \(device.name)"
        }
    }

    static func needsPermission(_ devices: [AudioInputDevice]) -> Bool {
        devices.contains { $0.kind == .systemAudio }
    }

    /// Opens Privacy & Security › Screen & System Audio Recording, which holds the "System Audio
    /// Recording Only" list.
    static func openPrivacySettings() {
        guard
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
