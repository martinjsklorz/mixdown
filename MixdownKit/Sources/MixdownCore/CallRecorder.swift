import Foundation
import os

/// A notification `CallRecorder` posts.
public enum CallNotice: Equatable, Sendable {
    /// "Record This Call?": the call in `app` started; clicking it records the call.
    case recordPrompt(app: String)
    /// "Stop Recording?": the call in `app` ended while recording; clicking it stops.
    case stopPrompt(app: String)
    /// "Recording Call": a recording of the call in `app` started automatically.
    case recordingCall(app: String)
    /// "Call Recording Stopped": the automatic recording stopped, as the call in `app` ended.
    case recordingStopped(app: String)
}

/// Posts `CallRecorder`'s notifications and takes them away.
@MainActor
public protocol CallNotifying: AnyObject {
    /// Posts `notice` as `id`. A notice taken away with `remove(id:)` before it shows never does.
    func post(_ notice: CallNotice, id: String)
    func remove(id: String)
}

/// Notifies about calls and records them, as `notifies` and `recordsAutomatically` say.
///
/// A call starts once Zoom, Discord, a browser or another call app has been using a microphone for
/// a few seconds, and ends once the last one has stopped for a few seconds; see `CallDetector`.
/// - Notifying, not recording automatically: When a call starts, posts a record prompt, which
///   records when clicked; it goes away again when the call ends. When the call ends while
///   recording, posts a stop prompt, which stops the recording when clicked; it goes away when
///   the recording stops or a call starts again.
/// - Recording automatically: Starts and stops recording by itself, and, if notifying, posts a
///   notice saying so. It stops once no one has spoken for `Timing.quietBeforeStop`, or after
///   `Timing.longestWaitToStop` at the latest, so a call that only seemed to end, or goodbyes said
///   after it, aren't cut off. If it can't record, e.g. as the model isn't downloaded, it asks
///   instead (if notifying), and clicking that opens Record, which says why. It only stops
///   recordings started for a call: one started by hand goes on, and it asks instead (if
///   notifying), as a call app may just have used the microphone briefly.
///
/// A recording it starts, from a prompt or automatically, is marked as a call in its app, so its
/// note says which app and is titled as a call. Recordings started any other way aren't, even
/// during a call. Only automatic ones are marked as started automatically: clicking a prompt is the
/// user's choice.
///
/// Closing a record prompt stops prompts about that app for `Timing.snoozeAfterDismissal`. Clicks
/// on a prompt other than the one posted last, such as one left from an earlier run, do nothing.
///
/// Call `recordingDidStart()` and `recordingDidStop()` as recordings come and go, and hand it the
/// clicks on its prompts.
@MainActor
public final class CallRecorder {
    public struct Timing: Sendable {
        /// How long no one may have spoken before an automatic recording whose call ended stops.
        public var quietBeforeStop: Duration
        /// How long after its call ended an automatic recording stops even if people still talk,
        /// or system audio plays something like speech.
        public var longestWaitToStop: Duration
        /// How long closing a record prompt stops prompts about that app.
        public var snoozeAfterDismissal: Duration

        public init(
            quietBeforeStop: Duration = .seconds(20),
            longestWaitToStop: Duration = .seconds(120),
            snoozeAfterDismissal: Duration = .seconds(30 * 60)
        ) {
            self.quietBeforeStop = quietBeforeStop
            self.longestWaitToStop = longestWaitToStop
            self.snoozeAfterDismissal = snoozeAfterDismissal
        }
    }

    /// Whether to post notifications. Turning it off takes away any that are open.
    public var notifies = false {
        didSet {
            guard notifies != oldValue else { return }
            if !notifies { withdrawNotifications() }
            updateWatching()
        }
    }

    /// Whether to start and stop recording with calls, without asking.
    public var recordsAutomatically = false {
        didSet { updateWatching() }
    }

    /// The apps that count as calls. Taking out one in a call ends its call.
    public var apps = CallApp.known {
        didSet { detector?.apps = apps }
    }

    /// A recording started for a call, until it has started.
    private enum Starting: Equatable {
        case none
        /// From a record prompt, for the call in the app with this name, if known.
        case fromPrompt(app: String?)
        /// By itself, for the call in this app.
        case automatically(CallApp)
    }

    private let isRecording: () -> Bool
    private let timeSinceSpeech: () -> Duration?
    private let startRecording: () -> Bool
    private let stopRecording: () -> Void
    private let markRecordingAsCall: (_ app: String?, _ automatically: Bool) -> Void
    private let showRecorder: () -> Void
    private let notifier: any CallNotifying
    private let makeDetector: (_ apps: [CallApp]) -> CallDetector
    private let timing: Timing

