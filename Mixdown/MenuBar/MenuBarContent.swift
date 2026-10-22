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

        Button(coordinator.canStopRecording ? "Stop Recording" : "Start Recording") {
            Task { await coordinator.toggleRecording() }
        }
        .recordingShortcut(isGlobal: environment.isRecordingShortcutEnabled)
        .disabled(!coordinator.canStartRecording && !coordinator.canStopRecording)
        if coordinator.isRecording {
            Button(coordinator.isPaused ? "Resume Recording" : "Pause Recording") {
                Task { await coordinator.togglePause() }
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Mark Moment") { environment.markMoment() }
                .globalKeyboardShortcut(.markMoment)
            Button("Catch Me Up") { environment.catchUp() }
                .globalKeyboardShortcut(.catchUp)
        }

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
        if case .preparingModel = coordinator.phase {
            // A download for a finished recording can't be cancelled.
            if !coordinator.isPreparingModelForRecording {
                Button("Cancel Download") { coordinator.cancelPreparation() }
                    .disabled(!coordinator.canCancelPreparation)
            }
        } else if !coordinator.isModelDownloaded && coordinator.isIdle {
            Button("Download Model") {
                Task { await coordinator.prepareEngine() }
            }
        }

        Divider()

        DevicePicker(environment: environment)

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
