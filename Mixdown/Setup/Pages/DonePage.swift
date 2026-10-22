import KeyboardShortcuts
import SwiftUI

/// The setup assistant's last page: what's ready, and how to start recording.
struct DonePage: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(MainNavigation.self) private var navigation
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let coordinator = environment.coordinator

        SetupPage(
            title: "You're All Set",
            systemImage: "checkmark.seal",
            detail: startHint
        ) {
            Form {
                Section {
                    row("Notes folder", systemImage: "folder", isReady: environment.notesFolder.directory != nil) {
                        Text(environment.notesFolder.status.name ?? "Not chosen")
                    }
                    row("Speech model", systemImage: "waveform", isReady: coordinator.isModelDownloaded) {
                        if case .preparingModel(let progress) = coordinator.phase {
                            Text("Downloading, \(progress.formatted(.percent.precision(.fractionLength(0))))")
                                .monospacedDigit()
                        } else {
                            Text(coordinator.isModelDownloaded ? environment.model.displayName : "Not downloaded")
                        }
                    }
                    row("Inputs", systemImage: "mic", isReady: !coordinator.selectedDevices.isEmpty) {
                        Text(inputsName)
                    }
                } footer: {
                    HStack {
                        Caption("Everything here is in Settings too.")
                        Spacer()
                        Button("Mixdown Help") { navigation.showHelp(using: openWindow) }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    private func row<Value: View>(
        _ title: String,
        systemImage: String,
        isReady: Bool,
        @ViewBuilder value: () -> Value
    ) -> some View {
        LabeledContent {
            HStack {
                value()
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(isReady ? Color.green : Color.orange)
                    .accessibilityLabel(isReady ? "Ready" : "Not ready")
            }
        } label: {
            Label(title, systemImage: systemImage)
        }
    }

    /// How to start recording, with the global shortcut if it's on.
    private var startHint: String {
        let inApp = "Click the red button in Record, or press ⌘R, to start recording."
        guard environment.isRecordingShortcutEnabled,
            let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecording)
        else { return inApp }
        return inApp + " From any other app, press \(shortcut.description)."
    }

    private var inputsName: String {
        var names: [String] = []
        if let microphone = environment.selectedMicrophone { names.append(microphone.name) }
        if environment.recordsSystemAudio { names.append("System Audio") }
        return names.isEmpty ? "None" : names.joined(separator: " + ")
    }
}