    private var detector: CallDetector?
    private var detection: Task<Void, Never>?
    /// The record prompt posted for each call that's going on, by app name.
    private var recordPromptIDs: [String: String] = [:]
    /// The stop prompt, while one is posted.
    private var stopPromptID: String?
    private var starting = Starting.none
    /// Whether the recording going on was started for a call, from a prompt or automatically.
    private var isRecordingCall = false
    /// The notice saying an automatic recording is going on.
    private var recordingNoticeID: String?
    /// Stops an automatic recording once its call has ended and it's quiet.
    private var pendingStop: Task<Void, Never>?
    /// Until when apps whose record prompt was closed aren't asked about again, by app name.
    private var snoozedUntil: [String: ContinuousClock.Instant] = [:]

    private static let logger = Logger(subsystem: "app.mixdown", category: "CallRecorder")

    /// - Parameters:
    ///   - isRecording: Whether Mixdown is recording, or starting to.
    ///   - timeSinceSpeech: How long it's been since anyone spoke in the recording, if anyone has.
    ///   - startRecording: Starts recording, returning `false` if it can't.
    ///   - stopRecording: Stops recording.
    ///   - markRecordingAsCall: Marks the recording in progress as a call in the app with the given
    ///     name, if known, and whether it was started automatically rather than from a prompt.
    ///   - showRecorder: Opens Record in the main window.
    ///   - notifier: Posts and takes away the notifications.
    ///   - makeDetector: The detector to watch calls with, for the apps given, while watching.
    public init(
        isRecording: @escaping () -> Bool,
        timeSinceSpeech: @escaping () -> Duration?,
        startRecording: @escaping () -> Bool,
        stopRecording: @escaping () -> Void,
        markRecordingAsCall: @escaping (_ app: String?, _ automatically: Bool) -> Void,
        showRecorder: @escaping () -> Void,
        notifier: any CallNotifying,
        makeDetector: @escaping (_ apps: [CallApp]) -> CallDetector,
        timing: Timing = Timing()
    ) {
        self.isRecording = isRecording
        self.timeSinceSpeech = timeSinceSpeech
        self.startRecording = startRecording
        self.stopRecording = stopRecording
        self.markRecordingAsCall = markRecordingAsCall
        self.showRecorder = showRecorder
        self.notifier = notifier
        self.makeDetector = makeDetector
        self.timing = timing
    }

    // MARK: Prompts

    /// Records the call in `app` for a click on its record prompt `id`, or opens Record if it
    /// can't, which says why. A prompt that's no longer current, such as one from an earlier run
    /// or for a call that has ended, is only taken away.
    public func recordFromPrompt(app: String?, id: String) {
        guard let app, recordPromptIDs[app] == id else {
            notifier.remove(id: id)
            return
        }
        // A recording that's going on already wasn't started for the call.
        guard !isRecording() else { return }
        starting = .fromPrompt(app: app)
        guard !startRecording() else { return }
        starting = .none
        showRecorder()
    }

    /// Stops recording for a click on the stop prompt `id`. One that's no longer current, such as
    /// one from an earlier run, is only taken away: it mustn't stop a newer recording.
    public func stopFromPrompt(id: String) {
        guard id == stopPromptID else {
            notifier.remove(id: id)
            return
        }
        stopRecording()
    }

    /// Doesn't prompt about `app` for `Timing.snoozeAfterDismissal`, as its record prompt `id` was
    /// closed.
    public func recordPromptDismissed(app: String, id: String) {
        Self.logger.info("Record prompt for \(app, privacy: .public) closed; not asking about it for a while")
        snoozedUntil[app] = .now + timing.snoozeAfterDismissal
        if recordPromptIDs[app] == id { recordPromptIDs[app] = nil }
    }

    // MARK: Recordings

    /// Takes away the record prompts, as there's nothing left to start, marks the recording as a
    /// call if it was started for one, and says so if that was automatic.
    public func recordingDidStart() {
        withdrawRecordPrompts()
        let starting = self.starting
        self.starting = .none
        switch starting {
        case .none:
            isRecordingCall = false
        case .fromPrompt(let app):
            isRecordingCall = true
            markRecordingAsCall(app, false)
        case .automatically(let app):
            isRecordingCall = true
            markRecordingAsCall(app.name, true)
            guard notifies else { return }
            let id = "call-recording-\(UUID().uuidString)"
            recordingNoticeID = id
            notifier.post(.recordingCall(app: app.name), id: id)
        }
    }

