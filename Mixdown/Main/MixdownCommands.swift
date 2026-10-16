import AppKit
import MixdownCore
import MixdownNotes
import SwiftUI

/// The main menu. The View menu's sections switch what the main window shows; the File menu has
/// the notes files and the shown note, the Recording menu recording and inputs. Settings… comes
/// with the `Settings` scene.
struct MixdownCommands: Commands {
    let environment: AppEnvironment
    let navigation: MainNavigation
    @FocusedValue(\.shownNote) private var shownNote

    var body: some Commands {
        // Replaces New Window, which a single-instance window doesn't offer anyway.
        CommandGroup(replacing: .newItem) {
            NotesFileMenuItems(shownNote: shownNote)
                .environment(environment)
        }
        CommandGroup(after: .pasteboard) {
            Button("Copy Transcript") {
                if let shownNote { NoteActions.copyTranscript(of: shownNote.note) }
            }
            .disabled(shownNote == nil)
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
    let shownNote: ShownNote?

    var body: some View {
        Button("Open Notes Folder") { environment.openNotesFolder() }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(environment.notesFolder.directory == nil)
        Button("Reveal Last Note in Finder") { environment.revealLastNote() }
            .disabled(environment.coordinator.lastNoteURL == nil)

        Divider()

        Button("Rename Note…") {
            if let shownNote { shownNote.actions.rename(shownNote.note) }
        }
        .disabled(shownNote == nil)
        if let note = shownNote?.note {
            ShareLink(item: note.url, preview: SharePreview(note.title))
        } else {
            Menu("Share") {}
                .disabled(true)
        }

        Divider()

        Button("Move to Trash", action: moveToTrash)
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(shownNote == nil)
    }

    /// ⌘⌫ also deletes to the start of the line in text fields, such as the sidebar's search, and
    /// the menu would get it first. So while typing, it's handed back to the text.
    private func moveToTrash() {
        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView, textView.isEditable {
            textView.deleteToBeginningOfLine(nil)
        } else if let shownNote {
            shownNote.actions.moveToTrash(shownNote.note)
        }
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
            followsDefaultMicrophone: environment.followsDefaultMicrophone,
            onSelectMicrophone: environment.selectMicrophone,
            onSetSystemAudio: environment.setRecordsSystemAudio
        )
    }
}
