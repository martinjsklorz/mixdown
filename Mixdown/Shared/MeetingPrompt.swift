import Foundation
import MixdownAudio
import MixdownCore
import UserNotifications
import os

/// Offers to record when a call starts: once Zoom, Discord, a browser or another call app has been
/// using a microphone for a few seconds, posts a notification that records when clicked. It has a
/// Record button too, but macOS only shows that while the pointer is over the banner. The
/// notification goes away again when the call ends.
///
/// Nothing is posted while Mixdown is recording; call `withdrawPrompts()` when a recording starts.
/// Set up at launch, so Record also works on a notification from an earlier run.
@MainActor
final class MeetingPrompt {
    /// Whether to watch for meetings. Off stops watching and takes away an open prompt.
    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled { start() } else { stop() }
        }
    }

    private let isRecording: () -> Bool
    private let onRecord: () -> Void
    private var detection: Task<Void, Never>?
    /// The notification posted for each meeting that's going on, by app name.
    private var promptIDs: [String: String] = [:]

    private static let category = "meetingStarted"
    private static let recordAction = "record"
    private static let logger = Logger(subsystem: "app.mixdown", category: "MeetingPrompt")

    /// - Parameters:
    ///   - isRecording: Whether Mixdown is recording already, in which case it doesn't ask.
    ///   - onRecord: Called when the notification or its Record button is clicked.
    init(isRecording: @escaping () -> Bool, onRecord: @escaping () -> Void) {
        self.isRecording = isRecording
        self.onRecord = onRecord
        NotificationRouter.shared.register(
            UNNotificationCategory(
                identifier: Self.category,
                actions: [UNNotificationAction(identifier: Self.recordAction, title: "Record")],
                intentIdentifiers: []
            )
        ) { [weak self] response in
            let clicked = [Self.recordAction, UNNotificationDefaultActionIdentifier]
            guard clicked.contains(response.actionIdentifier) else { return }
            self?.onRecord()
        }
    }

    private func start() {
        Self.logger.info("Watching for meetings")
        let detector = MeetingDetector(monitor: CoreAudioInputActivityMonitor())
        detection = Task { [weak self] in
            await detector.run { [weak self] event in self?.handle(event) }
        }
    }

    private func stop() {
        detection?.cancel()
        detection = nil
        withdrawPrompts()
    }

    /// Takes away the notifications posted so far, e.g. once a recording has started some other way.
    func withdrawPrompts() {
        for id in promptIDs.values { Notifications.remove(id: id) }
        promptIDs = [:]
    }

    private func handle(_ event: MeetingDetector.Event) {
        switch event {
        case .started(let app):
            guard !isRecording() else {
                Self.logger.info("\(app.name, privacy: .public) started a call; not asking, already recording")
                return
            }
            Self.logger.info("\(app.name, privacy: .public) started a call; asking to record")
            let id = "meeting-\(UUID().uuidString)"
            promptIDs[app.name] = id
            Task {
                await Notifications.post(
                    title: "Record This Meeting?",
                    body: "\(app.name) is using the microphone. Click to record.",
                    categoryIdentifier: Self.category,
                    id: id
                )
            }
        case .ended(let app):
            Self.logger.info("\(app.name, privacy: .public) ended its call")
            // Clicking Record on a meeting that's over would start an empty recording.
            if let id = promptIDs.removeValue(forKey: app.name) { Notifications.remove(id: id) }
        }
    }
}