    /// Takes away the stop prompt and the recording notice, as there's nothing left to stop.
    public func recordingDidStop() {
        cancelPendingStop()
        withdrawStopPrompt()
        starting = .none
        isRecordingCall = false
        withdrawRecordingNotice()
    }

    // MARK: Watching

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
        let detector = makeDetector(apps)
        self.detector = detector
        detection = Task { [weak self] in
            await detector.run { [weak self] event in self?.handle(event) }
        }
    }

    private func stop() {
        detection?.cancel()
        detection = nil
        detector = nil
        cancelPendingStop()
        withdrawNotifications()
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
        cancelPendingStop()
        guard !isRecording() else {
            Self.logger.info("\(app.name, privacy: .public) started a call; already recording")
            return
        }
        if recordsAutomatically {
            starting = .automatically(app)
            if startRecording() {
                Self.logger.info("\(app.name, privacy: .public) started a call; recording it")
                return
            }
            starting = .none
            Self.logger.info("\(app.name, privacy: .public) started a call; can't record it")
        }
        guard notifies else {
            Self.logger.info("\(app.name, privacy: .public) started a call; not notifying")
            return
        }
        if let until = snoozedUntil[app.name], until > .now {
            Self.logger.info("\(app.name, privacy: .public) started a call; its prompt was closed recently")
            return
        }
        Self.logger.info("\(app.name, privacy: .public) started a call; asking to record")
        let id = "call-started-\(UUID().uuidString)"
        recordPromptIDs[app.name] = id
        notifier.post(.recordPrompt(app: app.name), id: id)
    }

    private func callEnded(_ app: CallApp) {
        // Clicking Record on a call that's over would start an empty recording.
        if let id = recordPromptIDs.removeValue(forKey: app.name) { notifier.remove(id: id) }
        guard isRecording(), detector?.activeCalls.isEmpty ?? true else {
            Self.logger.info("\(app.name, privacy: .public) ended its call")
            return
        }
        // A recording started by hand isn't the call's to stop, e.g. a call app used the
        // microphone briefly during an in-person recording.
        if recordsAutomatically, isRecordingCall {
            Self.logger.info("\(app.name, privacy: .public) ended its call; stopping the recording once it's quiet")
            stopWhenQuiet(after: app)
            return
        }
        if recordsAutomatically, starting != .none {
            Self.logger.info("\(app.name, privacy: .public) ended its call; stopping the recording")
            // A recording still starting, e.g. waiting on a permission prompt, is discarded as soon
            // as it has started, so it's neither announced nor said to have stopped.
            stopRecording()
            starting = .none
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
        notifier.post(.stopPrompt(app: app.name), id: id)
    }

    /// Stops the automatic recording of `app`'s call, which has ended, once no one has spoken for
    /// `Timing.quietBeforeStop`, or `Timing.longestWaitToStop` has passed. A call starting again
    /// cancels it.
    private func stopWhenQuiet(after app: CallApp) {
        cancelPendingStop()
        let timing = timing
        let deadline = ContinuousClock.now + timing.longestWaitToStop
        pendingStop = Task { [weak self] in
            while let quiet = self?.timeSinceSpeech(), quiet < timing.quietBeforeStop, ContinuousClock.now < deadline {
                try? await Task.sleep(for: min(timing.quietBeforeStop - quiet, deadline - ContinuousClock.now))
                guard !Task.isCancelled else { return }
            }
            guard !Task.isCancelled, let self else { return }
            self.pendingStop = nil
            guard self.isRecordingCall, self.detector?.activeCalls.isEmpty ?? true else { return }
            Self.logger.info("Stopping the recording of the ended \(app.name, privacy: .public) call")
            self.stopRecording()
            if self.notifies {
                self.notifier.post(.recordingStopped(app: app.name), id: UUID().uuidString)
            }
        }
    }

    private func cancelPendingStop() {
        pendingStop?.cancel()
        pendingStop = nil
    }

    // MARK: Withdrawing

    private func withdrawNotifications() {
        withdrawRecordPrompts()
        withdrawStopPrompt()
        withdrawRecordingNotice()
    }

    private func withdrawRecordingNotice() {
        guard let recordingNoticeID else { return }
        notifier.remove(id: recordingNoticeID)
        self.recordingNoticeID = nil
    }

    private func withdrawRecordPrompts() {
        for id in recordPromptIDs.values { notifier.remove(id: id) }
        recordPromptIDs = [:]
    }

    private func withdrawStopPrompt() {
        guard let stopPromptID else { return }
        notifier.remove(id: stopPromptID)
        self.stopPromptID = nil
    }
}
