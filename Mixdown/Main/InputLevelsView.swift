import MixdownCore
import SwiftUI

/// A level meter per input of the running recording, and a warning for inputs that stay silent.
///
/// Its own view so the levels, which change about ten times a second, only redraw the meters
/// and not the rest of the Record view.
struct InputLevelsView: View {
    let coordinator: RecordingCoordinator

    var body: some View {
        let devices = coordinator.selectedDevices
        let levels = coordinator.inputLevels
        let silent = coordinator.silentDevices

        VStack(spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                ForEach(devices) { device in
                    GridRow {
                        Image(systemName: device.kind == .systemAudio ? "speaker.wave.2" : "mic")
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                            .help(device.name)
                        LevelBar(value: levels[device.id]?.meterValue ?? 0)
                            .accessibilityLabel("\(device.name) level")
                    }
                }
            }
            .frame(maxWidth: 260)

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

/// A thin horizontal meter, 0...1.
private struct LevelBar: View {
    let value: Double

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(.quaternary)
            .overlay(alignment: .leading) {
                // Scaling rather than resizing keeps each update to a cheap render, no layout.
                RoundedRectangle(cornerRadius: 2)
                    .fill(value > 0.95 ? Color.red : Color.green)
                    .scaleEffect(x: value, anchor: .leading)
                    .animation(.linear(duration: 0.1), value: value)
            }
            .frame(height: 6)
            .accessibilityValue("\(Int((value * 100).rounded())) percent")
    }
}
