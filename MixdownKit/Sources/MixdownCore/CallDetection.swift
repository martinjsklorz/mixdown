import Foundation

/// A process that is recording from an audio input right now.
public struct AudioInputClient: Hashable, Sendable {
    public let processID: Int32
    /// `nil` for processes without a bundle, such as command-line tools.
    public let bundleID: String?
    /// The app whose bundle the process runs from: for a helper such as
    /// `Webex.app/Contents/Frameworks/…/Helper.app`, that's `Webex.app`; for an app's main process,
    /// the app itself. `nil` if it isn't in an app or that can't be read.
    public let appBundleID: String?

    public init(processID: Int32, bundleID: String?, appBundleID: String? = nil) {
        self.processID = processID
        self.bundleID = bundleID
        self.appBundleID = appBundleID
    }
}

/// Reports which processes are recording from an audio input.
public protocol AudioInputActivityMonitoring: Sendable {
    /// Emits the processes using an input now, then the new list whenever it changes. Finishes
    /// when the consumer cancels.
    func inputClients() -> AsyncStream<[AudioInputClient]>
}

/// An app people hold calls in, recognized by the bundle IDs of the processes it records with.
public struct CallApp: Hashable, Sendable {
    public let name: String
    /// Bundle IDs of the app. Its helper processes count too: those whose bundle ID continues one
    /// of these, e.g. `com.google.Chrome.helper`, and those inside the app's bundle.
    public let bundleIDs: [String]

    public init(name: String, bundleIDs: [String]) {
        self.name = name
        self.bundleIDs = bundleIDs
    }

    /// Whether `bundleID` is one of `bundleIDs` or a helper of one (it continues with a dot).
    /// Case-insensitive, since helpers don't always keep the app's capitalization.
    public func matches(bundleID: String) -> Bool {
        let bundleID = bundleID.lowercased()
        return bundleIDs.contains { id in
            let id = id.lowercased()
            return bundleID == id || bundleID.hasPrefix(id + ".")
        }
    }

    /// Call and voice chat apps, and browsers (for Google Meet and calls in the browser). Many
    /// record from helper processes; see `bundleIDs`.
    public static let known: [CallApp] = [
        CallApp(name: "Zoom", bundleIDs: ["us.zoom.xos"]),
        CallApp(name: "Microsoft Teams", bundleIDs: ["com.microsoft.teams2", "com.microsoft.teams"]),
        // Webex records in `Cisco-Systems.SparkHelper`, which the prefix match doesn't cover.
        CallApp(
            name: "Webex",
            bundleIDs: ["Cisco-Systems.Spark", "Cisco-Systems.SparkHelper", "com.cisco.webexmeetingsapp"]
        ),
        CallApp(name: "Slack", bundleIDs: ["com.tinyspeck.slackmacgap"]),
        // FaceTime records in `avconferenced`, the system's call daemon, not in the app.
        CallApp(name: "FaceTime", bundleIDs: ["com.apple.FaceTime", "com.apple.avconferenced"]),
        CallApp(name: "Discord", bundleIDs: ["com.hnc.Discord", "com.hnc.DiscordPTB", "com.hnc.DiscordCanary"]),
        // Mumble 1.5 says `mumble-client`; older versions `net.sourceforge.mumble.Mumble`.
        CallApp(
            name: "Mumble",
            bundleIDs: ["mumble-client", "info.mumble.Mumble", "net.sourceforge.mumble.Mumble"]
        ),
        CallApp(name: "TeamSpeak", bundleIDs: ["com.teamspeak.TeamSpeak3", "com.teamspeak.TeamSpeak"]),
        CallApp(name: "WhatsApp", bundleIDs: ["net.whatsapp.WhatsApp", "desktop.WhatsApp"]),
        // Telegram for macOS (App Store) and Telegram Desktop.
        CallApp(name: "Telegram", bundleIDs: ["ru.keepcoder.Telegram", "com.tdesktop.Telegram"]),
        CallApp(name: "Signal", bundleIDs: ["org.whispersystems.signal-desktop"]),
        CallApp(name: "Element", bundleIDs: ["im.riot.app"]),
        CallApp(name: "Viber", bundleIDs: ["com.viber.osx"]),
        CallApp(name: "GoTo Meeting", bundleIDs: ["com.logmein.GoToMeeting"]),
        CallApp(name: "Jitsi Meet", bundleIDs: ["org.jitsi.jitsi-meet"]),
        // Safari records in WebKit's shared GPU process, which other WebKit apps use too.
        CallApp(name: "Safari", bundleIDs: ["com.apple.Safari", "com.apple.WebKit.GPU"]),
        CallApp(name: "Google Chrome", bundleIDs: ["com.google.Chrome"]),
        CallApp(name: "Microsoft Edge", bundleIDs: ["com.microsoft.edgemac"]),
        // Firefox records in its main process, not in its sandboxed content processes.
        CallApp(
            name: "Firefox",
            bundleIDs: ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly"]
        ),
        CallApp(name: "Arc", bundleIDs: ["company.thebrowser.Browser"]),
        CallApp(name: "Brave", bundleIDs: ["com.brave.Browser"]),
        CallApp(name: "Vivaldi", bundleIDs: ["com.vivaldi.Vivaldi"]),
        CallApp(name: "Opera", bundleIDs: ["com.operasoftware.Opera"]),
    ]
}

