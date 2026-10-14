@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import MixdownCore
import os

/// Captures everything the Mac plays back through a Core Audio process tap, excluding Mixdown's
/// own audio. Needs only the "System Audio Recording Only" permission, not Screen Recording.
///
/// macOS has no public API to check that permission and prompts when the tap first starts. If the
/// user declines, the tap still runs but delivers silence, so a denial can't be reported as an
/// error.
///
/// `@unchecked Sendable`: mutable state lives behind `state`; `resampler` is only touched on
/// `sampleQueue`, where the tap's IO block runs.
final class SystemAudioCapture: AudioCapturing, @unchecked Sendable {
    private typealias Continuation = AsyncThrowingStream<AudioChunk, any Error>.Continuation

    private enum Phase { case idle, starting, running, stopped }

    private struct State {
        var phase: Phase = .idle
        var tap: ProcessTap?
        var continuation: Continuation?
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let sampleQueue = DispatchQueue(label: "app.mixdown.audio.system-audio", qos: .userInitiated)
    private let resampler: AudioResampler

    init() throws {
        resampler = try AudioResampler()
    }

    func start() async throws -> AsyncThrowingStream<AudioChunk, any Error> {
        let (stream, continuation) = AsyncThrowingStream<AudioChunk, any Error>.makeStream()
        try state.withLockUnchecked { state in
            guard state.phase == .idle else { throw AudioCaptureError.alreadyRunning }
            state.phase = .starting
            state.continuation = continuation
        }

        let tap = ProcessTap()
        do {
            let format = try tap.create(excluding: Self.ownProcessObjectID())
            try tap.start(on: sampleQueue) { [weak self] _, inputData, inputTime, _, _ in
                self?.consume(inputData, at: inputTime.pointee, format: format)
            }
        } catch {
            tap.invalidate()
            state.withLockUnchecked { state in
                state.phase = .stopped
                state.continuation = nil
            }
            continuation.finish(throwing: error)
            throw error
        }

        let isStillStarting = state.withLockUnchecked { state -> Bool in
            guard state.phase == .starting else { return false }
            state.phase = .running
            state.tap = tap
            return true
        }
        guard isStillStarting else {
            // stop() ran while the tap was starting; it already finished the continuation.
            tap.invalidate()
            return stream
        }

        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.stop() }
        }
        audioLogger.info("System audio capture started")
        return stream
    }

    func stop() async {
        let (tap, continuation) = state.withLockUnchecked { state -> (ProcessTap?, Continuation?) in
            guard state.phase != .stopped else { return (nil, nil) }
            state.phase = .stopped
            defer {
                state.tap = nil
                state.continuation = nil
            }
            return (state.tap, state.continuation)
        }
        guard let continuation else { return }

        tap?.invalidate()
        // Let buffers already queued on the sample queue go out before finishing the stream.
        let sampleQueue = sampleQueue
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            sampleQueue.async { done.resume() }
        }
        continuation.finish()
        audioLogger.info("System audio capture stopped")
    }

    // MARK: - Samples

    private func consume(_ bufferList: UnsafePointer<AudioBufferList>, at time: AudioTimeStamp, format: AVAudioFormat) {
        // No copy needed: the resampler copies while downmixing, before the IO block returns.
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: bufferList, deallocator: nil),
              let chunk = resampler.process(buffer, hostTime: Self.hostTime(of: time, buffer: buffer))
        else { return }
        let continuation = state.withLockUnchecked { $0.continuation }
        continuation?.yield(chunk)
    }

    /// The HAL stamps IO cycles on the host clock. A timestamp that's missing or far off "now"
    /// means that assumption broke, so fall back to the arrival time.
    private static func hostTime(of time: AudioTimeStamp, buffer: AVAudioPCMBuffer) -> TimeInterval {
        let arrival = HostClock.now() - Double(buffer.frameLength) / buffer.format.sampleRate
        guard time.mFlags.contains(.hostTimeValid) else { return arrival }
        let stamped = AVAudioTime.seconds(forHostTime: time.mHostTime)
        return abs(stamped - arrival) < 2 ? stamped : arrival
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

/// A global process tap and the private aggregate device it's read through. A tap delivers no
/// buffers on its own; it has to be part of an aggregate device with an IO proc.
///
/// `@unchecked Sendable`: `create`, `start` and `invalidate` are called one after another, never
/// concurrently.
private final class ProcessTap: @unchecked Sendable {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    /// Creates the tap and its aggregate device and returns the format of the tapped audio.
    func create(excluding ownProcess: AudioObjectID?) throws -> AVAudioFormat {
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
                    as [String: Any],
            ],
        ]
        try CoreAudioHAL.check(
            AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID),
            "create the system audio device"
        )

        var address = CoreAudioHAL.propertyAddress(kAudioTapPropertyFormat)
        var streamDescription = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try CoreAudioHAL.check(
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &streamDescription),
            "read the system audio format"
        )
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw AudioCaptureError.deviceUnavailable("The system audio format isn't supported")
        }
        return format
    }

    /// Starts IO. macOS asks for the System Audio Recording permission the first time.
    func start(on queue: DispatchQueue, ioBlock: @escaping AudioDeviceIOBlock) throws {
        try CoreAudioHAL.check(
            AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue, ioBlock),
            "read from the system audio device"
        )
        try CoreAudioHAL.check(AudioDeviceStart(aggregateID, ioProcID), "start the system audio device")
    }

    /// Stops IO and destroys whatever `create`/`start` set up. Safe after a partial setup.
    func invalidate() {
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            if let ioProcID {
                logFailure(AudioDeviceStop(aggregateID, ioProcID), "AudioDeviceStop")
                logFailure(AudioDeviceDestroyIOProcID(aggregateID, ioProcID), "AudioDeviceDestroyIOProcID")
            }
            logFailure(AudioHardwareDestroyAggregateDevice(aggregateID), "AudioHardwareDestroyAggregateDevice")
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            logFailure(AudioHardwareDestroyProcessTap(tapID), "AudioHardwareDestroyProcessTap")
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func logFailure(_ status: OSStatus, _ call: String) {
        guard status != noErr else { return }
        audioLogger.error("\(call, privacy: .public) failed: \(status, privacy: .public)")
    }
}
