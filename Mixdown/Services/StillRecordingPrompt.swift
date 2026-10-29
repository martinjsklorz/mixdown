import Foundation
import MixdownCore
import UserNotifications

/// Asks "Still Recording?" with a notification while the coordinator's `isAskingIfStillRecording`,
/// i.e. after no one has spoken for a while, as the recording may have been left running after a
/// meeting ended. Its buttons stop the recording or keep it going; clicking the notification itself
/// opens Record, which asks too. It goes away as soon as anyone speaks or the question is answered
/// elsewhere, such as in the menu bar.
///
/// `NotificationResponder` hands it the buttons, on notifications from an earlier run, too. Those
/// only act while the question is still open, so an old Stop never ends a newer recording.
@MainActor
final class StillRecordingPrompt {
    nonisolated static let categoryIdentifier = "stillRecording"
    private nonisolated static let stopAction = "stop"
    private nonisolated static let keepAction = "keep"

    /// The Stop Recording and Keep Recording buttons, registered by `NotificationResponder`.
    static let category = UNNotificationCategory(
        identifier: categoryIdentifier,
        actions: [
            UNNotificationAction(identifier: stopAction, title: "Stop Recording"),
            UNNotificationAction(identifier: keepAction, title: "Keep Recording"),
        ],
        intentIdentifiers: []
    )

    private let coordinator: () -> RecordingCoordinator?
    private let showRecorder: () -> Void
    /// The notification, while one is posted.
    private var promptID: String?

    /// - Parameters:
    ///   - coordinator: The coordinator in use, which is replaced when the model changes.
    ///   - showRecorder: Opens Record in the main window.
    init(coordinator: @escaping () -> RecordingCoordinator?, showRecorder: @escaping () -> Void) {
        self.coordinator = coordinator
        self.showRecorder = showRecorder
    }

    /// Posts the notification, unless it's up already.
    func ask() {
        guard promptID == nil else { return }
        let id = "still-recording-\(UUID().uuidString)"
        promptID = id
        let body = Self.message(for: coordinator()?.stillRecordingDelay)
        Notifications.send(title: "Still Recording?", body: body, categoryIdentifier: Self.categoryIdentifier, id: id)
    }

    /// Takes the notification away, as the question was answered.
    func withdraw() {
        guard let promptID else { return }
        Notifications.remove(id: promptID)
        self.promptID = nil
    }

    /// "No one has spoken for 15 minutes." Also the detail on Record.
    static func message(for delay: Duration?) -> String {
        let minutes = Int(((delay ?? .zero).components.seconds + 30) / 60)
        let time = minutes == 1 ? "a minute" : "\(minutes) minutes"
        return "No one has spoken for \(time)."
    }

    private func stop() {
        guard let coordinator = coordinator(), coordinator.isAskingIfStillRecording else { return }
        Task { await coordinator.stopRecording() }
    }

    private func keep() {
        coordinator()?.keepRecording()
    }

    private func openRecorder() {
        showRecorder()
    }
}

extension StillRecordingPrompt {
    /// Handles a click on a notification of `category` or one of its buttons.
    nonisolated func respond(to response: UNNotificationResponse) async {
        switch response.actionIdentifier {
        case Self.stopAction:
            await stop()
        case Self.keepAction:
            await keep()
        case UNNotificationDefaultActionIdentifier:
            await openRecorder()
        default:
            break
        }
    }
}
