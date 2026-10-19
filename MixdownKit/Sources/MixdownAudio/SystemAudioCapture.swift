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

    deinit {
        // Released without `stop()`: end the stream so its reader isn't left waiting. The tap
        // destroys itself when it's released along with `state`.
        state.withLockUnchecked { $0.continuation }?.finish()
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
            try tap.create(excluding: Self.ownProcessObjectID()) { [weak self] error in
                guard let self else { return }
                Task { await self.finish(throwing: error) }
            }
            try tap.start(on: sampleQueue) { [weak self] bufferList, time, format in
                self?.consume(bufferList, at: time, format: format)
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
        await finish(throwing: nil)
    }

    /// Destroys the tap and ends the stream, with `error` if the capture failed.
    private func finish(throwing error: (any Error)?) async {
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
        if let error {
            audioLogger.error("System audio capture failed: \(error.localizedDescription, privacy: .public)")
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
            audioLogger.info("System audio capture stopped")
        }
    }

    // MARK: - Samples

    private func consume(_ bufferList: UnsafePointer<AudioBufferList>, at time: AudioTimeStamp, format: AVAudioFormat) {
        // No copy needed: the resampler copies while downmixing, before the IO block returns.
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: bufferList, deallocator: nil),
            let chunk = resampler.process(buffer, hostTime: HostClock.captureTime(of: time, buffer: buffer))
        else { return }
        let continuation = state.withLockUnchecked { $0.continuation }
        continuation?.yield(chunk)
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

/// A global process tap, the private aggregate device it's read through, and listeners that
/// keep the format current and notice the audio service restarting, which destroys both. A tap
/// delivers no buffers on its own; it has to be part of an aggregate device with an IO proc.
///
/// `@unchecked Sendable`: `create`, `start` and `invalidate` are called one after another, never
/// concurrently; `format` is behind a lock because the listener and IO queues both use it.
private final class ProcessTap: @unchecked Sendable {
    typealias IOBlock = @Sendable (UnsafePointer<AudioBufferList>, AudioTimeStamp, AVAudioFormat) -> Void

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var listeners: [HALPropertyListener] = []
    /// The format of the aggregate device's input stream, the one the IO block reads.
    private let format = OSAllocatedUnfairLock<AVAudioFormat?>(uncheckedState: nil)

    deinit { invalidate() }

    /// Creates the tap and its aggregate device and starts following the device's format.
    /// - Parameter onFailure: Called, possibly more than once, when the tap stops working.
    func create(
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
        format.withLockUnchecked { $0 = initialFormat }

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

    /// Starts IO. macOS asks for the System Audio Recording permission the first time.
    func start(on queue: DispatchQueue, ioBlock: @escaping IOBlock) throws {
        // Holds the lock, not `self`, so `self` is never released on the IO queue.
        let format = format
        let block: AudioDeviceIOBlock = { _, inputData, inputTime, _, _ in
            guard let format = format.withLockUnchecked({ $0 }) else { return }
            CoreAudioHAL.withFirstInputStream(inputData, matching: format) { ioBlock($0, inputTime.pointee, format) }
        }
        try CoreAudioHAL.check(
            AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue, block),
            "read from the system audio device"
        )
        try CoreAudioHAL.check(AudioDeviceStart(aggregateID, ioProcID), "start the system audio device")
    }

    /// Stops IO and destroys whatever `create`/`start` set up. Safe after a partial setup.
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
        let changed = format.withLockUnchecked { format -> Bool in
            guard format != newFormat else { return false }
            format = newFormat
            return true
        }
        if changed {
            audioLogger.info("System audio switched to \(newFormat, privacy: .public)")
        }
    }
}
