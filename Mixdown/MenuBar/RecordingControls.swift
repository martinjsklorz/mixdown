import KeyboardShortcuts
import MixdownCore
import SwiftUI

/// Start or Stop Recording, Pause or Resume, Mark Moment and Catch Me Up, for the menu bar
/// extra's menu and the Recording menu. The menu bar extra hides what can't be done right now;
/// the Recording menu disables it instead, which keeps the menu steady.
struct RecordingControls: View {
    let environment: AppEnvironment
    /// Whether to leave out what can't be done right now rather than disable it.
    let hidesUnavailable: Bool
    /// Whether Start/Stop Recording shows the global shortcut, if it's turned on, rather than ⌘R.
    let showsGlobalShortcut: Bool

    var body: some View {
        let coordinator = environment.coordinator

        Button(coordinator.canStopRecording ? "Stop Recording" : "Start Recording") {
            Task { await coordinator.toggleRecording() }
        }
        .recordingShortcut(isGlobal: showsGlobalShortcut && environment.preferences.isRecordingShortcutEnabled)
        .disabled(!coordinator.canStartRecording && !coordinator.canStopRecording)
        if coordinator.isRecording || !hidesUnavailable {
            Button(coordinator.isPaused ? "Resume Recording" : "Pause Recording") {
                Task { await coordinator.togglePause() }
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(!coordinator.isRecording)
            Button("Mark Moment") { environment.island.markMoment() }
                .globalKeyboardShortcut(.markMoment)
                .disabled(!coordinator.isRecording)
            Button("Catch Me Up") { environment.island.catchUp() }
                .globalKeyboardShortcut(.catchUp)
                .disabled(!coordinator.isRecording)
        }
    }
}

/// Cancel Download while the model downloads, else Download Model, for the same menus as
/// `RecordingControls` and hidden or disabled the same way.
struct ModelDownloadControls: View {
    let coordinator: RecordingCoordinator
    /// Whether to leave out what can't be done right now rather than disable it.
    let hidesUnavailable: Bool

    var body: some View {
        if case .preparingModel = coordinator.phase {
            // A download for a finished recording can't be cancelled.
            if !(hidesUnavailable && coordinator.isPreparingModelForRecording) {
                Button("Cancel Download") { coordinator.cancelPreparation() }
                    .disabled(!coordinator.canCancelPreparation)
            }
        } else if coordinator.canDownloadModel || !hidesUnavailable {
            Button("Download Model") {
                Task { await coordinator.prepareEngine() }
            }
            .disabled(!coordinator.canDownloadModel)
        }
    }
}
