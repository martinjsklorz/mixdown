import AppKit
import CoreSpotlight
import MixdownCore
import MixdownNotes
import Observation
import SwiftUI

/// Brings the main window back when the Dock icon is clicked. SwiftUI does that for a
/// `WindowGroup`, but not for a `Window` that has been closed. Also adds help topics to the Help
/// menu's search, opens notes picked in Spotlight, and asks before quitting while recording or
/// making a note, or with notes or recordings only kept in memory.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `capturesOpenWindow(for:navigation:environment:)`, which also gives it SwiftUI's
    /// `openWindow`.
    fileprivate weak var navigation: MainNavigation?
    fileprivate weak var environment: AppEnvironment?
    private var helpSearch: HelpSearch?
    /// A note picked in Spotlight before `navigation` was set, at launch.
    private var pendingSpotlightItem: (url: URL, line: Int?)?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before the first window appears, so it doesn't flash in the system's appearance.
        AppSettings().appearance.apply()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let helpSearch = HelpSearch { [weak self] topic, search in
            self?.navigation?.showHelp(topic, searching: search)
        }
        NSApp.registerUserInterfaceItemSearchHandler(helpSearch)
        self.helpSearch = helpSearch
    }

    /// Asks before quitting while recording or making a note, and with notes waiting for the notes
    /// folder or recordings that couldn't be transcribed, which only live in memory. Logging out,
    /// restarting or shutting down doesn't ask about recording, so it isn't held up: a recording
    /// kept on disk stops, to make its note the next time Mixdown opens, like one being made into a
    /// note already is. One only in memory stops, and Mixdown quits once its note is saved.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator = environment?.coordinator else { return .terminateNow }
        if Self.isSessionEnding {
            if coordinator.canStopRecording, coordinator.keepsRecordingWhenQuitting {
                stopWithoutNoteThenQuit(coordinator)
                return .terminateLater
            } else if coordinator.canStopRecording {
                Task { await coordinator.stopRecording() }
                replyWhenDone(coordinator)
                return .terminateLater
            } else if coordinator.isMakingNote, !coordinator.keepsRecordingWhenQuitting,
                coordinator.importingFileName == nil
            {
                replyWhenDone(coordinator)
                return .terminateLater
            }
        } else if coordinator.canStopRecording {
            return askToQuitWhileRecording(coordinator)
        } else if coordinator.isMakingNote {
            return askToQuitWhileMakingNote(coordinator)
        }
        return askToQuitLosingWork(coordinator)
    }

    private func askToQuitWhileRecording(_ coordinator: RecordingCoordinator) -> NSApplication.TerminateReply {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Mixdown is recording"
        alert.informativeText =
            "Stop the recording, and Mixdown quits once its note is saved. "
            + (coordinator.keepsRecordingWhenQuitting
                ? "If you quit now, Mixdown keeps the recording, to make its note the next time you open it."
                : "If you quit now, the recording is lost.")
        alert.addButton(withTitle: "Stop and Quit When Saved")
        addDontQuitButton(to: alert)
        let quit = alert.addButton(withTitle: "Quit Now")
        quit.hasDestructiveAction = !coordinator.keepsRecordingWhenQuitting
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { await coordinator.stopRecording() }
            quitWhenDone()
            return .terminateCancel
        case .alertThirdButtonReturn:
            stopWithoutNoteThenQuit(coordinator)
            return .terminateLater
        default:
            return .terminateCancel
        }
    }

    private func askToQuitWhileMakingNote(_ coordinator: RecordingCoordinator) -> NSApplication.TerminateReply {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Mixdown is still making a note"
        let quittingNow =
            if let name = coordinator.importingFileName {
                "If you quit now, import “\(name)” again later."
            } else if coordinator.keepsRecordingWhenQuitting {
                "If you quit now, Mixdown keeps the recording, to make its note the next time you open it."
            } else {
                "If you quit now, the recording is lost."
            }
        alert.informativeText = "Mixdown can quit once the note is saved. " + quittingNow
        alert.addButton(withTitle: "Quit When Saved")
        addDontQuitButton(to: alert)
        let quit = alert.addButton(withTitle: "Quit Now")
        quit.hasDestructiveAction = coordinator.importingFileName == nil && !coordinator.keepsRecordingWhenQuitting
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            quitWhenDone()
            return .terminateCancel
        case .alertThirdButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    /// Asks about notes waiting for the notes folder, then about recordings that couldn't be
    /// transcribed and are only in memory, as quitting loses them.
    private func askToQuitLosingWork(_ coordinator: RecordingCoordinator) -> NSApplication.TerminateReply {
        guard askToQuitWithPendingNotes(coordinator) == .terminateNow else { return .terminateCancel }
        return askToQuitWithRecordingsInMemory(coordinator)
    }

    private func askToQuitWithPendingNotes(_ coordinator: RecordingCoordinator) -> NSApplication.TerminateReply {
        let count = coordinator.pendingNotes.count
        guard count > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = count == 1 ? "A note hasn't been saved yet" : "\(count) notes haven't been saved yet"
        alert.informativeText =
            "Mixdown couldn't reach the notes folder. If you quit now, "
            + (count == 1 ? "the note is" : "the notes are")
            + " lost. Connect the folder's drive, or choose another folder in Settings, and Mixdown "
            + "saves " + (count == 1 ? "it." : "them.")
        alert.addButton(withTitle: "Don't Quit")
        let quit = alert.addButton(withTitle: "Quit Anyway")
        quit.hasDestructiveAction = true
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
    }

    private func askToQuitWithRecordingsInMemory(
        _ coordinator: RecordingCoordinator
    ) -> NSApplication.TerminateReply {
        let count = coordinator.unfinishedRecordings.filter { !$0.isOnDisk }.count
        guard count > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText =
            count == 1 ? "A recording hasn't been transcribed" : "\(count) recordings haven't been transcribed"
        alert.informativeText =
            "Mixdown keeps the audio in memory only, so if you quit now, "
            + (count == 1 ? "the recording is" : "the recordings are")
            + " lost. Transcribe " + (count == 1 ? "it" : "them") + " again from Record."
        alert.addButton(withTitle: "Don't Quit")
        let quit = alert.addButton(withTitle: "Quit Anyway")
        quit.hasDestructiveAction = true
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
    }

    /// Adds Don't Quit, which Escape presses too.
    private func addDontQuitButton(to alert: NSAlert) {
        alert.addButton(withTitle: "Don't Quit").keyEquivalent = "\u{1b}"
    }

    /// Quits once Mixdown has stopped recording and making notes. Quitting asks again about notes
    /// and recordings only in memory.
    private func quitWhenDone() {
        guard let coordinator = environment?.coordinator else { return }
        whenDone(coordinator) { NSApp.terminate(nil) }
    }

    /// Lets Mixdown quit once it has stopped recording and making notes, after asking about notes
    /// and recordings only in memory. Answers a `.terminateLater`.
    private func replyWhenDone(_ coordinator: RecordingCoordinator) {
        whenDone(coordinator) { [weak self] in
            let reply = self?.askToQuitLosingWork(coordinator) ?? .terminateNow
            NSApp.reply(toApplicationShouldTerminate: reply == .terminateNow)
        }
    }

    /// Runs `action` once `coordinator` has stopped recording and making notes.
    private func whenDone(_ coordinator: RecordingCoordinator, _ action: @escaping @MainActor () -> Void) {
        let isBusy = withObservationTracking {
            coordinator.canStopRecording || coordinator.isMakingNote
        } onChange: { [weak self] in
            Task { @MainActor in self?.whenDone(coordinator, action) }
        }
        if !isBusy { action() }
    }

    /// Stops the recording, keeping it to make its note the next time, then lets Mixdown quit.
    /// Answers a `.terminateLater`.
    private func stopWithoutNoteThenQuit(_ coordinator: RecordingCoordinator) {
        Task {
            await coordinator.stopRecordingWithoutNote()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }

    /// Whether Mixdown is asked to quit as the user logs out or the Mac restarts or shuts down,
    /// by the quit event's reason.
    private static var isSessionEnding: Bool {
        // `kAEQuitReason`, and `kAELogOut`, `kAEReallyLogOut`, `kAEShowRestartDialog`,
        // `kAEShowShutdownDialog`, `kAERestart` and `kAEShutDown`.
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
            let reason = event.attributeDescriptor(forKeyword: fourCharCode("why?"))?.typeCodeValue
        else { return false }
        return ["logo", "rlgo", "rrst", "rsdn", "rest", "shut"].map(fourCharCode).contains(reason)
    }

    private static func fourCharCode(_ code: String) -> FourCharCode {
        code.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }

    /// Opens the note, at the line, picked in Spotlight. See `NoteSpotlight`.
    func application(
        _ application: NSApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void
    ) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType,
            let id = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
            let location = NoteSearchIndex.location(ofItemID: id)
        else { return false }
        pendingSpotlightItem = (location.noteURL, location.line)
        showPendingSpotlightItem()
        return true
    }

    fileprivate func showPendingSpotlightItem() {
        guard let navigation, let item = pendingSpotlightItem else { return }
        pendingSpotlightItem = nil
        navigation.showNote(at: item.url, line: item.line)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Regardless of `flag`: the menu bar extra's window can count as visible.
        navigation?.openWindow?(id: MainView.windowID)
        return false
    }
}

extension View {
    /// Lets `delegate` and `navigation` open windows once this view has appeared, and gives
    /// `delegate` the environment.
    func capturesOpenWindow(
        for delegate: AppDelegate,
        navigation: MainNavigation,
        environment: AppEnvironment
    ) -> some View {
        modifier(OpenWindowCapture(delegate: delegate, navigation: navigation, environment: environment))
    }
}

private struct OpenWindowCapture: ViewModifier {
    let delegate: AppDelegate
    let navigation: MainNavigation
    let environment: AppEnvironment
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            navigation.openWindow = openWindow
            delegate.navigation = navigation
            delegate.environment = environment
            delegate.showPendingSpotlightItem()
        }
    }
}
