import CoreAudio
import Darwin
import Foundation
import MixdownCore
import os

/// Reports which processes record from an audio input, from the HAL's process objects
/// (`kAudioProcessPropertyIsRunningInput`). Mixdown's own process is among them while it records.
public final class CoreAudioInputActivityMonitor: AudioInputActivityMonitoring {
    public init() {}

    public func inputClients() -> AsyncStream<[AudioInputClient]> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let watcher = ProcessInputWatcher { continuation.yield($0) }
            watcher.start()
            continuation.onTermination = { _ in watcher.stop() }
        }
    }
}

/// Follows the HAL's process list and each process's input state.
///
/// Process objects don't always announce input starting or stopping, e.g. when an app's helper
/// that's already running joins a second call. So input devices starting or stopping trigger a
/// check too, and `pollInterval` catches whatever no notification announces.
///
/// `@unchecked Sendable`: mutable state is only touched on `queue`.
private final class ProcessInputWatcher: @unchecked Sendable {
    private static let pollInterval: DispatchTimeInterval = .seconds(2)

    private let queue = DispatchQueue(label: "app.mixdown.audio.process-input")
    private let onChange: @Sendable ([AudioInputClient]) -> Void
    private var systemListener: HALPropertyListener?
    /// One listener per process object, for `kAudioProcessPropertyIsRunningInput`.
    private var processListeners: [AudioObjectID: HALPropertyListener] = [:]
    /// One listener per input device, for `kAudioDevicePropertyDeviceIsRunningSomewhere`.
    private var deviceListeners: [AudioObjectID: HALPropertyListener] = [:]
    private var poll: (any DispatchSourceTimer)?
    private var lastClients: [AudioInputClient]?
    private var isStopped = false

    init(onChange: @escaping @Sendable ([AudioInputClient]) -> Void) {
        self.onChange = onChange
    }

    func start() {
        queue.async { [self] in
            systemListener = HALPropertyListener(
                selectors: [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDevices]
            ) { [weak self] in self?.scheduleRefresh("process or device list changed") }
            systemListener?.install()

            let poll = DispatchSource.makeTimerSource(queue: queue)
            poll.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)
            poll.setEventHandler { [weak self] in self?.refresh("poll") }
            poll.resume()
            self.poll = poll

            refresh("start")
        }
    }

    func stop() {
        queue.async { [self] in
            isStopped = true
            poll?.cancel()
            poll = nil
            systemListener?.remove()
            systemListener = nil
            for listener in processListeners.values { listener.remove() }
            for listener in deviceListeners.values { listener.remove() }
            processListeners = [:]
            deviceListeners = [:]
        }
    }

    private func scheduleRefresh(_ reason: String) {
        queue.async { [weak self] in self?.refresh(reason) }
    }

    /// Re-reads every process, keeps the listeners in step with the processes and input devices,
    /// and reports the processes running input if that changed.
    private func refresh(_ reason: String) {
        guard !isStopped else { return }
        let processes: [AudioObjectID]
        let inputDevices: [AudioObjectID]
        do {
            processes = try CoreAudioHAL.allProcessObjectIDs()
            inputDevices = try CoreAudioHAL.allDeviceIDs().filter(CoreAudioHAL.hasInputStreams)
        } catch {
            audioLogger.error("\(error.localizedDescription, privacy: .public)")
            return
        }
        HALPropertyListener.sync(&processListeners, to: processes, selectors: [kAudioProcessPropertyIsRunningInput]) {
            [weak self] in self?.scheduleRefresh("process input changed")
        }
        HALPropertyListener.sync(
            &deviceListeners,
            to: inputDevices,
            selectors: [kAudioDevicePropertyDeviceIsRunningSomewhere]
        ) { [weak self] in self?.scheduleRefresh("input device started or stopped") }

        let clients = processes.compactMap { objectID -> AudioInputClient? in
            guard CoreAudioHAL.boolProperty(kAudioProcessPropertyIsRunningInput, of: objectID),
                let pid = CoreAudioHAL.processID(of: objectID)
            else { return nil }
            return AudioInputClient(
                processID: pid,
                bundleID: Self.bundleID(of: objectID),
                appBundleID: Self.containingAppBundleID(of: pid)
            )
        }
        // Several notifications arrive per change, and polls mostly find none; only report real ones.
        guard clients != lastClients else { return }
        lastClients = clients
        let described = clients.map { client in
            // Without a bundle ID, the executable is all there is to tell the process by.
            let name = client.bundleID ?? Self.executablePath(of: client.processID) ?? "-"
            return "\(client.processID) \(name) in \(client.appBundleID ?? "-")"
        }
        audioLogger.info(
            "\(processes.count, privacy: .public) audio processes; using an input: \(described.joined(separator: ", "), privacy: .public) (found by: \(reason, privacy: .public))"
        )
        onChange(clients)
    }

    // MARK: - Process details

    /// The bundle ID of the outermost app the process's executable lives in, e.g. `Webex.app` for
    /// `/Applications/Webex.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper`. `nil` if
    /// it isn't inside an app or the path can't be read.
    private static func containingAppBundleID(of pid: Int32) -> String? {
        guard let path = executablePath(of: pid), let range = path.range(of: ".app/") else { return nil }
        let appURL = URL(filePath: String(path[..<range.lowerBound]) + ".app", directoryHint: .isDirectory)
        return Bundle(url: appURL)?.bundleIdentifier
    }

    private static func executablePath(of pid: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    private static func bundleID(of objectID: AudioObjectID) -> String? {
        guard let bundleID = CoreAudioHAL.stringProperty(kAudioProcessPropertyBundleID, of: objectID),
            !bundleID.isEmpty
        else { return nil }
        return bundleID
    }
}
