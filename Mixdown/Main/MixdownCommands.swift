import MixdownCore
import SwiftUI

/// The main menu. The View menu's sections switch what the main window shows; the File menu has
/// the notes files, the Recording menu recording and inputs. Settings… comes with the `Settings`
/// scene.
struct MixdownCommands: Commands {
    let environment: AppEnvironment
    let navigation: MainNavigation

    var body: some Commands {
        // Replaces New Window, which a single-instance window doesn't offer anyway.
        CommandGroup(replacing: .newItem) {
            NotesFileMenuItems()
                .environment(environment)
        }
        CommandGroup(before: .sidebar) {
            SectionMenuItem("Record", destination: .recorder)
                .keyboardShortcut("1")
                .environment(navigation)
            SectionMenuItem("Notes", destination: .notes)
                .keyboardShortcut("2")
                .environment(navigation)
            Divider()
        }
        CommandMenu("Recording") {
            RecordingMenuItems()
                .environment(environment)
        }
    }
}

/// Opens the main window at `destination`.
private struct SectionMenuItem: View {
    @Environment(MainNavigation.self) private var navigation
    @Environment(\.openWindow) private var openWindow
    let title: String
    let destination: MainNavigation.Destination

    init(_ title: String, destination: MainNavigation.Destination) {
        self.title = title
        self.destination = destination
    }

    var body: some View {
        Button(title) { navigation.show(destination, using: openWindow) }
    }
}

private struct NotesFileMenuItems: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        Button("Open Notes Folder") { environment.openNotesFolder() }
            .keyboardShortcut("o", modifiers: [.command, .shift])
        Button("Reveal Last Note in Finder") { environment.revealLastNote() }
            .disabled(environment.coordinator.lastNoteURL == nil)
    }
}

/// The same controls as the menu bar extra's menu. Items are disabled rather than hidden where
/// that keeps the menu steady.
private struct RecordingMenuItems: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let coordinator = environment.coordinator

        Button(coordinator.isRecording ? "Stop Recording" : "Start Recording") {
            Task { await coordinator.toggleRecording() }
        }
        .keyboardShortcut("r")
        .disabled(!coordinator.canStartRecording && !coordinator.isRecording)

        if case .preparingModel = coordinator.phase {
            Button("Cancel Download") { coordinator.cancelPreparation() }
        } else {
            Button("Download Model") {
                Task { await coordinator.prepareEngine() }
            }
            .disabled(coordinator.isModelDownloaded || !coordinator.isIdle)
        }
        if case .failed = coordinator.phase {
            Button("Dismiss Error") { coordinator.dismissError() }
        }

        Divider()

        DevicePicker(
            devices: coordinator.devices,
            selectedIDs: Set(coordinator.selectedDevices.map(\.id)),
            isEnabled: !coordinator.isRecording,
            onSelectMicrophone: environment.selectMicrophone,
            onSetSystemAudio: environment.setRecordsSystemAudio
        )
    }
}
