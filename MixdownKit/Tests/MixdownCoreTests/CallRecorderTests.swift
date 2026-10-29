import Foundation
import MixdownCore
import Testing

@MainActor
struct CallRecorderTests {
    private static let zoom = AudioInputClient(processID: 100, bundleID: "us.zoom.xos")

    /// Keeps what `CallRecorder` posted and took away.
    @MainActor private final class FakeNotifier: CallNotifying {
        var posted: [(notice: CallNotice, id: String)] = []
        var removed: [String] = []

        func post(_ notice: CallNotice, id: String) { posted.append((notice, id)) }
        func remove(id: String) { removed.append(id) }

        func id(of notice: CallNotice) -> String? { posted.last { $0.notice == notice }?.id }
    }

    /// A recorder on a mock monitor, with a recording that starts and stops as it's told.
    @MainActor private final class Harness {
        let monitor = MockInputActivityMonitor()
        let notifier = FakeNotifier()
        var isRecording = false
        var canRecord = true
        var timeSinceSpeech: Duration? = .seconds(60)
        var starts = 0
        var stops = 0
        var markedAsCall: [(app: String?, automatically: Bool)] = []
        var recorderShown = 0
        private(set) var recorder: CallRecorder!

        init(timing: CallRecorder.Timing = .init(quietBeforeStop: .milliseconds(40), longestWaitToStop: .seconds(1))) {
            recorder = CallRecorder(
                isRecording: { [unowned self] in isRecording },
                timeSinceSpeech: { [unowned self] in timeSinceSpeech },
                startRecording: { [unowned self] in
                    guard canRecord else { return false }
                    starts += 1
                    isRecording = true
                    return true
                },
                stopRecording: { [unowned self] in stops += 1 },
                markRecordingAsCall: { [unowned self] app, automatically in markedAsCall.append((app, automatically)) },
                showRecorder: { [unowned self] in recorderShown += 1 },
                notifier: notifier,
                makeDetector: { [monitor] apps in
                    CallDetector(
                        monitor: monitor,
                        apps: apps,
                        ownProcessID: 1,
                        startDelay: .milliseconds(10),
                        endDelay: .milliseconds(10)
                    )
                },
                timing: timing
            )
        }

        /// Starts a call and waits until the detector has said so.
        func callStarts() async throws {
            monitor.send([CallRecorderTests.zoom])
            try await Task.sleep(for: .milliseconds(60))
        }

        /// Ends the call and waits until the detector has said so.
        func callEnds() async throws {
            monitor.send([])
            try await Task.sleep(for: .milliseconds(60))
        }

        /// The recording the recorder asked for has started, as the coordinator would say.
        func recordingStarted() {
            recorder.recordingDidStart()
        }

        func recordingStopped() {
            isRecording = false
            recorder.recordingDidStop()
        }
    }

    // MARK: Prompts

    @Test func recordPromptGoesAwayWhenTheCallEnds() async throws {
        let harness = Harness()
        harness.recorder.notifies = true
        try await harness.callStarts()
        let id = try #require(harness.notifier.id(of: .recordPrompt(app: "Zoom")))

        try await harness.callEnds()
        #expect(harness.notifier.removed == [id])
        // Clicking it now would start an empty recording.
        harness.recorder.recordFromPrompt(app: "Zoom", id: id)
        #expect(harness.starts == 0)
    }

    @Test func clickingTheRecordPromptRecordsTheCall() async throws {
        let harness = Harness()
        harness.recorder.notifies = true
        try await harness.callStarts()
        let id = try #require(harness.notifier.id(of: .recordPrompt(app: "Zoom")))

        harness.recorder.recordFromPrompt(app: "Zoom", id: id)
        harness.recordingStarted()
        #expect(harness.starts == 1)
        #expect(harness.markedAsCall.map(\.app) == ["Zoom"])
        #expect(harness.markedAsCall.map(\.automatically) == [false])
        #expect(harness.notifier.removed == [id])
    }

    @Test func aStaleRecordPromptIsOnlyTakenAway() async throws {
        let harness = Harness()
        harness.recorder.notifies = true
        try await harness.callStarts()

        harness.recorder.recordFromPrompt(app: "Zoom", id: "from-an-earlier-run")
        #expect(harness.starts == 0)
        #expect(harness.notifier.removed == ["from-an-earlier-run"])
    }

