import MixdownCore
import SwiftUI

/// Contents of the menu-style `MenuBarExtra`. Each view here becomes a native `NSMenuItem`.
struct MenuBarContent: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let coordinator = environment.coordinator

        Button(coordinator.isRecording ? "Stop Recording" : "Start Recording") {
            Task { await coordinator.toggleRecording() }
        }
        .keyboardShortcut("r")
        .disabled(!coordinator.canStartRecording && !coordinator.isRecording)

        RecordingStatusView(
            phase: coordinator.phase,
            engineName: coordinator.engineInfo.displayName,
            isModelDownloaded: coordinator.isModelDownloaded,
            timeRemaining: coordinator.preparationTimeRemaining
        )
        if case .preparingModel = coordinator.phase {
            Button("Cancel Download") { coordinator.cancelPreparation() }
        } else if !coordinator.isModelDownloaded && coordinator.isIdle {
            Button("Download Model") {
                Task { await coordinator.prepareEngine() }
            }
        }

        Divider()

        DevicePicker(
            devices: coordinator.devices,
            selectedID: coordinator.selectedDevice?.id,
            isEnabled: !coordinator.isRecording,
            onSelect: environment.selectDevice
        )

        Divider()

        Button("Show Notes") {
            NSApp.activate()
            openWindow(id: NotesView.windowID)
        }
        Button("Open Notes Folder") { environment.openNotesFolder() }
        if coordinator.lastNoteURL != nil {
            Button("Reveal Last Note") { environment.revealLastNote() }
        }

        if case .failed(let message) = coordinator.phase {
            Divider()
            Text(message)
            Button("Dismiss") { coordinator.dismissError() }
        }

        Divider()

        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Button("Quit Mixdown") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
