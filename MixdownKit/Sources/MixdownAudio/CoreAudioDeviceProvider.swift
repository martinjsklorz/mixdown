import CoreAudio
import Foundation
import MixdownCore
import os

/// Lists CoreAudio input devices (plus the system-audio pseudo device) and watches for changes.
public final class CoreAudioDeviceProvider: AudioDeviceProvider {
    public init() {}

    public func availableDevices() async -> [AudioInputDevice] {
        Self.currentDevices()
    }

    public func deviceUpdates() -> AsyncStream<[AudioInputDevice]> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let watcher = DeviceListWatcher { continuation.yield($0) }
            watcher.start()
            continuation.onTermination = { _ in
                watcher.stop()
            }
        }
    }

    static func currentDevices() -> [AudioInputDevice] {
        let deviceIDs: [AudioDeviceID]
        do {
            deviceIDs = try CoreAudioHAL.allDeviceIDs()
        } catch {
            audioLogger.error("\(error.localizedDescription, privacy: .public)")
            deviceIDs = []
        }
        let defaultID = CoreAudioHAL.defaultInputDeviceID()

        let microphones = deviceIDs
            .compactMap { deviceID -> AudioInputDevice? in
                guard CoreAudioHAL.hasInputStreams(deviceID),
                      let uid = CoreAudioHAL.uid(of: deviceID)
                else { return nil }
                let name = CoreAudioHAL.name(of: deviceID) ?? uid
                // Private aggregates only exist for the process that created them and aren't
                // user-selectable: Mixdown's own system-audio device while it records, and those
                // AVAudioEngine/CoreAudio create, which are also caught by name in case they
                // aren't marked private.
                guard !CoreAudioHAL.isPrivateAggregate(deviceID),
                      !name.hasPrefix("CADefaultDeviceAggregate")
                else { return nil }
                return AudioInputDevice(id: uid, name: name, kind: .microphone, isDefault: deviceID == defaultID)
            }
            .sorted { lhs, rhs in
                if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }

        return microphones + [.systemAudio]
    }
}

/// Reports the device list whenever it changes.
///
/// Watching the system's device list isn't enough: a Bluetooth headset such as AirPods can join
/// it before its microphone is published, and is skipped as output-only at that point. So every
/// device is watched too, for its streams, name and whether it's alive.
///
/// `@unchecked Sendable`: all state is only touched on `queue`.
private final class DeviceListWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.mixdown.audio.device-list")
    private let onChange: @Sendable ([AudioInputDevice]) -> Void
    private var systemListener: HALPropertyListener?
    private var deviceListeners: [AudioDeviceID: HALPropertyListener] = [:]
    private var lastDevices: [AudioInputDevice] = []
    private var isStopped = false

    init(onChange: @escaping @Sendable ([AudioInputDevice]) -> Void) {
        self.onChange = onChange
    }

    /// Waits for the first device list, so changes from then on are reported.
    func start() {
        queue.sync { [self] in
            lastDevices = CoreAudioDeviceProvider.currentDevices()
            let listener = HALPropertyListener(
                selectors: [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice]
            ) { [weak self] in
                self?.scheduleRefresh()
            }
            listener.install()
            systemListener = listener
            watchDevices()
        }
    }

    func stop() {
        queue.async { [self] in
            isStopped = true
            systemListener?.remove()
            systemListener = nil
            for listener in deviceListeners.values {
                listener.remove(logsFailures: false)
            }
            deviceListeners = [:]
        }
    }

    /// Listener blocks run on their own queues; the work happens on `queue`.
    private func scheduleRefresh() {
        queue.async { [weak self] in self?.refresh() }
    }

    private func refresh() {
        guard !isStopped else { return }
        watchDevices()
        let devices = CoreAudioDeviceProvider.currentDevices()
        // A single plug/unplug fires several notifications; only report real changes.
        guard devices != lastDevices else { return }
        lastDevices = devices
        onChange(devices)
    }

    /// Listens to every device the HAL knows, and stops listening to those that are gone.
    private func watchDevices() {
        let deviceIDs: Set<AudioDeviceID>
        do {
            deviceIDs = Set(try CoreAudioHAL.allDeviceIDs())
        } catch {
            audioLogger.error("\(error.localizedDescription, privacy: .public)")
            return
        }
        for (deviceID, listener) in deviceListeners where !deviceIDs.contains(deviceID) {
            listener.remove(logsFailures: false)
            deviceListeners[deviceID] = nil
        }
        for deviceID in deviceIDs where deviceListeners[deviceID] == nil {
            let listener = HALPropertyListener(
                objectID: deviceID,
                selectors: [
                    kAudioDevicePropertyStreams,
                    kAudioDevicePropertyStreamConfiguration,
                    kAudioObjectPropertyName,
                    kAudioDevicePropertyDeviceIsAlive,
                ],
                scope: kAudioObjectPropertyScopeWildcard
            ) { [weak self] in
                self?.scheduleRefresh()
            }
            listener.install()
            deviceListeners[deviceID] = listener
        }
    }
}
