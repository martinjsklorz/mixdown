@preconcurrency import AVFoundation
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
        try objectIDs(kAudioHardwarePropertyDevices, "list audio devices")
    }

    /// Every process the HAL knows as an audio client, whether it plays, records or neither.
    static func allProcessObjectIDs() throws -> [AudioObjectID] {
        try objectIDs(kAudioHardwarePropertyProcessObjectList, "list audio processes")
    }

    /// A list of objects from the system object, e.g. its devices.
    private static func objectIDs(_ selector: AudioObjectPropertySelector, _ action: String) throws -> [AudioObjectID] {
        var address = propertyAddress(selector)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size), action)

        let stride = MemoryLayout<AudioObjectID>.stride
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / stride)
        guard !ids.isEmpty else { return [] }
        try check(AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &ids), action)
        // The list can shrink between the two calls if a device is unplugged or a process exits.
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

    /// Whether the device is an aggregate device that only its creating process can see, such as
    /// the one system audio is captured through.
    static func isPrivateAggregate(_ deviceID: AudioDeviceID) -> Bool {
        var address = propertyAddress(kAudioAggregateDevicePropertyComposition)
        var value: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        // Fails for anything that isn't an aggregate device.
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return false }
        // CFDictionary properties are returned at +1; the caller owns the reference.
        let composition = value.takeRetainedValue() as? [String: Any]
        return (composition?[kAudioAggregateDeviceIsPrivateKey] as? NSNumber)?.boolValue ?? false
    }

    /// Whether the device is still connected. A device ID outlives its device and reports `false`.
    static func isAlive(_ deviceID: AudioDeviceID) -> Bool {
        boolProperty(kAudioDevicePropertyDeviceIsAlive, of: deviceID)
    }

    /// The PID of a HAL process object, or `nil` if it can't be read (e.g. the process exited).
    static func processID(of objectID: AudioObjectID) -> pid_t? {
        var address = propertyAddress(kAudioProcessPropertyPID)
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &pid) == noErr else { return nil }
        return pid
    }

    /// The format IO procs receive from the device's first input stream, or `nil` if it has none.
    static func inputFormat(of deviceID: AudioDeviceID) -> AVAudioFormat? {
        var address = propertyAddress(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else { return nil }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.stride)
        guard !streams.isEmpty,
              AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &streams) == noErr
        else {
            audioLogger.error("Device \(deviceID, privacy: .public) has no input streams")
            return nil
        }

        var formatAddress = propertyAddress(kAudioStreamPropertyVirtualFormat)
        var description = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(streams[0], &formatAddress, 0, nil, &formatSize, &description)
        guard status == noErr, description.mSampleRate > 0, description.mChannelsPerFrame > 0 else {
            audioLogger.error(
                "Device \(deviceID, privacy: .public) input format unreadable (OSStatus \(status, privacy: .public)): \(description.mSampleRate, privacy: .public) Hz, \(description.mChannelsPerFrame, privacy: .public) channels"
            )
            return nil
        }
        if let format = AVAudioFormat(streamDescription: &description) { return format }

        // AVAudioFormat needs a channel layout for more than two channels, e.g. a microphone array
        // exposing each microphone. The resampler mixes any number of channels down, so their
        // order doesn't matter.
        let discreteLayout = kAudioChannelLayoutTag_DiscreteInOrder | description.mChannelsPerFrame
        if let layout = AVAudioChannelLayout(layoutTag: discreteLayout),
           let format = AVAudioFormat(streamDescription: &description, channelLayout: layout) {
            return format
        }
        audioLogger.error(
            "Device \(deviceID, privacy: .public) input format unsupported: \(description.mSampleRate, privacy: .public) Hz, \(description.mChannelsPerFrame, privacy: .public) channels, format \(description.mFormatID, privacy: .public), flags \(description.mFormatFlags, privacy: .public), \(description.mBitsPerChannel, privacy: .public) bits"
        )
        return nil
    }

    /// Calls `body` with only the first stream of an IO proc's input, if its channel count matches
    /// `format`. A device with several input streams (some audio interfaces) delivers one buffer
    /// per stream; the first is the main input. Right after a format change the IO proc can run
    /// before the format listener has caught up, so a mismatched buffer is dropped.
    static func withFirstInputStream(
        _ inputData: UnsafePointer<AudioBufferList>,
        matching format: AVAudioFormat,
        _ body: (UnsafePointer<AudioBufferList>) -> Void
    ) {
        guard inputData.pointee.mNumberBuffers > 0 else { return }
        var firstStream = AudioBufferList(mNumberBuffers: 1, mBuffers: inputData.pointee.mBuffers)
        guard firstStream.mBuffers.mNumberChannels == format.channelCount else { return }
        withUnsafePointer(to: &firstStream) { body($0) }
    }

    /// Resolves a device UID to its current `AudioDeviceID`, or `nil` if it isn't connected.
    static func deviceID(forUID uid: String) throws -> AudioDeviceID? {
        try allDeviceIDs().first { self.uid(of: $0) == uid }
    }

    /// A `UInt32` flag property; `false` if it's zero or can't be read.
    static func boolProperty(_ selector: AudioObjectPropertySelector, of objectID: AudioObjectID) -> Bool {
        var address = propertyAddress(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        return status == noErr && value != 0
    }

    static func stringProperty(_ selector: AudioObjectPropertySelector, of objectID: AudioObjectID) -> String? {
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

    /// Logs a failed teardown call, which there's nothing else to do about.
    static func logFailure(_ status: OSStatus, _ call: String) {
        guard status != noErr else { return }
        audioLogger.error("\(call, privacy: .public) failed: \(status, privacy: .public)")
    }
}

/// Registers a block listener for HAL properties on an object (the system object unless told
/// otherwise) and removes it again.
/// `@unchecked Sendable`: the listener block is immutable and installation is guarded by a lock.
final class HALPropertyListener: @unchecked Sendable {
    private let objectID: AudioObjectID
    private let selectors: [AudioObjectPropertySelector]
    private let scope: AudioObjectPropertyScope
    private let queue = DispatchQueue(label: "app.mixdown.audio.hal-listener")
    // CoreAudio identifies listener blocks by identity, so the same block instance must be
    // passed to both add and remove.
    private let block: AudioObjectPropertyListenerBlock
    private let isInstalled = OSAllocatedUnfairLock(initialState: false)

    init(
        objectID: AudioObjectID = CoreAudioHAL.systemObject,
        selectors: [AudioObjectPropertySelector],
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        onChange: @escaping @Sendable () -> Void
    ) {
        self.objectID = objectID
        self.selectors = selectors
        self.scope = scope
        self.block = { _, _ in onChange() }
    }

    func install() {
        isInstalled.withLockUnchecked { installed in
            guard !installed else { return }
            installed = true
            for selector in selectors {
                var address = CoreAudioHAL.propertyAddress(selector, scope: scope)
                let status = AudioObjectAddPropertyListenerBlock(objectID, &address, queue, block)
                if status != noErr {
                    audioLogger.error("AudioObjectAddPropertyListenerBlock failed: \(status, privacy: .public)")
                }
            }
        }
    }

    /// - Parameter logsFailures: Pass `false` when the object may be gone already, e.g. a process
    ///   that has exited, which makes removing fail.
    func remove(logsFailures: Bool = true) {
        isInstalled.withLockUnchecked { installed in
            guard installed else { return }
            installed = false
            for selector in selectors {
                var address = CoreAudioHAL.propertyAddress(selector, scope: scope)
                let status = AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, block)
                if status != noErr, logsFailures {
                    audioLogger.error("AudioObjectRemovePropertyListenerBlock failed: \(status, privacy: .public)")
                }
            }
        }
    }

    deinit { remove() }
}