    @Test func aStaleStopPromptDoesntStopANewerRecording() async throws {
        let harness = Harness()
        harness.recorder.notifies = true
        harness.isRecording = true  // started by hand
        try await harness.callStarts()
        try await harness.callEnds()
        let id = try #require(harness.notifier.id(of: .stopPrompt(app: "Zoom")))

        harness.recorder.stopFromPrompt(id: "from-an-earlier-run")
        #expect(harness.stops == 0)
        harness.recorder.stopFromPrompt(id: id)
        #expect(harness.stops == 1)
    }

    @Test func closingARecordPromptSnoozesTheApp() async throws {
        let harness = Harness()
        harness.recorder.notifies = true
        try await harness.callStarts()
        let id = try #require(harness.notifier.id(of: .recordPrompt(app: "Zoom")))
        harness.recorder.recordPromptDismissed(app: "Zoom", id: id)
        try await harness.callEnds()

        harness.monitor.send([Self.zoom])
        try await Task.sleep(for: .milliseconds(60))
        #expect(harness.notifier.posted.count == 1)
    }

    @Test func closingAStalePromptKeepsTheCurrentOneTracked() async throws {
        let harness = Harness()
        harness.recorder.notifies = true
        try await harness.callStarts()
        let id = try #require(harness.notifier.id(of: .recordPrompt(app: "Zoom")))

        harness.recorder.recordPromptDismissed(app: "Zoom", id: "from-an-earlier-run")
        try await harness.callEnds()
        #expect(harness.notifier.removed == [id])
    }

    @Test func turningNotificationsOffTakesThemAway() async throws {
        let harness = Harness()
        harness.recorder.notifies = true
        try await harness.callStarts()
        let id = try #require(harness.notifier.id(of: .recordPrompt(app: "Zoom")))

        harness.recorder.notifies = false
        #expect(harness.notifier.removed == [id])
    }

    // MARK: Recording automatically

    @Test func anAutomaticRecordingStopsOnceItsCallEndedAndItsQuiet() async throws {
        let harness = Harness()
        harness.recorder.notifies = true
        harness.recorder.recordsAutomatically = true
        try await harness.callStarts()
        harness.recordingStarted()
        #expect(harness.starts == 1)
        #expect(harness.markedAsCall.map(\.automatically) == [true])
        #expect(harness.notifier.id(of: .recordingCall(app: "Zoom")) != nil)

        harness.timeSinceSpeech = .zero
        try await harness.callEnds()
        #expect(harness.stops == 0)
        harness.timeSinceSpeech = .seconds(60)
        try await waitUntil { harness.stops == 1 }
        try await waitUntil { harness.notifier.id(of: .recordingStopped(app: "Zoom")) != nil }
    }

    @Test func anAutomaticRecordingStopsAtTheDeadlineEvenIfPeopleTalk() async throws {
        let harness = Harness(timing: .init(quietBeforeStop: .seconds(10), longestWaitToStop: .milliseconds(80)))
        harness.recorder.recordsAutomatically = true
        try await harness.callStarts()
        harness.recordingStarted()
        harness.timeSinceSpeech = .zero

        try await harness.callEnds()
        try await waitUntil { harness.stops == 1 }
    }

    @Test func aCallStartingAgainCancelsTheStop() async throws {
        let harness = Harness(timing: .init(quietBeforeStop: .seconds(10), longestWaitToStop: .milliseconds(150)))
        harness.recorder.recordsAutomatically = true
        try await harness.callStarts()
        harness.recordingStarted()
        harness.timeSinceSpeech = .zero

        try await harness.callEnds()
        harness.monitor.send([Self.zoom])
        try await Task.sleep(for: .milliseconds(250))
        #expect(harness.stops == 0)
    }

    @Test func aRecordingStartedByHandIsNeverStoppedForACall() async throws {
        let harness = Harness()
        harness.recorder.recordsAutomatically = true
        harness.isRecording = true
        harness.recordingStarted()
        try await harness.callStarts()
        try await harness.callEnds()
        try await Task.sleep(for: .milliseconds(100))
        #expect(harness.stops == 0)
        #expect(harness.markedAsCall.isEmpty)
    }

    @Test func whenItCantRecordItAsksAndOpensRecordOnClick() async throws {
        let harness = Harness()
        harness.canRecord = false
        harness.recorder.notifies = true
        harness.recorder.recordsAutomatically = true
        try await harness.callStarts()
        let id = try #require(harness.notifier.id(of: .recordPrompt(app: "Zoom")))

        harness.recorder.recordFromPrompt(app: "Zoom", id: id)
        #expect(harness.recorderShown == 1)
    }
}
