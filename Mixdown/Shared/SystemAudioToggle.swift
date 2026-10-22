import MixdownCore
import SwiftUI

/// Whether to record system audio, besides the microphone. Only there if the coordinator offers
/// system audio. Shared by Settings and the setup assistant; the menus use `DevicePicker`.
struct SystemAudioToggle: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        if environment.coordinator.devices.contains(where: { $0.kind == .systemAudio }) {
            Toggle(
                "Record system audio",
                isOn: Binding(
                    get: { environment.recordsSystemAudio },
                    set: { environment.setRecordsSystemAudio($0) }
                )
            )
        }
    }
}
