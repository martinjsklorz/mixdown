import AppKit
import KeyboardShortcuts
import MixdownCore
import MixdownNotes
import SwiftUI

/// The main menu. The View menu's sections switch what the main window shows; the File menu has
/// the notes files and the shown note, the Recording menu recording and inputs, the Help menu
/// Mixdown Help. About Mixdown adds how much space models and notes take up, and Check for
/// Updates… follows it. Settings… comes with the `Settings` scene.
struct MixdownCommands: Commands {
    let environment: AppEnvironment
    let navigation: MainNavigation
    @FocusedValue(\.shownNote) private var shownNote

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Mixdown") { AboutPanel.show(notesFolder: environment.notesFolder.status) }
            CheckForUpdatesMenuItem()
                .environment(environment)
        }
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
            ChatMenuItem()
                .environment(environment)
                .environment(navigation)
            Divider()
        }
        CommandMenu("Recording") {
            RecordingMenuItems()
                .environment(environment)
        }
        // Replaces Mixdown Help, which looks for an Apple Help Book. The search field stays.
        CommandGroup(replacing: .help) {
            HelpMenuItems()
                .environment(navigation)
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

/// Opens the main window at Chat, while it's turned on in Settings.
private struct ChatMenuItem: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        if environment.preferences.isChatEnabled {
            SectionMenuItem("Chat", destination: .chat)
                .keyboardShortcut("3")
        }
    }
}

/// Only in release builds, which have an updater.
private struct CheckForUpdatesMenuItem: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let updater = environment.updater
        if updater.isAvailable {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
    }
}

private struct HelpMenuItems: View {
    @Environment(MainNavigation.self) private var navigation
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Mixdown Help") { navigation.showHelp(using: openWindow) }
            .keyboardShortcut("?", modifiers: .command)
        Button("Keyboard Shortcuts") { navigation.showHelp(.shortcuts, using: openWindow) }
        Divider()
        Button("Setup Assistant…") { navigation.showSetup(using: openWindow) }
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
        Button("Import Audio…") { environment.importAudio() }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(!environment.coordinator.canImportAudio)

        Divider()

        Button(shownNote?.note.isPinned == true ? "Unpin Note" : "Pin Note") {
            if let shownNote { shownNote.actions.togglePinned(shownNote.note) }
        }
        .disabled(shownNote == nil)
        Button("Rename Note…") {
            if let shownNote { shownNote.actions.rename(shownNote.note) }
        }
        .disabled(shownNote == nil)
        if let shownNote {
            RenameSpeakerMenu(note: shownNote.note, actions: shownNote.actions) { Text("Rename Speaker") }
        } else {
            Menu("Rename Speaker") {}
                .disabled(true)
        }
        Button("Add to Vocabulary…") {
            shownNote?.actions.addToVocabulary()
        }
        .disabled(shownNote == nil)
        if let note = shownNote?.note {
            ShareLink(item: note.url, preview: SharePreview(note.title))
        } else {
            Menu("Share") {}
                .disabled(true)
        }

        Divider()

        Button("Delete", action: moveToTrash)
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

        Button(coordinator.canStopRecording ? "Stop Recording" : "Start Recording") {
            Task { await coordinator.toggleRecording() }
        }
        .keyboardShortcut("r")
        .disabled(!coordinator.canStartRecording && !coordinator.canStopRecording)
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

        if case .preparingModel = coordinator.phase {
            Button("Cancel Download") { coordinator.cancelPreparation() }
                .disabled(!coordinator.canCancelPreparation)
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

        DevicePicker(environment: environment)
    }
}
