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
                onDisconnect: { [weak self, name = device.name] in
                    guard let self else { return }
                    Task { await self.finish(throwing: AudioCaptureError.deviceNotFound(name)) }
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

/// An IO proc on one input device, plus a listener that keeps its format current and notices
/// when the device goes away.
///
/// `@unchecked Sendable`: `start` and `invalidate` are called one after another, never
/// concurrently; `format` is behind a lock because the listener and IO queues both use it.
private final class DeviceInput: @unchecked Sendable {
    typealias IOBlock = @Sendable (UnsafePointer<AudioBufferList>, AudioTimeStamp, AVAudioFormat) -> Void

    private let name: String
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var listener: HALPropertyListener?
    /// The format of the device's first input stream, the one the IO block reads.
    private let format = OSAllocatedUnfairLock<AVAudioFormat?>(uncheckedState: nil)

    init(name: String) {
        self.name = name
    }

    func start(
        uid: String,
        on queue: DispatchQueue,
        onDisconnect: @escaping @Sendable () -> Void,
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

        let listener = HALPropertyListener(
            objectID: deviceID,
            selectors: [
                kAudioDevicePropertyDeviceIsAlive,
                kAudioDevicePropertyNominalSampleRate,
                kAudioDevicePropertyStreams,
                kAudioDevicePropertyStreamConfiguration,
            ],
            scope: kAudioObjectPropertyScopeWildcard
        ) { [weak self] in
            self?.deviceChanged(deviceID, onDisconnect: onDisconnect)
        }
        listener.install()
        self.listener = listener

        let block: AudioDeviceIOBlock = { [weak self] _, inputData, inputTime, _, _ in
            guard let self, let format = self.format.withLockUnchecked({ $0 }) else { return }
            self.deliver(inputData, at: inputTime.pointee, format: format, to: ioBlock)
        }
        try CoreAudioHAL.check(
            AudioDeviceCreateIOProcIDWithBlock(&ioProcID, deviceID, queue, block),
            "read from “\(name)”"
        )
        try CoreAudioHAL.check(AudioDeviceStart(deviceID, ioProcID), "start “\(name)”")
    }

    /// Stops IO and removes whatever `start` set up. Safe after a partial setup.
    func invalidate() {
        listener?.remove()
        listener = nil
        if deviceID != AudioObjectID(kAudioObjectUnknown), let ioProcID {
            logFailure(AudioDeviceStop(deviceID, ioProcID), "AudioDeviceStop")
            logFailure(AudioDeviceDestroyIOProcID(deviceID, ioProcID), "AudioDeviceDestroyIOProcID")
        }
        ioProcID = nil
        deviceID = AudioObjectID(kAudioObjectUnknown)
    }

    /// Hands the first input stream's buffer to `ioBlock`. A device with several input streams
    /// (some audio interfaces) delivers one buffer per stream; the first is the main input.
    private func deliver(
        _ inputData: UnsafePointer<AudioBufferList>,
        at time: AudioTimeStamp,
        format: AVAudioFormat,
        to ioBlock: IOBlock
    ) {
        guard inputData.pointee.mNumberBuffers > 0 else { return }
        var firstStream = AudioBufferList(mNumberBuffers: 1, mBuffers: inputData.pointee.mBuffers)
        // Right after a format change the IO proc can run before the listener has caught up.
        guard firstStream.mBuffers.mNumberChannels == format.channelCount else { return }
        withUnsafePointer(to: &firstStream) { ioBlock($0, time, format) }
    }

    /// A Bluetooth headset changes sample rate and streams when its microphone opens, and an
    /// unplugged device stops being alive.
    private func deviceChanged(_ deviceID: AudioDeviceID, onDisconnect: @escaping @Sendable () -> Void) {
        guard CoreAudioHAL.isAlive(deviceID) else {
            onDisconnect()
            return
        }
        guard let newFormat = CoreAudioHAL.inputFormat(of: deviceID) else { return }
        let changed = format.withLockUnchecked { format -> Bool in
            guard format != newFormat else { return false }
            format = newFormat
            return true
        }
        if changed {
            audioLogger.info("“\(self.name, privacy: .public)” switched to \(newFormat, privacy: .public)")
        }
    }

    private func logFailure(_ status: OSStatus, _ call: String) {
        guard status != noErr else { return }
        audioLogger.error("\(call, privacy: .public) failed: \(status, privacy: .public)")
    }
}
