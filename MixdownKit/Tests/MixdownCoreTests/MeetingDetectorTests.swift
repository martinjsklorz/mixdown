import Foundation
import MixdownCore
import Testing

@MainActor
struct MeetingDetectorTests {
    private let zoom = AudioInputClient(processID: 100, bundleID: "us.zoom.xos")
    private let chromeHelper = AudioInputClient(processID: 200, bundleID: "com.google.Chrome.helper")
    private static let ownProcessID: Int32 = 1
    private static let zoomApp = MeetingApp.known[0]

    /// Runs a detector on a mock monitor and collects its events.
    @MainActor private final class Harness {
        let monitor = MockInputActivityMonitor()
        var events: [MeetingDetector.Event] = []
        let detector: MeetingDetector
        private var run: Task<Void, Never>?

        init(startDelay: Duration = .milliseconds(50), endDelay: Duration = .milliseconds(50)) {
            detector = MeetingDetector(
                monitor: monitor,
                ownProcessID: MeetingDetectorTests.ownProcessID,
                startDelay: startDelay,
                endDelay: endDelay
            )
            run = Task { [detector] in
                await detector.run { [weak self] event in self?.events.append(event) }
            }
        }

        func send(_ clients: [AudioInputClient]) { monitor.send(clients) }

        func stop() async {
            run?.cancel()
            await run?.value
        }
    }

    @Test func matchesAppsAndTheirHelpers() {
        let chrome = MeetingApp(name: "Chrome", bundleIDs: ["com.google.Chrome"])
        #expect(chrome.matches(bundleID: "com.google.Chrome"))
        #expect(chrome.matches(bundleID: "com.google.Chrome.helper"))
        #expect(chrome.matches(bundleID: "com.google.chrome.helper"))
        #expect(!chrome.matches(bundleID: "com.google.Chromecast"))
        #expect(!chrome.matches(bundleID: "com.google"))
    }

    @Test func knownAppsIncludeCallAppsAndBrowsers() {
        func name(of bundleID: String) -> String? {
            MeetingApp.known.first { $0.matches(bundleID: bundleID) }?.name
        }
        #expect(name(of: "us.zoom.xos") == "Zoom")
        #expect(name(of: "com.microsoft.teams2") == "Microsoft Teams")
        #expect(name(of: "com.microsoft.teams") == "Microsoft Teams")
        #expect(name(of: "com.apple.WebKit.GPU") == "Safari")
        #expect(name(of: "com.microsoft.edgemac.helper") == "Microsoft Edge")
        #expect(name(of: "Cisco-Systems.SparkHelper") == "Webex")
        #expect(name(of: "com.hnc.Discord.helper") == "Discord")
        #expect(name(of: "com.apple.FaceTime") == "FaceTime")
        #expect(name(of: "mumble-client") == "Mumble")
        #expect(name(of: "org.mozilla.firefox") == "Firefox")
        #expect(name(of: "org.mozilla.firefoxdeveloperedition") == "Firefox")
        #expect(name(of: "org.mozilla.plugincontainer") == nil)
        #expect(name(of: "com.apple.Music") == nil)
    }

    @Test func reportsAppThatKeepsRecording() async throws {
        let harness = Harness()
        harness.send([])
        harness.send([zoom])
        #expect(harness.events.isEmpty)

        try await waitUntil { !harness.events.isEmpty }
        #expect(harness.events == [.started(Self.zoomApp)])
        #expect(harness.detector.activeMeetings == [Self.zoomApp])
        await harness.stop()
    }

    @Test func ignoresBriefMicrophoneChecks() async throws {
        let harness = Harness(startDelay: .milliseconds(200))
        harness.send([zoom])
        try await Task.sleep(for: .milliseconds(20))
        harness.send([])
        try await Task.sleep(for: .milliseconds(400))
        #expect(harness.events.isEmpty)
        await harness.stop()
    }

    @Test func recognizesHelpersInsideAnAppsBundle() async throws {
        let harness = Harness()
        harness.send([
            AudioInputClient(
                processID: 400,
                bundleID: "com.example.helper",
                appBundleID: "Cisco-Systems.Spark"
            )
        ])
        try await waitUntil { !harness.events.isEmpty }
        #expect(harness.events.map(\.app.name) == ["Webex"])
        await harness.stop()
    }

    @Test func ignoresOwnAndUnknownProcesses() async throws {
        let harness = Harness()
        harness.send([
            AudioInputClient(processID: Self.ownProcessID, bundleID: "com.google.Chrome"),
            AudioInputClient(processID: 300, bundleID: "com.apple.VoiceMemos"),
            AudioInputClient(processID: 301, bundleID: nil),
        ])
        try await Task.sleep(for: .milliseconds(200))
        #expect(harness.events.isEmpty)
        await harness.stop()
    }

    @Test func reportsEndOnceAppStopsRecording() async throws {
        let harness = Harness()
        harness.send([zoom, chromeHelper])
        try await waitUntil { harness.events.count == 2 }

        harness.send([chromeHelper])
        try await waitUntil { harness.events.count == 3 }
        #expect(harness.events.last == .ended(Self.zoomApp))
        #expect(harness.detector.activeMeetings.map(\.name) == ["Google Chrome"])
        await harness.stop()
    }

    @Test func nextMeetingAfterAnEndedOneIsReportedAgain() async throws {
        let harness = Harness()
        harness.send([zoom])
        try await waitUntil { harness.events.count == 1 }
        harness.send([])
        try await waitUntil { harness.events.count == 2 }

        // Call apps may record the next meeting from a new process.
        harness.send([AudioInputClient(processID: 101, bundleID: "us.zoom.xos")])
        try await waitUntil { harness.events.count == 3 }
        #expect(harness.events == [.started(Self.zoomApp), .ended(Self.zoomApp), .started(Self.zoomApp)])
        await harness.stop()
    }

    @Test func shortGapMidCallIsTheSameMeeting() async throws {
        let harness = Harness(endDelay: .milliseconds(200))
        harness.send([zoom])
        try await waitUntil { harness.events == [.started(Self.zoomApp)] }

        // E.g. switching microphones restarts the input.
        harness.send([])
        try await Task.sleep(for: .milliseconds(20))
        harness.send([AudioInputClient(processID: 100, bundleID: "us.zoom.xos")])
        try await Task.sleep(for: .milliseconds(400))
        #expect(harness.events == [.started(Self.zoomApp)])
        await harness.stop()
    }

    @Test func stoppingDropsActiveMeetings() async throws {
        let harness = Harness()
        harness.send([zoom])
        try await waitUntil { !harness.events.isEmpty }

        await harness.stop()
        #expect(harness.detector.activeMeetings.isEmpty)
        #expect(harness.events == [.started(Self.zoomApp)])
    }
}

extension MeetingDetector.Event {
    var app: MeetingApp {
        switch self {
        case .started(let app), .ended(let app): app
        }
    }
}

/// Hands out one stream; `send` yields to it.
final class MockInputActivityMonitor: AudioInputActivityMonitoring {
    private let stream: AsyncStream<[AudioInputClient]>
    private let continuation: AsyncStream<[AudioInputClient]>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    func inputClients() -> AsyncStream<[AudioInputClient]> { stream }

    func send(_ clients: [AudioInputClient]) { continuation.yield(clients) }
}
