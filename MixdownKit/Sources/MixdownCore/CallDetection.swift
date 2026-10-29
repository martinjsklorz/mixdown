import Foundation

/// A process that is recording from an audio input or playing audio right now.
public struct AudioInputClient: Hashable, Sendable {
    public let processID: Int32
    /// `nil` for processes without a bundle, such as command-line tools.
    public let bundleID: String?
    /// The app whose bundle the process runs from: for a helper such as
    /// `Webex.app/Contents/Frameworks/…/Helper.app`, that's `Webex.app`; for an app's main process,
    /// the app itself. `nil` if it isn't in an app or that can't be read.
    public let appBundleID: String?
    /// Whether it records from an input.
    public let isRunningInput: Bool
    /// Whether it plays audio. A call app that lets go of the microphone while muted still plays
    /// the call.
    public let isRunningOutput: Bool

    public init(
        processID: Int32,
        bundleID: String?,
        appBundleID: String? = nil,
        isRunningInput: Bool = true,
        isRunningOutput: Bool = false
    ) {
        self.processID = processID
        self.bundleID = bundleID
        self.appBundleID = appBundleID
        self.isRunningInput = isRunningInput
        self.isRunningOutput = isRunningOutput
    }
}

/// Reports which processes are recording from an audio input or playing audio.
public protocol AudioInputActivityMonitoring: Sendable {
    /// Emits the processes using an input or playing audio now, then the new list whenever it
    /// changes. Finishes when the consumer cancels.
    func inputClients() -> AsyncStream<[AudioInputClient]>
}

/// An app people hold calls in, recognized by the bundle IDs of the processes it records with.
public struct CallApp: Hashable, Codable, Identifiable, Sendable {
    public let name: String
    /// Bundle IDs of the app. Its helper processes count too: those whose bundle ID continues one
    /// of these, e.g. `com.google.Chrome.helper`, and those inside the app's bundle.
    public let bundleIDs: [String]
    /// Whether it's a browser, whose calls are in a website such as Google Meet, not in the app.
    public let isBrowser: Bool

    public init(name: String, bundleIDs: [String], isBrowser: Bool = false) {
        self.name = name
        self.bundleIDs = bundleIDs
        self.isBrowser = isBrowser
    }

    /// Its first bundle ID, which stays the same when the list of them grows.
    public var id: String { bundleIDs.first ?? name }

    private enum CodingKeys: String, CodingKey {
        case name, bundleIDs, isBrowser
    }

    /// Lenient, so an app stored by another version still reads. Throws only without bundle IDs,
    /// as such an app matches nothing.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleIDs = container.decodeLossyArray([String].self, forKey: .bundleIDs)
        guard let first = bundleIDs.first else {
            throw DecodingError.dataCorruptedError(
                forKey: .bundleIDs,
                in: container,
                debugDescription: "A call app needs a bundle ID"
            )
        }
        name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? first
        isBrowser = (try? container.decodeIfPresent(Bool.self, forKey: .isBrowser)) ?? false
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
        CallApp(name: "Safari", bundleIDs: ["com.apple.Safari", "com.apple.WebKit.GPU"], isBrowser: true),
        CallApp(name: "Google Chrome", bundleIDs: ["com.google.Chrome"], isBrowser: true),
        CallApp(name: "Microsoft Edge", bundleIDs: ["com.microsoft.edgemac"], isBrowser: true),
        // Firefox records in its main process, not in its sandboxed content processes.
        CallApp(
            name: "Firefox",
            bundleIDs: ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly"],
            isBrowser: true
        ),
        CallApp(name: "Arc", bundleIDs: ["company.thebrowser.Browser"], isBrowser: true),
        CallApp(name: "Brave", bundleIDs: ["com.brave.Browser"], isBrowser: true),
        CallApp(name: "Vivaldi", bundleIDs: ["com.vivaldi.Vivaldi"], isBrowser: true),
        CallApp(name: "Opera", bundleIDs: ["com.operasoftware.Opera"], isBrowser: true),
    ]
}

/// Which apps count as calls: the known ones not turned off, and those the user added.
public struct CallAppSelection: Codable, Equatable, Sendable {
    /// `id`s of the known apps turned off.
    public var excludedIDs: Set<String>
    /// Apps the user added, in the order they were added.
    public var added: [CallApp]

    public init(excludedIDs: Set<String> = [], added: [CallApp] = []) {
        self.excludedIDs = excludedIDs
        self.added = added
    }

    private enum CodingKeys: String, CodingKey {
        case excludedIDs, added
    }

