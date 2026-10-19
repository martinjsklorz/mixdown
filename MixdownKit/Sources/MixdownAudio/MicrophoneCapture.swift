@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import MixdownCore
import os

/// Captures a specific Core Audio input device through an IO proc on the device itself.
///
/// Not `AVAudioEngine`: pointing the engine's input unit at a Bluetooth headset such as AirPods
/// left it running without delivering any audio, while the built-in microphone worked. Opening
/// the headset's input switches it to its call profile at a lower sample rate, and the engine
/// most likely kept the format from before the switch. An IO proc follows the device's format.
///
/// `@unchecked Sendable`: mutable state lives behind `state`; `resampler` is only touched on
/// `sampleQueue`, where the device's IO block runs.
final class MicrophoneCapture: AudioCapturing, @unchecked Sendable {
    private typealias Continuation = AsyncThrowingStream<AudioChunk, any Error>.Continuation

    private enum Phase { case idle, starting, running, stopped }

    private struct State {
        var phase: Phase = .idle
        var input: DeviceInput?
        var continuation: Continuation?
    }

    private let device: AudioInputDevice
    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let sampleQueue = DispatchQueue(label: "app.mixdown.audio.microphone", qos: .userInitiated)
    private let resampler: AudioResampler

    init(device: AudioInputDevice) throws {
        self.device = device
        resampler = try AudioResampler()
    }

    deinit {
        // Released without `stop()`: end the stream so its reader isn't left waiting. The device
        // input stops itself when it's released along with `state`.
        state.withLockUnchecked { $0.continuation }?.finish()
    }

