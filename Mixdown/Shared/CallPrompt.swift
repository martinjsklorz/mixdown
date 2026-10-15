import Foundation
import MixdownAudio
import MixdownCore
import UserNotifications
import os

/// Offers to record when a call starts, and to stop when it ends.
///
/// Once Zoom, Discord, a browser or another call app has been using a microphone for a few seconds,
/// posts a notification that records when clicked; it goes away again when the call ends. When the
/// last call ends while Mixdown is recording, posts one that stops the recording when clicked; it
/// goes away when the recording stops or a call starts again. Both have a button too, but macOS
/// only shows that while the pointer is over the banner.
///
/// Call `recordingDidStart()` and `recordingDidStop()` as recordings come and go. Set up at
/// launch, so the buttons also work on notifications from an earlier run.
@MainActor
final class CallPrompt {
    /// Whether to watch for calls. Off stops watching and takes away any open prompt.
    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled { start() } else { stop() }
        }
    }

    private let isRecording: () -> Bool
    private let onRecord: () -> Void
    private let onStop: () -> Void
    private var detector: CallDetector?
    private var detection: Task<Void, Never>?
    /// The record prompt posted for each call that's going on, by app name.
    private var recordPromptIDs: [String: String] = [:]
    /// The stop prompt, while one is posted.
    private var stopPromptID: String?

    private static let startedCategory = "callStarted"
    private static let endedCategory = "callEnded"
    private static let recordAction = "record"
    private static let stopAction = "stop"
    private static let logger = Logger(subsystem: "app.mixdown", category: "CallPrompt")

    /// - Parameters:
    ///   - isRecording: Whether Mixdown is recording. It only offers to record when it isn't, and
    ///     to stop when it is.
    ///   - onRecord: Called when the record prompt or its Record button is clicked.
    ///   - onStop: Called when the stop prompt or its Stop Recording button is clicked.
    init(isRecording: @escaping () -> Bool, onRecord: @escaping () -> Void, onStop: @escaping () -> Void) {
        self.isRecording = isRecording
        self.onRecord = onRecord
        self.onStop = onStop
        Self.register(Self.startedCategory, action: Self.recordAction, title: "Record") { [weak self] in
            self?.onRecord()
        }
        Self.register(Self.endedCategory, action: Self.stopAction, title: "Stop Recording") { [weak self] in
            self?.onStop()
        }
    }

    /// Registers a category whose notification and button both call `handler`.
    private static func register(
        _ category: String,
        action: String,
        title: String,
        handler: @escaping () -> Void
    ) {
        NotificationRouter.shared.register(
            UNNotificationCategory(
                identifier: category,
                actions: [UNNotificationAction(identifier: action, title: title)],
                intentIdentifiers: []
            )
        ) { response in
            guard [action, UNNotificationDefaultActionIdentifier].contains(response.actionIdentifier) else { return }
            handler()
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
        withdrawRecordPrompts()
        withdrawStopPrompt()
    }

    /// Takes away the record prompts, as there's nothing left to start.
    func recordingDidStart() {
        withdrawRecordPrompts()
    }

    /// Takes away the stop prompt, as there's nothing left to stop.
    func recordingDidStop() {
        withdrawStopPrompt()
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
        case .started(let app):
            // The recording goes on, e.g. the call dropped and was joined again.
            withdrawStopPrompt()
            guard !isRecording() else {
                Self.logger.info("\(app.name, privacy: .public) started a call; not asking, already recording")
                return
            }
            Self.logger.info("\(app.name, privacy: .public) started a call; asking to record")
            let id = "call-started-\(UUID().uuidString)"
            recordPromptIDs[app.name] = id
            post(
                title: "Record This Call?",
                body: "\(app.name) is using the microphone. Click to record.",
                category: Self.startedCategory,
                id: id
            )

        case .ended(let app):
            // Clicking Record on a call that's over would start an empty recording.
            if let id = recordPromptIDs.removeValue(forKey: app.name) { Notifications.remove(id: id) }
            guard isRecording(), detector?.activeCalls.isEmpty ?? true else {
                Self.logger.info("\(app.name, privacy: .public) ended its call")
                return
            }
            Self.logger.info("\(app.name, privacy: .public) ended its call; asking to stop recording")
            withdrawStopPrompt()
            let id = "call-ended-\(UUID().uuidString)"
            stopPromptID = id
            post(
                title: "Stop Recording?",
                body: "The \(app.name) call has ended. Click to stop recording.",
                category: Self.endedCategory,
                id: id
            )
        }
    }

    private func post(title: String, body: String, category: String, id: String) {
        Task {
            await Notifications.post(title: title, body: body, categoryIdentifier: category, id: id)
        }
    }
}