/// Watches which apps record from an audio input and reports when a call app starts and stops
/// doing so, so Mixdown can offer to record the call.
///
/// An app has to keep its input running for `startDelay` before it counts as a call, which
/// skips the brief microphone checks browsers and call apps make. It has to stop for `endDelay`
/// before the call counts as over, so switching microphones mid-call doesn't start a new one.
@MainActor
public final class CallDetector {
    public enum Event: Equatable, Sendable {
        case started(CallApp)
        case ended(CallApp)
    }

    /// Apps that are in a call, i.e. have been reported as started and not yet as ended.
    public private(set) var activeCalls: Set<CallApp> = []

    private let monitor: any AudioInputActivityMonitoring
    private let apps: [CallApp]
    private let ownProcessID: Int32
    private let startDelay: Duration
    private let endDelay: Duration

    /// Apps using an input in the latest list.
    private var recordingApps: Set<CallApp> = []
    /// Waits for `startDelay` or `endDelay` before reporting, by app.
    private var pending: [CallApp: Task<Void, Never>] = [:]

    /// - Parameter ownProcessID: Mixdown's own process, which is ignored, so its own recordings
    ///   don't count.
    public init(
        monitor: any AudioInputActivityMonitoring,
        apps: [CallApp] = CallApp.known,
        ownProcessID: Int32 = ProcessInfo.processInfo.processIdentifier,
        startDelay: Duration = .seconds(3),
        endDelay: Duration = .seconds(5)
    ) {
        self.monitor = monitor
        self.apps = apps
        self.ownProcessID = ownProcessID
        self.startDelay = startDelay
        self.endDelay = endDelay
    }

    /// Follows the monitor and calls `handle` for every call that starts or ends, until the
    /// calling task is cancelled. Calls still active then are dropped without an `.ended`.
    public func run(_ handle: @escaping @MainActor (Event) -> Void) async {
        for await clients in monitor.inputClients() {
            update(recordingApps: apps(in: clients), handle: handle)
        }
        for task in pending.values { task.cancel() }
        pending = [:]
        recordingApps = []
        activeCalls = []
    }

    /// The known apps among `clients`, other than Mixdown.
    private func apps(in clients: [AudioInputClient]) -> Set<CallApp> {
        var found = Set<CallApp>()
        for client in clients where client.processID != ownProcessID {
            let bundleIDs = [client.bundleID, client.appBundleID].compactMap { $0 }
            guard let app = apps.first(where: { app in bundleIDs.contains { app.matches(bundleID: $0) } })
            else { continue }
            found.insert(app)
        }
        return found
    }

    private func update(recordingApps newApps: Set<CallApp>, handle: @escaping @MainActor (Event) -> Void) {
        let changed = newApps.symmetricDifference(recordingApps)
        recordingApps = newApps
        for app in changed {
            pending.removeValue(forKey: app)?.cancel()
            // Back to what's been reported already (a blip, or a short gap mid-call): nothing to do.
            guard newApps.contains(app) != activeCalls.contains(app) else { continue }

            let isStarting = newApps.contains(app)
            let delay = isStarting ? startDelay : endDelay
            pending[app] = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                self.pending[app] = nil
                if isStarting {
                    self.activeCalls.insert(app)
                    handle(.started(app))
                } else {
                    self.activeCalls.remove(app)
                    handle(.ended(app))
                }
            }
        }
    }
}
