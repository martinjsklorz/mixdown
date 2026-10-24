import Foundation
import MixdownAudio
import MixdownCore
import UserNotifications
import os

/// Notifies about calls and records them, as `notifies` and `recordsAutomatically` say.
///
/// A call starts once Zoom, Discord, a browser or another call app has been using a microphone for
/// a few seconds, and ends once the last one has stopped for a few seconds.
/// - Notifying, not recording automatically: When a call starts, posts a notification that records
///   when clicked; it goes away again when the call ends. When the call ends while Mixdown is
///   recording, posts one that stops the recording when clicked; it goes away when the recording
///   stops or a call starts again. Both have a button too, but macOS only shows that while the
///   pointer is over the banner.
/// - Recording automatically: Starts and stops recording by itself, and, if notifying, posts a
///   notification saying so. If it can't record, e.g. as the model isn't downloaded, it asks
///   instead (if notifying), and clicking that opens Record, which says why. It only stops
///   recordings started for a call: one started by hand goes on, and it asks instead (if
///   notifying), as a call app may just have used the microphone briefly.
///
/// A recording it starts, from a notification or automatically, is marked as a call in its app, so
/// its note says which app and is titled as a call. Recordings started any other way aren't, even
/// during a call. Only automatic ones are marked as started automatically: clicking a notification
/// is the user's choice.
///
/// Call `recordingDidStart()` and `recordingDidStop()` as recordings come and go.
/// `NotificationResponder` hands it the buttons, on notifications from an earlier run, too.
@MainActor
final class CallPrompt {
    /// Whether to post notifications. Turning it off takes away any that are open.
    var notifies = false {
        didSet {
            guard notifies != oldValue else { return }
            if !notifies { withdrawNotifications() }
            updateWatching()
        }
    }

    /// Whether to start and stop recording with calls, without asking.
    var recordsAutomatically = false {
        didSet { updateWatching() }
    }

    private let isRecording: () -> Bool
    private let startRecording: () -> Bool
    private let stopRecording: () -> Void
    private let markRecordingAsCall: (_ app: String?, _ automatically: Bool) -> Void
    private let showRecorder: () -> Void
    private var detector: CallDetector?
    private var detection: Task<Void, Never>?
    /// The record prompt posted for each call that's going on, by app name.
    private var recordPromptIDs: [String: String] = [:]
    /// The stop prompt, while one is posted.
    private var stopPromptID: String?
    /// The call a recording was started for automatically, until the recording has started.
    private var startingFor: CallApp?
    /// Whether a recording was started for a call, from a notification or automatically, until it
    /// has started.
    private var isStartingCall = false
    /// The name of the app the call being started for is in, if known, until the recording has
    /// started.
    private var startingCallApp: String?
    /// Whether the recording going on was started for a call, from a notification or automatically.
    private var isRecordingCall = false
    /// The notification saying an automatic recording is going on.
    private var recordingNoticeID: String?

    nonisolated static let startedCategoryIdentifier = "callStarted"
    nonisolated static let endedCategoryIdentifier = "callEnded"
    private nonisolated static let recordAction = "record"
    private nonisolated static let stopAction = "stop"
    /// The record prompt's `userInfo` key for the call app's name.
    private nonisolated static let appKey = "callApp"
    private static let logger = Logger(subsystem: "app.mixdown", category: "CallPrompt")

    /// The Record button, registered by `NotificationResponder`.
    static let startedCategory = UNNotificationCategory(
        identifier: startedCategoryIdentifier,
        actions: [UNNotificationAction(identifier: recordAction, title: "Record")],
        intentIdentifiers: []
    )

    /// The Stop Recording button, registered by `NotificationResponder`.
    static let endedCategory = UNNotificationCategory(
        identifier: endedCategoryIdentifier,
        actions: [UNNotificationAction(identifier: stopAction, title: "Stop Recording")],
        intentIdentifiers: []
    )

    /// - Parameters:
    ///   - isRecording: Whether Mixdown is recording, or starting to.
    ///   - startRecording: Starts recording, returning `false` if it can't.
    ///   - stopRecording: Stops recording.
    ///   - markRecordingAsCall: Marks the recording in progress as a call in the app with the given
    ///     name, if known, and whether it was started automatically rather than from a notification.
    ///   - showRecorder: Opens Record in the main window.
    init(
        isRecording: @escaping () -> Bool,
        startRecording: @escaping () -> Bool,
        stopRecording: @escaping () -> Void,
        markRecordingAsCall: @escaping (_ app: String?, _ automatically: Bool) -> Void,
        showRecorder: @escaping () -> Void
    ) {
        self.isRecording = isRecording
        self.startRecording = startRecording
        self.stopRecording = stopRecording
        self.markRecordingAsCall = markRecordingAsCall
        self.showRecorder = showRecorder
    }

    /// Records the call in `app` from the record prompt, or opens Record if it can't, which says why.
    private func recordFromPrompt(app: String?) {
        // A recording that's going on already wasn't started for the call.
        guard !isRecording() else { return }
        isStartingCall = true
        startingCallApp = app
        guard !startRecording() else { return }
        isStartingCall = false
        startingCallApp = nil
        showRecorder()
    }

    private func stopFromPrompt() {
        stopRecording()
    }

    /// Watches calls while there's something to do about them.
    private func updateWatching() {
        let watches = notifies || recordsAutomatically
        if watches, detection == nil {
            start()
        } else if !watches, detection != nil {
            stop()
        }
    }

    private func start() {
        Self.logger.info("Watching for calls")
        let detector = CallDetector(monitor: CoreAudioInputActivityMonitor())
        self.detector = detector
        detection = Task { [weak self] in
            await detector.run { [weak self] event in self?.handle(event) }
        }
    }

