import Foundation
import MixdownAudio
import MixdownCore
import UserNotifications

/// Notifies about calls and records them: `CallRecorder` on the Mac's audio inputs, with its
/// notices as notifications. The record and stop prompts have a button too, but macOS only shows
/// that while the pointer is over the banner.
///
/// Call `recordingDidStart()` and `recordingDidStop()` as recordings come and go.
/// `NotificationResponder` hands it the buttons, on notifications from an earlier run, too.
@MainActor
final class CallPrompt {
    /// Whether to post notifications. Turning it off takes away any that are open.
    var notifies: Bool {
        get { recorder.notifies }
        set { recorder.notifies = newValue }
    }

    /// Whether to start and stop recording with calls, without asking.
    var recordsAutomatically: Bool {
        get { recorder.recordsAutomatically }
        set { recorder.recordsAutomatically = newValue }
    }

    /// The apps that count as calls. Taking out one in a call ends its call.
    var apps: [CallApp] {
        get { recorder.apps }
        set { recorder.apps = newValue }
    }

    private let recorder: CallRecorder

    nonisolated static let startedCategoryIdentifier = "callStarted"
    nonisolated static let endedCategoryIdentifier = "callEnded"
    private nonisolated static let recordAction = "record"
    private nonisolated static let stopAction = "stop"
    /// The record prompt's `userInfo` key for the call app's name.
    private nonisolated static let appKey = "callApp"

    /// The Record button, registered by `NotificationResponder`.
    static let startedCategory = UNNotificationCategory(
        identifier: startedCategoryIdentifier,
        actions: [UNNotificationAction(identifier: recordAction, title: "Record")],
        intentIdentifiers: [],
        // So closing it is reported, to snooze the app.
        options: [.customDismissAction]
    )

    /// The Stop Recording button, registered by `NotificationResponder`.
    static let endedCategory = UNNotificationCategory(
        identifier: endedCategoryIdentifier,
        actions: [UNNotificationAction(identifier: stopAction, title: "Stop Recording")],
        intentIdentifiers: []
    )

    /// See `CallRecorder.init` for the parameters.
    init(
        isRecording: @escaping () -> Bool,
        timeSinceSpeech: @escaping () -> Duration?,
        startRecording: @escaping () -> Bool,
        stopRecording: @escaping () -> Void,
        markRecordingAsCall: @escaping (_ app: String?, _ automatically: Bool) -> Void,
        showRecorder: @escaping () -> Void
    ) {
        recorder = CallRecorder(
            isRecording: isRecording,
            timeSinceSpeech: timeSinceSpeech,
            startRecording: startRecording,
            stopRecording: stopRecording,
            markRecordingAsCall: markRecordingAsCall,
            showRecorder: showRecorder,
            notifier: CallNotifier(),
            makeDetector: { apps in CallDetector(monitor: CoreAudioInputActivityMonitor(), apps: apps) }
        )
    }

    func recordingDidStart() { recorder.recordingDidStart() }

    func recordingDidStop() { recorder.recordingDidStop() }

    /// Posts `CallRecorder`'s notices as notifications.
    private final class CallNotifier: CallNotifying {
        func post(_ notice: CallNotice, id: String) {
            switch notice {
            case .recordPrompt(let app):
                Notifications.send(
                    title: "Record This Call?",
                    body: "\(app) is using the microphone. Click to record.",
                    categoryIdentifier: CallPrompt.startedCategoryIdentifier,
                    userInfo: [CallPrompt.appKey: app],
                    id: id
                )
            case .stopPrompt(let app):
                Notifications.send(
                    title: "Stop Recording?",
                    body: "The \(app) call has ended. Click to stop recording.",
                    categoryIdentifier: CallPrompt.endedCategoryIdentifier,
                    id: id
                )
            case .recordingCall(let app):
                Notifications.send(title: "Recording Call", body: "Mixdown is recording the \(app) call.", id: id)
            case .recordingStopped(let app):
                Notifications.send(title: "Call Recording Stopped", body: "The \(app) call has ended.", id: id)
            }
        }

        func remove(id: String) {
            Notifications.remove(id: id)
        }
    }
}

extension CallPrompt {
    /// Handles a click on a notification of `startedCategory` or `endedCategory`, or its button.
    nonisolated func respond(to response: UNNotificationResponse) async {
        let request = response.notification.request
        let category = request.content.categoryIdentifier
        let app = request.content.userInfo[Self.appKey] as? String
        if response.actionIdentifier == UNNotificationDismissActionIdentifier {
            if category == Self.startedCategoryIdentifier, let app {
                await recorder.recordPromptDismissed(app: app, id: request.identifier)
            }
            return
        }
        let clicks = [Self.recordAction, Self.stopAction, UNNotificationDefaultActionIdentifier]
        guard clicks.contains(response.actionIdentifier) else { return }
        if category == Self.startedCategoryIdentifier {
            await recorder.recordFromPrompt(app: app, id: request.identifier)
        } else {
            await recorder.stopFromPrompt(id: request.identifier)
        }
    }
}
