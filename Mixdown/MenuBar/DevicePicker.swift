import MixdownCore
import SwiftUI

/// Input selection as checkmarked menu items: one microphone at a time, and system audio, which
/// can be added on top to record both sides of a call.
///
/// Choosing a microphone replaces the current one; choosing the checked one again turns the
/// microphone off. Either is ignored if it would leave nothing to record.
struct DevicePicker: View {
    let devices: [AudioInputDevice]
    let selectedIDs: Set<String>
    /// Switching inputs mid-recording isn't supported.
    let isEnabled: Bool
    let onSelectMicrophone: @MainActor (AudioInputDevice?) -> Void
    let onSetSystemAudio: @MainActor (Bool) -> Void

    var body: some View {
        let microphones = devices.filter { $0.kind == .microphone }
        let system = devices.filter { $0.kind == .systemAudio }

        if devices.isEmpty {
            Section("Input") {
                Text("No Input Devices")
            }
        }
        if !microphones.isEmpty {
            Section("Microphone") {
                ForEach(microphones) { device in
                    toggle(Self.title(for: device), isOn: selectedIDs.contains(device.id)) { isOn in
                        onSelectMicrophone(isOn ? device : nil)
                    }
                }
            }
        }
        if !system.isEmpty {
            Section("System") {
                ForEach(system) { device in
                    toggle(device.name, isOn: selectedIDs.contains(device.id), set: onSetSystemAudio)
                }
            }
        }
    }

    private func toggle(_ title: String, isOn: Bool, set: @escaping @MainActor (Bool) -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { isOn }, set: { set($0) }))
            .disabled(!isEnabled)
    }

    static func title(for device: AudioInputDevice) -> String {
        device.isDefault ? "\(device.name) (Default)" : device.name
    }
}
