import MixdownCore
import SwiftUI

/// Input selection as checkmarked menu items: one microphone at a time, and system audio, which
/// can be added on top to record both sides of a call.
///
/// **System Default** follows whichever microphone the Mac uses as its input, so connecting
/// AirPods switches to them. Choosing a microphone replaces the current one; choosing the checked
/// one again turns the microphone off. Either is ignored if it would leave nothing to record.
/// While recording, the recording switches over.
struct DevicePicker: View {
    let devices: [AudioInputDevice]
    let selectedIDs: Set<String>
    let followsDefaultMicrophone: Bool
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
                let defaultTitle = AudioInputDevice.defaultMicrophoneTitle(among: microphones)
                toggle(defaultTitle, isOn: followsDefaultMicrophone) { isOn in
                    onSelectMicrophone(isOn ? .defaultMicrophone : nil)
                }
                ForEach(microphones) { device in
                    let isOn = !followsDefaultMicrophone && selectedIDs.contains(device.id)
                    toggle(device.pickerTitle, isOn: isOn) { isOn in
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
    }
}

extension DevicePicker {
    /// The inputs of `environment`'s coordinator, chosen through `environment`, which remembers
    /// the choice.
    @MainActor init(environment: AppEnvironment) {
        let coordinator = environment.coordinator
        self.init(
            devices: coordinator.devices,
            selectedIDs: Set(coordinator.selectedDevices.map(\.id)),
            followsDefaultMicrophone: environment.followsDefaultMicrophone,
            onSelectMicrophone: environment.selectMicrophone,
            onSetSystemAudio: environment.setRecordsSystemAudio
        )
    }
}
