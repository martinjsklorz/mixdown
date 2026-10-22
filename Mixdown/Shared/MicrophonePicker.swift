import MixdownCore
import SwiftUI

/// Picks the microphone to record: none, **System Default**, or a particular one. Shared by
/// Settings and the setup assistant; the menus use `DevicePicker`.
struct MicrophonePicker: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let microphones = environment.coordinator.devices.filter { $0.kind == .microphone }

        Picker(
            "Microphone",
            selection: Binding(
                get: {
                    environment.followsDefaultMicrophone
                        ? AudioInputDevice.defaultMicrophoneID : environment.selectedMicrophone?.id
                },
                set: { id in
                    environment.selectMicrophone(
                        id == AudioInputDevice.defaultMicrophoneID
                            ? .defaultMicrophone : microphones.first(where: { $0.id == id })
                    )
                }
            )
        ) {
            Text("None").tag(String?.none)
            Divider()
            Text(AudioInputDevice.defaultMicrophoneTitle(among: microphones))
                .tag(Optional(AudioInputDevice.defaultMicrophoneID))
            ForEach(microphones) { device in
                Text(device.pickerTitle).tag(Optional(device.id))
            }
        }
    }
}

extension AudioInputDevice {
    /// The device's name, marked if it's the Mac's default input. For this picker and `DevicePicker`.
    var pickerTitle: String {
        isDefault ? "\(name) (Default)" : name
    }

    /// "System Default (AirPods)", naming the microphone it currently stands for.
    static func defaultMicrophoneTitle(among microphones: [AudioInputDevice]) -> String {
        guard let current = microphones.first(where: \.isDefault) else { return "System Default" }
        return "System Default (\(current.name))"
    }
}
