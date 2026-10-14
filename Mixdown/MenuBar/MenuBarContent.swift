import MixdownCore
import SwiftUI

/// Contents of the menu-style `MenuBarExtra`. Each view here becomes a native `NSMenuItem`.
struct MenuBarContent: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(MainNavigation.self) private var navigation
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

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
            selectedIDs: Set(coordinator.selectedDevices.map(\.id)),
            isEnabled: !coordinator.isRecording,
            onSelectMicrophone: environment.selectMicrophone,
            onSetSystemAudio: environment.setRecordsSystemAudio
        )

        Divider()

        Button("Open Mixdown") { navigation.show(navigation.destination, using: openWindow) }

        if case .failed(let message) = coordinator.phase {
            Divider()
            Text(message)
            Button("Dismiss") { coordinator.dismissError() }
        }

        Divider()

        Button("Settings…") { navigation.showSettings(using: openSettings) }
            .keyboardShortcut(",")
        Button("Quit Mixdown") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
