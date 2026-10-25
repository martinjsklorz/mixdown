import Foundation
import MixdownCore
import Testing

@MainActor
struct CallDetectorTests {
    private let zoom = AudioInputClient(processID: 100, bundleID: "us.zoom.xos")
    private let chromeHelper = AudioInputClient(processID: 200, bundleID: "com.google.Chrome.helper")
    private static let ownProcessID: Int32 = 1

    /// A process that plays audio without recording.
    private func playing(_ processID: Int32, bundleID: String = "us.zoom.xos") -> AudioInputClient {
        AudioInputClient(processID: processID, bundleID: bundleID, isRunningInput: false, isRunningOutput: true)
    }
    private static let zoomApp = CallApp.known[0]

    /// Runs a detector on a mock monitor and collects its events.
    @MainActor private final class Harness {
        let monitor = MockInputActivityMonitor()
        var events: [CallDetector.Event] = []
        let detector: CallDetector
        private var run: Task<Void, Never>?

        init(apps: [CallApp] = CallApp.known) {
            detector = CallDetector(
                monitor: monitor,
                apps: apps,
                ownProcessID: CallDetectorTests.ownProcessID,
                startDelay: .milliseconds(50),
                endDelay: .milliseconds(50)
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
        let chrome = CallApp(name: "Chrome", bundleIDs: ["com.google.Chrome"])
        #expect(chrome.matches(bundleID: "com.google.Chrome"))
        #expect(chrome.matches(bundleID: "com.google.Chrome.helper"))
        #expect(chrome.matches(bundleID: "com.google.chrome.helper"))
        #expect(!chrome.matches(bundleID: "com.google.Chromecast"))
        #expect(!chrome.matches(bundleID: "com.google"))
    }

    @Test func knownAppsIncludeCallAppsAndBrowsers() {
        func name(of bundleID: String) -> String? {
            CallApp.known.first { $0.matches(bundleID: bundleID) }?.name
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
        #expect(name(of: "ru.keepcoder.Telegram") == "Telegram")
        #expect(name(of: "com.tdesktop.Telegram") == "Telegram")
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
        #expect(harness.detector.activeCalls == [Self.zoomApp])
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
        #expect(harness.detector.activeCalls.map(\.name) == ["Webex"])
        await harness.stop()
    }

    @Test func ignoresOwnAndUnknownProcesses() async throws {
        let harness = Harness()
        let ignored = [
            AudioInputClient(processID: Self.ownProcessID, bundleID: "com.google.Chrome"),
            AudioInputClient(processID: 300, bundleID: "com.apple.VoiceMemos"),
            AudioInputClient(processID: 301, bundleID: nil),
        ]
        // Sent first, so any of them reported would be before Zoom.
        harness.send(ignored)
        harness.send(ignored + [zoom])
        try await waitUntil { !harness.events.isEmpty }
        #expect(harness.events == [.started(Self.zoomApp)])
        #expect(harness.detector.activeCalls == [Self.zoomApp])
        await harness.stop()
    }

    @Test func reportsEndOnceAppStopsRecording() async throws {
        let harness = Harness()
        harness.send([zoom, chromeHelper])
        try await waitUntil { harness.events.count == 2 }

        harness.send([chromeHelper])
        try await waitUntil { harness.events.count == 3 }
        #expect(harness.events.last == .ended(Self.zoomApp))
        #expect(harness.detector.activeCalls.map(\.name) == ["Google Chrome"])
        await harness.stop()
    }

    @Test func nextCallAfterAnEndedOneIsReportedAgain() async throws {
        let harness = Harness()
        harness.send([zoom])
        try await waitUntil { harness.events.count == 1 }
        harness.send([])
        try await waitUntil { harness.events.count == 2 }

        // Call apps may record the next call from a new process.
        harness.send([AudioInputClient(processID: 101, bundleID: "us.zoom.xos")])
        try await waitUntil { harness.events.count == 3 }
        #expect(harness.events == [.started(Self.zoomApp), .ended(Self.zoomApp), .started(Self.zoomApp)])
        await harness.stop()
    }

    @Test func mutedCallGoesOnWhileItsAppPlaysTheCall() async throws {
        let harness = Harness()
        harness.send([zoom])
        try await waitUntil { harness.events.count == 1 }

        // Muted: the microphone is let go of, the others still play.
        let muted = playing(100)
        harness.send([muted])
        try await Task.sleep(for: .milliseconds(200))
        #expect(harness.events == [.started(Self.zoomApp)])

        harness.send([])
        try await waitUntil { harness.events.count == 2 }
        #expect(harness.events.last == .ended(Self.zoomApp))
        await harness.stop()
    }

    @Test func playingAudioAloneStartsNoCall() async throws {
        let harness = Harness()
        harness.send([playing(100)])
        try await Task.sleep(for: .milliseconds(200))
        #expect(harness.events.isEmpty)
        await harness.stop()
    }

    @Test func onlyProcessesThatRecordedKeepACallGoing() async throws {
        let harness = Harness()
        harness.send([zoom])
        try await waitUntil { harness.events.count == 1 }

        // Another of the app's processes playing, e.g. a notification sound, isn't the call.
        harness.send([playing(102)])
        try await waitUntil { harness.events.count == 2 }
        #expect(harness.events.last == .ended(Self.zoomApp))
        await harness.stop()
    }

    @Test func browserCallEndsWhenTheMicrophoneIsLetGoOf() async throws {
        let harness = Harness()
        harness.send([chromeHelper])
        try await waitUntil { harness.events.count == 1 }

        // Playing a video after leaving the meeting.
        harness.send([
            playing(200, bundleID: "com.google.Chrome.helper")
        ])
        try await waitUntil { harness.events.count == 2 }
        #expect(harness.events.last?.isEnded == true)
        await harness.stop()
    }

    @Test func ignoresAppsThatDontCount() async throws {
        let harness = Harness(apps: CallApp.known.filter { $0.name != "Zoom" })
        harness.send([zoom])
        harness.send([zoom, chromeHelper])
        try await waitUntil { !harness.events.isEmpty }
        #expect(harness.detector.activeCalls.map(\.name) == ["Google Chrome"])
        await harness.stop()
    }

    @Test func followsChangesToTheAppsThatCount() async throws {
        let harness = Harness()
        harness.send([zoom])
        try await waitUntil { !harness.events.isEmpty }

        harness.detector.apps = CallApp.known.filter { $0.name != "Zoom" }
        try await waitUntil { harness.events.count == 2 }
        #expect(harness.events.last == .ended(Self.zoomApp))

        harness.detector.apps = CallApp.known
        try await waitUntil { harness.events.count == 3 }
        #expect(harness.events.last == .started(Self.zoomApp))
        await harness.stop()
    }

    @Test func recognizesAddedApps() async throws {
        var selection = CallAppSelection()
        let added = selection.add(name: "Around", bundleID: "co.teamport.around")
        let harness = Harness(apps: selection.apps)
        harness.send([AudioInputClient(processID: 500, bundleID: "co.teamport.around.helper")])
        try await waitUntil { !harness.events.isEmpty }
        #expect(harness.events == [.started(added)])
        await harness.stop()
    }

    @Test func selectionTurnsKnownAppsOffAndOn() {
        var selection = CallAppSelection()
        #expect(selection.apps == CallApp.known)

        selection.set(Self.zoomApp, included: false)
        #expect(!selection.includes(Self.zoomApp))
        #expect(!selection.apps.contains(Self.zoomApp))

        selection.set(Self.zoomApp, included: true)
        #expect(selection.apps == CallApp.known)
    }

    @Test func addingAKnownAppTurnsItOnInstead() {
        var selection = CallAppSelection()
        selection.set(Self.zoomApp, included: false)
        let app = selection.add(name: "zoom.us", bundleID: "us.zoom.xos")
        #expect(app == Self.zoomApp)
        #expect(selection.added.isEmpty)
        #expect(selection.includes(Self.zoomApp))

        let webex = selection.add(name: "Webex", bundleID: "Cisco-Systems.SparkHelper")
        #expect(webex.name == "Webex")
        #expect(selection.added.isEmpty)
    }

    @Test func addedAppsAreAddedOnceAndRemoved() throws {
        var selection = CallAppSelection()
        let app = selection.add(name: "Around", bundleID: "co.teamport.around")
        selection.add(name: "Around 2", bundleID: "co.teamport.around")
        #expect(selection.added == [app])
        #expect(selection.apps.last == app)

        let decoded = try JSONDecoder().decode(CallAppSelection.self, from: JSONEncoder().encode(selection))
        #expect(decoded == selection)

        selection.set(app, included: false)
        #expect(selection.added.isEmpty)
        #expect(!selection.includes(app))
    }

    @Test func stoppingDropsActiveCalls() async throws {
        let harness = Harness()
        harness.send([zoom])
        try await waitUntil { !harness.events.isEmpty }

        await harness.stop()
        #expect(harness.detector.activeCalls.isEmpty)
        #expect(harness.events == [.started(Self.zoomApp)])
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

extension CallDetector.Event {
    fileprivate var isEnded: Bool {
        if case .ended = self { true } else { false }
    }
}