    /// Lenient, so one odd app doesn't lose the user's whole selection.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        excludedIDs = Set(container.decodeLossyArray([String].self, forKey: .excludedIDs))
        added = container.decodeLossyArray([CallApp].self, forKey: .added)
    }

    /// The apps that count, known ones first.
    public var apps: [CallApp] {
        CallApp.known.filter { !excludedIDs.contains($0.id) } + added
    }

    public func includes(_ app: CallApp) -> Bool {
        added.contains(app) || (CallApp.known.contains(app) && !excludedIDs.contains(app.id))
    }

    /// Turns a known app on or off. Turning off an added app removes it.
    public mutating func set(_ app: CallApp, included: Bool) {
        if CallApp.known.contains(app) {
            if included { excludedIDs.remove(app.id) } else { excludedIDs.insert(app.id) }
        } else if !included {
            added.removeAll { $0 == app }
        } else if !added.contains(app) {
            added.append(app)
        }
    }

    /// Adds the app with `bundleID`, called `name`, and returns it. If it's known or added
    /// already, as itself or as a helper of one, that one is turned on and returned instead.
    @discardableResult
    public mutating func add(name: String, bundleID: String) -> CallApp {
        let app =
            (CallApp.known + added).first { $0.matches(bundleID: bundleID) }
            ?? CallApp(name: name, bundleIDs: [bundleID])
        set(app, included: true)
        return app
    }
}

/// Watches which apps record from an audio input and reports when a call app starts and stops
/// doing so, so Mixdown can offer to record the call.
///
/// An app has to keep its input running for `startDelay` before it counts as a call, which
/// skips the brief microphone checks browsers and call apps make. It has to stop for `endDelay`
/// before the call counts as over, so switching microphones mid-call doesn't start a new one.
///
/// Some call apps let go of the microphone while the user is muted. So once a call has started,
/// it goes on while a process of the app that recorded during it still plays audio. Browsers
/// aren't given that: one that played a video after leaving a meeting would keep the call going.
///
/// Only `apps` count. An app taken out of them mid-call ends its call, as if it had stopped
/// recording; one put in starts one if it's recording.
@MainActor
public final class CallDetector {
    public enum Event: Equatable, Sendable {
        case started(CallApp)
        case ended(CallApp)
    }

    /// Apps that are in a call, i.e. have been reported as started and not yet as ended.
    public private(set) var activeCalls: Set<CallApp> = []

    /// The apps that count as calls.
    public var apps: [CallApp] {
        didSet {
            guard apps != oldValue, let handle else { return }
            update(recordingApps: callApps(in: clients), handle: handle)
        }
    }

    private let monitor: any AudioInputActivityMonitoring
    private let ownProcessID: Int32
    private let startDelay: Duration
    private let endDelay: Duration

    /// The latest list of processes using an input or playing audio.
    private var clients: [AudioInputClient] = []
    /// Apps in a call, or starting one, in the latest list: using an input, or in a call already
    /// and playing audio from a process that recorded during it.
    private var recordingApps: Set<CallApp> = []
    /// The processes of each app that recorded since its call started, or since it started using
    /// an input if it's not in one yet.
    private var callProcessIDs: [CallApp: Set<Int32>] = [:]
    /// What `run` was given, while it runs.
    private var handle: (@MainActor (Event) -> Void)?
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
        self.handle = handle
        for await clients in monitor.inputClients() {
            self.clients = clients
            update(recordingApps: callApps(in: clients), handle: handle)
        }
        for task in pending.values { task.cancel() }
        pending = [:]
        self.handle = nil
        clients = []
        recordingApps = []
        callProcessIDs = [:]
        activeCalls = []
    }

    /// The apps among `clients` that count as calls, other than Mixdown: those using an input, and
    /// those in a call playing audio from a process that recorded during it. Notes the processes
    /// that record in `callProcessIDs`.
    private func callApps(in clients: [AudioInputClient]) -> Set<CallApp> {
        var recording = Set<CallApp>()
        var playing: [CallApp: Set<Int32>] = [:]
        for client in clients where client.processID != ownProcessID {
            let bundleIDs = [client.bundleID, client.appBundleID].compactMap { $0 }
            guard let app = apps.first(where: { app in bundleIDs.contains { app.matches(bundleID: $0) } })
            else { continue }
            if client.isRunningInput {
                recording.insert(app)
                callProcessIDs[app, default: []].insert(client.processID)
            }
            if client.isRunningOutput {
                playing[app, default: []].insert(client.processID)
            }
        }
        // A muted call, whose app plays the others but doesn't record.
        let sustained = activeCalls.filter { app in
            !app.isBrowser && !recording.contains(app)
                && !(playing[app] ?? []).isDisjoint(with: callProcessIDs[app] ?? [])
        }
        // Processes of an app that's neither in a call nor starting one are forgotten, so a later
        // process with the same ID isn't taken for one that recorded.
        for app in callProcessIDs.keys where !recording.contains(app) && !activeCalls.contains(app) {
            callProcessIDs[app] = nil
        }
        return recording.union(sustained)
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
                    self.callProcessIDs[app] = nil
                    handle(.ended(app))
                }
            }
        }
    }
}