    func start() async throws -> AsyncThrowingStream<AudioChunk, any Error> {
        let (stream, continuation) = AsyncThrowingStream<AudioChunk, any Error>.makeStream()
        try state.withLockUnchecked { state in
            guard state.phase == .idle else { throw AudioCaptureError.alreadyRunning }
            state.phase = .starting
            state.continuation = continuation
        }

        let input = DeviceInput(name: device.name)
        do {
            try await Self.ensurePermission()
            // stop() may have run while the permission prompt was showing.
            guard state.withLockUnchecked({ $0.phase == .starting }) else { return stream }
            try input.start(
                uid: device.id,
                on: sampleQueue,
                onFailure: { [weak self] error in
                    guard let self else { return }
                    Task { await self.finish(throwing: error) }
                },
                ioBlock: { [weak self] bufferList, time, format in
                    self?.consume(bufferList, at: time, format: format)
                }
            )
        } catch {
            input.invalidate()
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
            state.input = input
            return true
        }
        guard isStillStarting else {
            // stop() ran while the device was starting; it already finished the continuation.
            input.invalidate()
            return stream
        }

        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.stop() }
        }
        audioLogger.info("Microphone capture started on \(self.device.name, privacy: .public)")
        return stream
    }

    func stop() async {
        await finish(throwing: nil)
    }

    /// Stops the device and ends the stream, with `error` if the capture failed.
    private func finish(throwing error: (any Error)?) async {
        let (input, continuation) = state.withLockUnchecked { state -> (DeviceInput?, Continuation?) in
            guard state.phase != .stopped else { return (nil, nil) }
            state.phase = .stopped
            defer {
                state.input = nil
                state.continuation = nil
            }
            return (state.input, state.continuation)
        }
        guard let continuation else { return }

        input?.invalidate()
        // Let buffers already queued on the sample queue go out before finishing the stream.
        let sampleQueue = sampleQueue
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            sampleQueue.async { done.resume() }
        }
        if let error {
            audioLogger.error("Microphone capture failed: \(error.localizedDescription, privacy: .public)")
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
            audioLogger.info("Microphone capture stopped")
        }
    }

    private static func ensurePermission() async throws {
        switch AudioPermissions.microphoneStatus() {
        case .granted:
            return
        case .denied:
            throw AudioCaptureError.microphonePermissionDenied
        case .notDetermined:
            guard await AudioPermissions.requestMicrophoneAccess() else {
                throw AudioCaptureError.microphonePermissionDenied
            }
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
}

/// An IO proc on one input device, plus listeners that keep its format current and notice when
/// the device goes away or stops being an input, or the audio service restarts.
///
/// `@unchecked Sendable`: `start` and `invalidate` are called one after another, never
/// concurrently; `format` is behind a lock because the listener and IO queues both use it.
private final class DeviceInput: @unchecked Sendable {
    typealias IOBlock = @Sendable (UnsafePointer<AudioBufferList>, AudioTimeStamp, AVAudioFormat) -> Void
    typealias FailureHandler = @Sendable (AudioCaptureError) -> Void

    /// How long a device may be without input streams before it counts as gone. A Bluetooth
    /// headset can drop them for a moment while it switches profiles.
    private static let lostInputGracePeriod: DispatchTimeInterval = .seconds(1)

    private let name: String
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var listeners: [HALPropertyListener] = []
    /// The format of the device's first input stream, the one the IO block reads.
    private let format = OSAllocatedUnfairLock<AVAudioFormat?>(uncheckedState: nil)

    init(name: String) {
        self.name = name
    }

    deinit { invalidate() }

    /// - Parameter onFailure: Called, possibly more than once, when the device can't be recorded
    ///   from anymore.
    func start(
        uid: String,
        on queue: DispatchQueue,
        onFailure: @escaping FailureHandler,
        ioBlock: @escaping IOBlock
    ) throws {
        guard let deviceID = try CoreAudioHAL.deviceID(forUID: uid) else {
            throw AudioCaptureError.deviceNotFound(name)
        }
        self.deviceID = deviceID

        guard let initialFormat = CoreAudioHAL.inputFormat(of: deviceID) else {
            throw AudioCaptureError.deviceUnavailable("“\(name)” has no usable input channels")
        }
        format.withLockUnchecked { $0 = initialFormat }

        listeners = [
            HALPropertyListener(
                objectID: deviceID,
                selectors: [
                    kAudioDevicePropertyDeviceIsAlive,
                    kAudioDevicePropertyNominalSampleRate,
                    kAudioDevicePropertyStreams,
                    kAudioDevicePropertyStreamConfiguration,
                ],
                scope: kAudioObjectPropertyScopeWildcard
            ) { [weak self] in
                self?.deviceChanged(deviceID, onFailure: onFailure)
            },
            // The IO proc dies with the service, without a word from the device.
            HALPropertyListener(selectors: [kAudioHardwarePropertyServiceRestarted]) {
                onFailure(.audioServiceRestarted)
            },
        ]
        listeners.forEach { $0.install() }

        // Holds the lock, not `self`, so `self` is never released on the IO queue.
        let format = format
        let block: AudioDeviceIOBlock = { _, inputData, inputTime, _, _ in
            guard let format = format.withLockUnchecked({ $0 }) else { return }
            CoreAudioHAL.withFirstInputStream(inputData, matching: format) { ioBlock($0, inputTime.pointee, format) }
        }
        try CoreAudioHAL.check(
            AudioDeviceCreateIOProcIDWithBlock(&ioProcID, deviceID, queue, block),
            "read from “\(name)”"
        )
        try CoreAudioHAL.check(AudioDeviceStart(deviceID, ioProcID), "start “\(name)”")
    }

    /// Stops IO and removes whatever `start` set up. Safe after a partial setup.
    func invalidate() {
        listeners.forEach { $0.remove(logsFailures: false) }
        listeners = []
        if deviceID != AudioObjectID(kAudioObjectUnknown), let ioProcID {
            CoreAudioHAL.logFailure(AudioDeviceStop(deviceID, ioProcID), "AudioDeviceStop")
            CoreAudioHAL.logFailure(AudioDeviceDestroyIOProcID(deviceID, ioProcID), "AudioDeviceDestroyIOProcID")
        }
        ioProcID = nil
        deviceID = AudioObjectID(kAudioObjectUnknown)
    }

    /// A Bluetooth headset changes sample rate and streams when its microphone opens, an
    /// unplugged device stops being alive, and a device can lose its input streams while staying
    /// connected, which leaves the IO proc running without audio.
    private func deviceChanged(_ deviceID: AudioDeviceID, onFailure: @escaping FailureHandler) {
        guard CoreAudioHAL.isAlive(deviceID) else {
            onFailure(.deviceNotFound(name))
            return
        }
        guard let newFormat = CoreAudioHAL.inputFormat(of: deviceID) else {
            let deadline = DispatchTime.now() + Self.lostInputGracePeriod
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: deadline) { [weak self, name] in
                // Once stopped, it's released, and the stream has ended anyway.
                guard self != nil, CoreAudioHAL.inputFormat(of: deviceID) == nil else { return }
                audioLogger.error("“\(name, privacy: .public)” has no input streams anymore")
                onFailure(.deviceNotFound(name))
            }
            return
        }
        let changed = format.withLockUnchecked { format -> Bool in
            guard format != newFormat else { return false }
            format = newFormat
            return true
        }
        if changed {
            audioLogger.info("“\(self.name, privacy: .public)” switched to \(newFormat, privacy: .public)")
        }
    }
}
