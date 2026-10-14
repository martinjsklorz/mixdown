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
            let lastDevices = OSAllocatedUnfairLock(initialState: Self.currentDevices())
            let listener = HALPropertyListener(
                selectors: [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice]
            ) {
                let devices = CoreAudioDeviceProvider.currentDevices()
                // A single plug/unplug fires several notifications; only report real changes.
                let changed = lastDevices.withLock { last in
                    guard last != devices else { return false }
                    last = devices
                    return true
                }
                if changed {
                    continuation.yield(devices)
                }
            }
            listener.install()
            continuation.onTermination = { _ in
                listener.remove()
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
                // Private aggregates created by AVAudioEngine/CoreAudio aren't user-selectable.
                guard !name.hasPrefix("CADefaultDeviceAggregate") else { return nil }
                return AudioInputDevice(id: uid, name: name, kind: .microphone, isDefault: deviceID == defaultID)
            }
            .sorted { lhs, rhs in
                if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }

        return microphones + [.systemAudio]
    }
}
