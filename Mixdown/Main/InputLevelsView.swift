import MixdownCore
import SwiftUI

/// The running recording's inputs as one waveform, the same as in the Dynamic Island, and a warning
/// for inputs that stay silent.
///
/// Its own view so the levels, which change about ten times a second, only redraw the waveform
/// and not the rest of the Record view.
struct InputLevelsView: View {
    let coordinator: RecordingCoordinator

    var body: some View {
        let silent = coordinator.silentDevices

        VStack(spacing: 12) {
            LevelWaveform(coordinator: coordinator, isSilent: !silent.isEmpty, scale: 2)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Input level")

            if !silent.isEmpty {
                VStack(spacing: 8) {
                    ForEach(silent) { device in
                        Label(SilentInputWarning.message(for: device), systemImage: "speaker.slash")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }
                    if SilentInputWarning.needsPermission(silent) {
                        Button("Open Privacy Settings…") { SilentInputWarning.openPrivacySettings() }
                            .controlSize(.small)
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.default, value: silent)
    }
}