    private func stop() {
        detection?.cancel()
        detection = nil
        detector = nil
        startingFor = nil
        withdrawNotifications()
    }

    /// Takes away the record prompts, as there's nothing left to start, marks the recording as a
    /// call if it was started for one, and says so if that was automatic.
    func recordingDidStart() {
        withdrawRecordPrompts()
        isRecordingCall = isStartingCall
        if isStartingCall {
            isStartingCall = false
            markRecordingAsCall(startingCallApp, startingFor != nil)
        }
        startingCallApp = nil
        guard let app = startingFor else { return }
        startingFor = nil
        guard notifies else { return }
        let id = "call-recording-\(UUID().uuidString)"
        recordingNoticeID = id
        post(title: "Recording Call", body: "Mixdown is recording the \(app.name) call.", id: id)
    }

    /// Takes away the stop prompt and the recording notice, as there's nothing left to stop.
    func recordingDidStop() {
        withdrawStopPrompt()
        startingFor = nil
        isStartingCall = false
        startingCallApp = nil
        isRecordingCall = false
        withdrawRecordingNotice()
    }

    private func withdrawNotifications() {
        withdrawRecordPrompts()
        withdrawStopPrompt()
        withdrawRecordingNotice()
    }

    private func withdrawRecordingNotice() {
        guard let recordingNoticeID else { return }
        Notifications.remove(id: recordingNoticeID)
        self.recordingNoticeID = nil
    }

    private func withdrawRecordPrompts() {
        for id in recordPromptIDs.values { Notifications.remove(id: id) }
        recordPromptIDs = [:]
    }

    private func withdrawStopPrompt() {
        guard let stopPromptID else { return }
        Notifications.remove(id: stopPromptID)
        self.stopPromptID = nil
    }

    private func handle(_ event: CallDetector.Event) {
        switch event {
        case .started(let app): callStarted(app)
        case .ended(let app): callEnded(app)
        }
    }

    private func callStarted(_ app: CallApp) {
        // The recording goes on, e.g. the call dropped and was joined again.
        withdrawStopPrompt()
        guard !isRecording() else {
            Self.logger.info("\(app.name, privacy: .public) started a call; already recording")
            return
        }
        if recordsAutomatically {
            startingFor = app
            isStartingCall = true
            startingCallApp = app.name
            if startRecording() {
                Self.logger.info("\(app.name, privacy: .public) started a call; recording it")
                return
            }
            startingFor = nil
            isStartingCall = false
            startingCallApp = nil
            Self.logger.info("\(app.name, privacy: .public) started a call; can't record it")
        }
        guard notifies else {
            Self.logger.info("\(app.name, privacy: .public) started a call; not notifying")
            return
        }
        Self.logger.info("\(app.name, privacy: .public) started a call; asking to record")
        let id = "call-started-\(UUID().uuidString)"
        recordPromptIDs[app.name] = id
        post(
            title: "Record This Call?",
            body: "\(app.name) is using the microphone. Click to record.",
            category: Self.startedCategoryIdentifier,
            userInfo: [Self.appKey: app.name],
            id: id
        )
    }

    private func callEnded(_ app: CallApp) {
        // Clicking Record on a call that's over would start an empty recording.
        if let id = recordPromptIDs.removeValue(forKey: app.name) { Notifications.remove(id: id) }
        guard isRecording(), detector?.activeCalls.isEmpty ?? true else {
            Self.logger.info("\(app.name, privacy: .public) ended its call")
            return
        }
        // A recording started by hand isn't the call's to stop, e.g. a call app used the
        // microphone briefly during an in-person recording.
        if recordsAutomatically, isRecordingCall || isStartingCall {
            Self.logger.info("\(app.name, privacy: .public) ended its call; stopping the recording")
            stopRecording()
            // A recording still starting, e.g. waiting on a permission prompt, is discarded as soon
            // as it has started, so it's neither announced nor said to have stopped.
            startingFor = nil
            if notifies, isRecordingCall {
                post(title: "Call Recording Stopped", body: "The \(app.name) call has ended.")
            }
            return
        }
        guard notifies else {
            Self.logger.info("\(app.name, privacy: .public) ended its call; not notifying")
            return
        }
        Self.logger.info("\(app.name, privacy: .public) ended its call; asking to stop recording")
        withdrawStopPrompt()
        let id = "call-ended-\(UUID().uuidString)"
        stopPromptID = id
        post(
            title: "Stop Recording?",
            body: "The \(app.name) call has ended. Click to stop recording.",
            category: Self.endedCategoryIdentifier,
            id: id
        )
    }

    private func post(
        title: String,
        body: String,
        category: String? = nil,
        userInfo: [String: String] = [:],
        id: String = UUID().uuidString
    ) {
        Task {
            await Notifications.post(
                title: title,
                body: body,
                categoryIdentifier: category,
                userInfo: userInfo,
                id: id
            )
        }
    }
}

extension CallPrompt {
    /// Handles a click on a notification of `startedCategory` or `endedCategory`, or its button.
    nonisolated func respond(to response: UNNotificationResponse) async {
        let category = response.notification.request.content.categoryIdentifier
        let clicks = [Self.recordAction, Self.stopAction, UNNotificationDefaultActionIdentifier]
        guard clicks.contains(response.actionIdentifier) else { return }
        if category == Self.startedCategoryIdentifier {
            let app = response.notification.request.content.userInfo[Self.appKey] as? String
            await recordFromPrompt(app: app)
        } else {
            await stopFromPrompt()
        }
    }
}
