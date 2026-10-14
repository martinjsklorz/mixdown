import CoreAudio
import Foundation
import MixdownCore
import os

let audioLogger = Logger(subsystem: "app.mixdown", category: "audio")

/// Thin wrappers around the CoreAudio HAL property API.
enum CoreAudioHAL {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func propertyAddress(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// Converts a non-zero `OSStatus` into `AudioCaptureError.deviceUnavailable`.
    static func check(_ status: OSStatus, _ action: String) throws {
        guard status == noErr else {
            throw AudioCaptureError.deviceUnavailable("Couldn't \(action) (OSStatus \(status))")
        }
    }

    /// Every audio device known to the HAL, inputs and outputs alike.
    static func allDeviceIDs() throws -> [AudioDeviceID] {
        var address = propertyAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size), "list audio devices")

        let stride = MemoryLayout<AudioDeviceID>.stride
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / stride)
        guard !ids.isEmpty else { return [] }
        try check(AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &ids), "list audio devices")
        // The list can shrink between the two calls if a device is unplugged.
        return Array(ids.prefix(Int(size) / stride))
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = propertyAddress(kAudioHardwarePropertyDefaultInputDevice)
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return deviceID
    }

    /// Whether the device has at least one input channel.
    static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = propertyAddress(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size)
        else { return false }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else { return false }

        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    static func uid(of deviceID: AudioDeviceID) -> String? {
        stringProperty(kAudioDevicePropertyDeviceUID, of: deviceID)
    }

    static func name(of deviceID: AudioDeviceID) -> String? {
        stringProperty(kAudioObjectPropertyName, of: deviceID)
    }

    /// Resolves a device UID to its current `AudioDeviceID`, or `nil` if it isn't connected.
    static func deviceID(forUID uid: String) throws -> AudioDeviceID? {
        try allDeviceIDs().first { self.uid(of: $0) == uid }
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, of objectID: AudioObjectID) -> String? {
        var address = propertyAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        // CFString properties are returned at +1; the caller owns the reference.
        return value.takeRetainedValue() as String
    }
}

/// Registers a block listener for HAL properties on the system object and removes it again.
/// `@unchecked Sendable`: the listener block is immutable and installation is guarded by a lock.
final class HALPropertyListener: @unchecked Sendable {
    private let selectors: [AudioObjectPropertySelector]
    private let queue = DispatchQueue(label: "app.mixdown.audio.hal-listener")
    // CoreAudio identifies listener blocks by identity, so the same block instance must be
    // passed to both add and remove.
    private let block: AudioObjectPropertyListenerBlock
    private let isInstalled = OSAllocatedUnfairLock(initialState: false)

    init(selectors: [AudioObjectPropertySelector], onChange: @escaping @Sendable () -> Void) {
        self.selectors = selectors
        self.block = { _, _ in onChange() }
    }

    func install() {
        isInstalled.withLockUnchecked { installed in
            guard !installed else { return }
            installed = true
            for selector in selectors {
                var address = CoreAudioHAL.propertyAddress(selector)
                let status = AudioObjectAddPropertyListenerBlock(CoreAudioHAL.systemObject, &address, queue, block)
                if status != noErr {
                    audioLogger.error("AudioObjectAddPropertyListenerBlock failed: \(status, privacy: .public)")
                }
            }
        }
    }

    func remove() {
        isInstalled.withLockUnchecked { installed in
            guard installed else { return }
            installed = false
            for selector in selectors {
                var address = CoreAudioHAL.propertyAddress(selector)
                let status = AudioObjectRemovePropertyListenerBlock(CoreAudioHAL.systemObject, &address, queue, block)
                if status != noErr {
                    audioLogger.error("AudioObjectRemovePropertyListenerBlock failed: \(status, privacy: .public)")
                }
            }
        }
    }

    deinit { remove() }
}
