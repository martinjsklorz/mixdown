import KeyboardShortcuts
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

        RecordingControls(environment: environment, hidesUnavailable: true, showsGlobalShortcut: true)

        RecordingStatusView(
            phase: coordinator.phase,
            recordingStartedAt: coordinator.recordingStartedAt,
            engineName: coordinator.engineInfo.displayName,
            isModelDownloaded: coordinator.isModelDownloaded,
            notesFolder: environment.notesFolder.status,
            timeRemaining: coordinator.timeRemaining
        )
        if coordinator.isAskingIfStillRecording {
            Label(
                "Still recording? \(StillRecordingPrompt.message(for: coordinator.stillRecordingDelay))",
                systemImage: "waveform.slash"
            )
            Button("Keep Recording") { coordinator.keepRecording() }
        }
        ForEach(coordinator.silentDevices) { device in
            Label(SilentInputWarning.title(for: device), systemImage: "speaker.slash")
        }
        if SilentInputWarning.needsPermission(coordinator.silentDevices) {
            Button("Open Privacy Settings…") { SystemSettings.open(.screenAndSystemAudioRecording) }
        }
        if environment.notesFolder.directory == nil && !coordinator.isRecording {
            Button("Choose Notes Folder…") { environment.chooseNotesFolder() }
        }
        ModelDownloadControls(coordinator: coordinator, hidesUnavailable: true)

        Divider()

        DevicePicker(environment: environment)

        Divider()

        Button("Open Mixdown") { navigation.show(navigation.destination, using: openWindow) }
        if !coordinator.unfinishedRecordings.isEmpty && !coordinator.canStopRecording {
            let count = coordinator.unfinishedRecordings.count
            Button(count == 1 ? "1 Unfinished Recording…" : "\(count) Unfinished Recordings…") {
                navigation.show(.recorder, using: openWindow)
            }
        }

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
