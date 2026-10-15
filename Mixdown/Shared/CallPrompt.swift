import Foundation
import MixdownAudio
import MixdownCore
import UserNotifications
import os

/// Records calls, asking first or not, depending on `mode`.
///
/// A call starts once Zoom, Discord, a browser or another call app has been using a microphone for
/// a few seconds, and ends once the last one has stopped for a few seconds.
/// - `.ask`: When a call starts, posts a notification that records when clicked; it goes away again
///   when the call ends. When the call ends while Mixdown is recording, posts one that stops the
///   recording when clicked; it goes away when the recording stops or a call starts again. Both
///   have a button too, but macOS only shows that while the pointer is over the banner.
/// - `.automatic`: Starts and stops recording by itself, and posts a notification saying so. If it
///   can't record, e.g. as the model isn't downloaded, it falls back to asking, and clicking that
///   opens Record, which says why.
///
/// Call `recordingDidStart()` and `recordingDidStop()` as recordings come and go. Set up at
/// launch, so the buttons also work on notifications from an earlier run.
@MainActor
final class CallPrompt {
    /// `.off` stops watching and takes away any open prompt.
    var mode = CallRecording.off {
        didSet {
            guard mode != oldValue else { return }
            if oldValue == .off { start() } else if mode == .off { stop() }
        }
    }

    private let isRecording: () -> Bool
    private let startRecording: () -> Bool
    private let stopRecording: () -> Void
    private let showRecorder: () -> Void
    private var detector: CallDetector?
    private var detection: Task<Void, Never>?
    /// The record prompt posted for each call that's going on, by app name.
    private var recordPromptIDs: [String: String] = [:]
    /// The stop prompt, while one is posted.
    private var stopPromptID: String?
    /// The call a recording was started for automatically, until the recording has started.
    private var startingFor: CallApp?
    /// The notification saying an automatic recording is going on.
    private var recordingNoticeID: String?

    private static let startedCategory = "callStarted"
    private static let endedCategory = "callEnded"
    private static let recordAction = "record"
    private static let stopAction = "stop"
    private static let logger = Logger(subsystem: "app.mixdown", category: "CallPrompt")

    /// - Parameters:
    ///   - isRecording: Whether Mixdown is recording.
    ///   - startRecording: Starts recording, returning `false` if it can't.
    ///   - stopRecording: Stops recording.
    ///   - showRecorder: Opens Record in the main window.
    init(
        isRecording: @escaping () -> Bool,
        startRecording: @escaping () -> Bool,
        stopRecording: @escaping () -> Void,
        showRecorder: @escaping () -> Void
    ) {
        self.isRecording = isRecording
        self.startRecording = startRecording
        self.stopRecording = stopRecording
        self.showRecorder = showRecorder
        Self.register(Self.startedCategory, action: Self.recordAction, title: "Record") { [weak self] in
            guard let self, !self.startRecording() else { return }
            self.showRecorder()
        }
        Self.register(Self.endedCategory, action: Self.stopAction, title: "Stop Recording") { [weak self] in
            self?.stopRecording()
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
        startingFor = nil
        withdrawRecordPrompts()
        withdrawStopPrompt()
    }

    /// Takes away the record prompts, as there's nothing left to start, and says so if the
    /// recording was started for a call automatically.
    func recordingDidStart() {
        withdrawRecordPrompts()
        guard let app = startingFor else { return }
        startingFor = nil
        let id = "call-recording-\(UUID().uuidString)"
        recordingNoticeID = id
        post(title: "Recording Call", body: "Mixdown is recording the \(app.name) call.", id: id)
    }

    /// Takes away the stop prompt and the recording notice, as there's nothing left to stop.
    func recordingDidStop() {
        withdrawStopPrompt()
        startingFor = nil
        if let recordingNoticeID {
            Notifications.remove(id: recordingNoticeID)
            self.recordingNoticeID = nil
        }
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
        if mode == .automatic {
            startingFor = app
            if startRecording() {
                Self.logger.info("\(app.name, privacy: .public) started a call; recording it")
                return
            }
            startingFor = nil
            Self.logger.info("\(app.name, privacy: .public) started a call; can't record, asking instead")
        } else {
            Self.logger.info("\(app.name, privacy: .public) started a call; asking to record")
        }
        let id = "call-started-\(UUID().uuidString)"
        recordPromptIDs[app.name] = id
        post(
            title: "Record This Call?",
            body: "\(app.name) is using the microphone. Click to record.",
            category: Self.startedCategory,
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
        if mode == .automatic {
            Self.logger.info("\(app.name, privacy: .public) ended its call; stopping the recording")
            stopRecording()
            post(title: "Call Recording Stopped", body: "The \(app.name) call has ended.")
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

    private func post(title: String, body: String, category: String? = nil, id: String = UUID().uuidString) {
        Task {
            await Notifications.post(title: title, body: body, categoryIdentifier: category, id: id)
        }
    }
}
