@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import MixdownCore
import os

/// Everything the Mac plays back, excluding Mixdown's own audio, recorded through a global Core
/// Audio process tap and the private aggregate device it's read through, plus listeners that
/// keep the format current and notice the audio service restarting, which destroys both. A tap
/// delivers no buffers on its own; it has to be part of an aggregate device with an IO proc.
///
/// Needs only the "System Audio Recording Only" permission, not Screen Recording. macOS has no
/// public API to check it and prompts when the tap first starts. If the user declines, the tap
/// still runs but delivers silence, so a denial can't be reported as an error.
///
/// `@unchecked Sendable`: `start` and `invalidate` are called one after another, never
/// concurrently; `formats` is safe from the listener and IO threads.
final class SystemAudioTap: CaptureSource, @unchecked Sendable {
    let formats = FormatHistory()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var listeners: [HALPropertyListener] = []

    deinit { invalidate() }

    var logName: String { "System audio capture" }

    /// Creates the tap and its aggregate device, starts following the device's format and starts
    /// IO. macOS asks for the System Audio Recording permission the first time.
    func start(into ring: CaptureRing, onFailure: @escaping @Sendable (AudioCaptureError) -> Void) throws {
        try create(excluding: Self.ownProcessObjectID(), onFailure: onFailure)

        // No queue: the block runs right on the IO thread, which it never blocks.
        let block = IOProcCapture.ioBlock(writingTo: ring, formats: formats)
        try CoreAudioHAL.check(
            AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil, block),
            "read from the system audio device"
        )
        try CoreAudioHAL.check(AudioDeviceStart(aggregateID, ioProcID), "start the system audio device")
    }

    /// Creates the tap and its aggregate device and starts following the device's format.
    private func create(
        excluding ownProcess: AudioObjectID?,
        onFailure: @escaping @Sendable (AudioCaptureError) -> Void
    ) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: ownProcess.map { [$0] } ?? [])
        description.name = "Mixdown System Audio"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try CoreAudioHAL.check(AudioHardwareCreateProcessTap(description, &tapID), "create the system audio tap")

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Mixdown System Audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            // No sub-devices: the tap is the only source and clocks the device, so switching
            // the output device doesn't affect the capture.
            kAudioAggregateDeviceSubDeviceListKey: [[String: Any]](),
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]
                    as [String: Any]
            ],
        ]
        try CoreAudioHAL.check(
            AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID),
            "create the system audio device"
        )

        guard let initialFormat = Self.currentFormat(aggregateID: aggregateID, tapID: tapID) else {
            throw AudioCaptureError.deviceUnavailable("The system audio format isn't supported")
        }
        formats.update(initialFormat)

        // The tap follows the output device, so connecting AirPods, which switch to a lower
        // sample rate for calls, can change its format mid-recording. The IDs are captured by
        // value because the listener runs on its own queue and `invalidate` resets them.
        let onChange: @Sendable () -> Void = { [weak self, aggregateID = self.aggregateID, tapID = self.tapID] in
            self?.formatChanged(aggregateID: aggregateID, tapID: tapID)
        }
        listeners = [
            HALPropertyListener(
                objectID: aggregateID,
                selectors: [
                    kAudioDevicePropertyNominalSampleRate,
                    kAudioDevicePropertyStreams,
                    kAudioDevicePropertyStreamConfiguration,
                ],
                scope: kAudioObjectPropertyScopeWildcard,
                onChange: onChange
            ),
            HALPropertyListener(objectID: tapID, selectors: [kAudioTapPropertyFormat], onChange: onChange),
            HALPropertyListener(selectors: [kAudioHardwarePropertyServiceRestarted]) {
                onFailure(.audioServiceRestarted)
            },
        ]
        listeners.forEach { $0.install() }
    }

    /// Stops IO and destroys whatever `start` set up. Safe after a partial setup.
    func invalidate() {
        listeners.forEach { $0.remove(logsFailures: false) }
        listeners = []
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            if let ioProcID {
                CoreAudioHAL.logFailure(AudioDeviceStop(aggregateID, ioProcID), "AudioDeviceStop")
                CoreAudioHAL.logFailure(AudioDeviceDestroyIOProcID(aggregateID, ioProcID), "AudioDeviceDestroyIOProcID")
            }
            CoreAudioHAL.logFailure(
                AudioHardwareDestroyAggregateDevice(aggregateID),
                "AudioHardwareDestroyAggregateDevice"
            )
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            CoreAudioHAL.logFailure(AudioHardwareDestroyProcessTap(tapID), "AudioHardwareDestroyProcessTap")
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// The format the IO proc receives: the aggregate device's input stream, which is what the
    /// buffers actually arrive in. Falls back to the tap's own format if the device's streams
    /// can't be read.
    private static func currentFormat(aggregateID: AudioObjectID, tapID: AudioObjectID) -> AVAudioFormat? {
        if let format = CoreAudioHAL.inputFormat(of: aggregateID) { return format }
        var address = CoreAudioHAL.propertyAddress(kAudioTapPropertyFormat)
        var streamDescription = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &streamDescription) == noErr,
            let format = AVAudioFormat(streamDescription: &streamDescription)
        else { return nil }
        audioLogger.warning("System audio device format unreadable, using the tap's \(format, privacy: .public)")
        return format
    }

    private func formatChanged(aggregateID: AudioObjectID, tapID: AudioObjectID) {
        guard let newFormat = Self.currentFormat(aggregateID: aggregateID, tapID: tapID) else { return }
        if formats.update(newFormat) {
            audioLogger.info("System audio switched to \(newFormat, privacy: .public)")
        }
    }

    /// Mixdown's own HAL process object, or `nil` if it has none yet (it hasn't touched audio).
    private static func ownProcessObjectID() -> AudioObjectID? {
        var address = CoreAudioHAL.propertyAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = ProcessInfo.processInfo.processIdentifier
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            CoreAudioHAL.systemObject,
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pid,
            &size,
            &objectID
        )
        guard status == noErr, objectID != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return objectID
    }
}
