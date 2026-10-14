import MixdownCore
import SwiftUI

/// Input selection as checkmarked menu items, grouped into microphones and system audio.
struct DevicePicker: View {
    let devices: [AudioInputDevice]
    let selectedID: String?
    /// Switching inputs mid-recording isn't supported.
    let isEnabled: Bool
    let onSelect: @MainActor (AudioInputDevice) -> Void

    var body: some View {
        let microphones = devices.filter { $0.kind == .microphone }
        let system = devices.filter { $0.kind == .systemAudio }

        if devices.isEmpty {
            Section("Input") {
                Text("No Input Devices")
            }
        }
        if !microphones.isEmpty {
            Section("Microphones") { picker("Microphones", options: microphones) }
        }
        if !system.isEmpty {
            Section("System") { picker("System", options: system) }
        }
    }

    // Two inline pickers share one selection so each group gets its own header while only one
    // item is ever checked.
    private func picker(_ title: String, options: [AudioInputDevice]) -> some View {
        Picker(title, selection: selection) {
            ForEach(options) { device in
                Text(Self.title(for: device)).tag(Optional(device.id))
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
        .disabled(!isEnabled)
    }

    private var selection: Binding<String?> {
        Binding(
            get: { selectedID },
            set: { id in
                guard let device = devices.first(where: { $0.id == id }) else { return }
                onSelect(device)
            }
        )
    }

    static func title(for device: AudioInputDevice) -> String {
        device.isDefault ? "\(device.name) (Default)" : device.name
    }
}
