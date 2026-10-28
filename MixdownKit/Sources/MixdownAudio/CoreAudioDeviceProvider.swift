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

        let microphones =
            deviceIDs
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
    private let refreshes = CoalescedRefresh()
    private let onChange: @Sendable ([AudioInputDevice]) -> Void
    private var systemListeners: [HALPropertyListener] = []
    private var deviceListeners: [AudioDeviceID: HALPropertyListener] = [:]
    private var lastDevices: [AudioInputDevice] = []
    private var isStopped = false

    init(onChange: @escaping @Sendable ([AudioInputDevice]) -> Void) {
        self.onChange = onChange
    }

    /// Reports the current device list, then every change. Listens before it reads the list, so
    /// a change in between isn't missed. Off the caller's thread, as the HAL calls can be slow.
    func start() {
        queue.async { [self] in
            systemListeners = [
                HALPropertyListener(
                    selectors: [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice]
                ) { [weak self] in
                    self?.scheduleRefresh()
                },
                HALPropertyListener(selectors: [kAudioHardwarePropertyServiceRestarted]) { [weak self] in
                    self?.scheduleRefresh(afterServiceRestart: true)
                },
            ]
            systemListeners.forEach { $0.install() }
            watchDevices()
            lastDevices = CoreAudioDeviceProvider.currentDevices()
            onChange(lastDevices)
        }
    }

    func stop() {
        queue.async { [self] in
            isStopped = true
            systemListeners.forEach { $0.remove() }
            systemListeners = []
            removeDeviceListeners()
        }
    }

    /// Listener blocks run on their own queues; the work happens on `queue`.
    /// - Parameter afterServiceRestart: The audio service restarted, so the devices' listeners
    ///   are gone and their IDs may now belong to other devices. Never folded into another
    ///   refresh, which wouldn't drop them.
    private func scheduleRefresh(afterServiceRestart: Bool = false) {
        guard !afterServiceRestart else {
            queue.async { [weak self] in self?.refresh(afterServiceRestart: true) }
            return
        }
        refreshes.schedule(on: queue) { [weak self] in self?.refresh(afterServiceRestart: false) }
    }

    private func refresh(afterServiceRestart: Bool) {
        guard !isStopped else { return }
        if afterServiceRestart {
            removeDeviceListeners()
        }
        watchDevices()
        let devices = CoreAudioDeviceProvider.currentDevices()
        // A single plug/unplug fires several notifications; only report real changes.
        guard devices != lastDevices else { return }
        lastDevices = devices
        onChange(devices)
    }

    private func removeDeviceListeners() {
        for listener in deviceListeners.values {
            listener.remove(logsFailures: false)
        }
        deviceListeners = [:]
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
        HALPropertyListener.sync(
            &deviceListeners,
            to: deviceIDs,
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
    }
}
