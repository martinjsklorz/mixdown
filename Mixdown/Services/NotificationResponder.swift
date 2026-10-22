import Foundation
import UserNotifications

/// The delegate of the app's `UNUserNotificationCenter`. Registers the buttons of Mixdown's
/// notifications and hands clicks on them to whoever posted them. Set up at launch, so it handles
/// notifications from an earlier run, too.
///
/// Also has Mixdown's notifications shown while Mixdown is in front.
@MainActor
final class NotificationResponder: NSObject {
    private let noteTrash: NoteTrash
    private let noteReady: NoteReady
    /// Set right after launch; it needs the app environment, which needs this first.
    weak var callPrompt: CallPrompt?

    init(noteTrash: NoteTrash, noteReady: NoteReady) {
        self.noteTrash = noteTrash
        self.noteReady = noteReady
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            NoteTrash.category, NoteReady.category, CallPrompt.startedCategory, CallPrompt.endedCategory,
        ])
    }
}

extension NotificationResponder: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Shown while Mixdown is in front too: that's when Restore is most useful, and when
        // Copy Transcript happens.
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        switch response.notification.request.content.categoryIdentifier {
        case NoteTrash.categoryIdentifier:
            await noteTrash.respond(to: response)
        case NoteReady.categoryIdentifier:
            await noteReady.respond(to: response)
        case CallPrompt.startedCategoryIdentifier, CallPrompt.endedCategoryIdentifier:
            await callPrompt?.respond(to: response)
        default:
            break
        }
    }
}
