@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import MixdownCore
import os

/// Captures a specific CoreAudio input device with `AVAudioEngine`.
actor MicrophoneCapture: AudioCapturing {
    private enum Phase { case idle, starting, running, stopped }

    private let device: AudioInputDevice
    private var phase: Phase = .idle
    private var engine: AVAudioEngine?
    private var sink: TapSink?
    private var isTapInstalled = false
    private var configurationObserver: (any NSObjectProtocol)?
    private var continuation: AsyncThrowingStream<AudioChunk, any Error>.Continuation?

    init(device: AudioInputDevice) {
        self.device = device
    }

    func start() async throws -> AsyncThrowingStream<AudioChunk, any Error> {
        guard phase == .idle else { throw AudioCaptureError.alreadyRunning }
        phase = .starting

        let (stream, continuation) = AsyncThrowingStream<AudioChunk, any Error>.makeStream()
        do {
            try await Self.ensurePermission()
            // stop() may have run while the permission prompt was showing.
            guard phase == .starting else {
                continuation.finish()
                return stream
            }
            try startEngine(continuation: continuation)
        } catch {
            teardown()
            phase = .stopped
            throw error
        }

        phase = .running
        self.continuation = continuation
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.stop() }
        }
        audioLogger.info("Microphone capture started on \(self.device.name, privacy: .public)")
        return stream
    }

    func stop() async {
        guard phase != .stopped else { return }
        phase = .stopped
        teardown()
        continuation?.finish()
        continuation = nil
        audioLogger.info("Microphone capture stopped")
    }

    // MARK: - Engine

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

    private func startEngine(continuation: AsyncThrowingStream<AudioChunk, any Error>.Continuation) throws {
        let engine = AVAudioEngine()
        let sink = try TapSink(continuation: continuation)
        self.engine = engine
        self.sink = sink

        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.handleConfigurationChange() }
        }

        try run(engine, sink: sink)
    }

    /// Points the engine's input unit at the device, installs the tap and starts the engine.
    private func run(_ engine: AVAudioEngine, sink: TapSink) throws {
        guard let deviceID = try CoreAudioHAL.deviceID(forUID: device.id) else {
            throw AudioCaptureError.deviceNotFound(device.name)
        }

        let input = engine.inputNode
        guard let audioUnit = input.audioUnit else {
            throw AudioCaptureError.deviceUnavailable("The audio engine has no input unit")
        }
        var currentDevice = deviceID
        try CoreAudioHAL.check(
            AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &currentDevice,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            ),
            "select “\(device.name)”"
        )

        let hardwareFormat = input.inputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw AudioCaptureError.deviceUnavailable("“\(device.name)” has no usable input channels")
        }

        // `format: nil` lets the engine use the input node's current output format, which avoids
        // format-mismatch exceptions after the device switch.
        input.installTap(onBus: 0, bufferSize: 4096, format: nil, block: Self.tapBlock(for: sink))
        isTapInstalled = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw AudioCaptureError.deviceUnavailable(error.localizedDescription)
        }
    }

    /// The engine stops itself when the hardware format changes or the device disappears.
    /// Restart on the same device, or end the session if it is gone.
    private func handleConfigurationChange() {
        guard phase == .running, let engine, let sink, !engine.isRunning else { return }
        audioLogger.info("Audio engine configuration changed; restarting microphone capture")

        removeTap()
        do {
            try run(engine, sink: sink)
        } catch {
            audioLogger.error("Microphone capture failed: \(error.localizedDescription, privacy: .public)")
            fail(with: error)
        }
    }

    private func fail(with error: any Error) {
        guard phase != .stopped else { return }
        phase = .stopped
        teardown()
        continuation?.finish(throwing: error)
        continuation = nil
    }

    private func teardown() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        removeTap()
        engine?.stop()
        engine = nil
        sink = nil
    }

    private func removeTap() {
        guard isTapInstalled, let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        isTapInstalled = false
    }

    /// Built outside actor isolation: the tap runs on an AVAudioEngine thread, not on the actor.
    private static func tapBlock(for sink: TapSink) -> AVAudioNodeTapBlock {
        { buffer, _ in sink.consume(buffer) }
    }
}

/// Receives tap buffers and forwards converted chunks.
/// `@unchecked Sendable`: AVAudioEngine invokes a tap serially, so the resampler is never used
/// concurrently, and the continuation is thread-safe on its own.
private final class TapSink: @unchecked Sendable {
    private let resampler: AudioResampler
    private let continuation: AsyncThrowingStream<AudioChunk, any Error>.Continuation

    init(continuation: AsyncThrowingStream<AudioChunk, any Error>.Continuation) throws {
        self.resampler = try AudioResampler()
        self.continuation = continuation
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        guard let chunk = resampler.process(buffer) else { return }
        continuation.yield(chunk)
    }
}
