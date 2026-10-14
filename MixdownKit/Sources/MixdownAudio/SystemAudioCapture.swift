@preconcurrency import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import MixdownCore
import os
@preconcurrency import ScreenCaptureKit

/// Captures everything the Mac plays back via ScreenCaptureKit, excluding Mixdown's own audio.
///
/// `@unchecked Sendable` class rather than an actor: ScreenCaptureKit needs an `NSObject` for its
/// output/delegate callbacks. Mutable state lives behind `state`; `resampler` is only touched on
/// `sampleQueue`.
final class SystemAudioCapture: NSObject, AudioCapturing, @unchecked Sendable {
    private typealias Continuation = AsyncThrowingStream<AudioChunk, any Error>.Continuation

    private enum Phase { case idle, starting, running, stopped }

    private struct State {
        var phase: Phase = .idle
        var stream: SCStream?
        var continuation: Continuation?
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let sampleQueue = DispatchQueue(label: "app.mixdown.audio.system-audio", qos: .userInitiated)
    private let resampler: AudioResampler

    /// Takes the resampler as a parameter because a throwing `init()` would clash with
    /// `NSObject.init()`, which can't be overridden by a throwing initializer.
    init(resampler: AudioResampler) {
        self.resampler = resampler
        super.init()
    }

    func start() async throws -> AsyncThrowingStream<AudioChunk, any Error> {
        let (stream, continuation) = AsyncThrowingStream<AudioChunk, any Error>.makeStream()
        try state.withLockUnchecked { state in
            guard state.phase == .idle else { throw AudioCaptureError.alreadyRunning }
            state.phase = .starting
            state.continuation = continuation
        }

        let captureStream: SCStream
        do {
            captureStream = try await makeStream()
            try await captureStream.startCapture()
        } catch {
            let mapped = Self.captureError(from: error)
            state.withLockUnchecked { state in
                state.phase = .stopped
                state.continuation = nil
            }
            continuation.finish(throwing: mapped)
            throw mapped
        }

        let isStillStarting = state.withLockUnchecked { state -> Bool in
            guard state.phase == .starting else { return false }
            state.phase = .running
            state.stream = captureStream
            return true
        }
        guard isStillStarting else {
            // stop() ran while the stream was starting; it already finished the continuation.
            try? await captureStream.stopCapture()
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
        let (captureStream, continuation) = state.withLockUnchecked { state -> (SCStream?, Continuation?) in
            guard state.phase != .stopped else { return (nil, nil) }
            state.phase = .stopped
            defer {
                state.stream = nil
                state.continuation = nil
            }
            return (state.stream, state.continuation)
        }
        guard let continuation else { return }

        if let captureStream {
            do {
                try await captureStream.stopCapture()
            } catch {
                audioLogger.error("Stopping system audio failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        // Let buffers already queued on the sample queue go out before finishing the stream.
        let sampleQueue = sampleQueue
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            sampleQueue.async { done.resume() }
        }
        continuation.finish()
        audioLogger.info("System audio capture stopped")
    }

    // MARK: - Setup

    private func makeStream() async throws -> SCStream {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mainDisplayID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainDisplayID })
            ?? content.displays.first
        else {
            throw AudioCaptureError.deviceUnavailable("No display is available for system audio capture")
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == ownPID }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        // A display filter always produces video; keep it as cheap as possible. No screen output
        // is added, so frames are discarded.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3
        configuration.showsCursor = false

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        return stream
    }

    private static func captureError(from error: any Error) -> AudioCaptureError {
        if let error = error as? AudioCaptureError { return error }
        if let error = error as? SCStreamError, error.code == .userDeclined {
            return .screenCapturePermissionDenied
        }
        return .deviceUnavailable(error.localizedDescription)
    }

    // MARK: - Sample conversion

    /// ScreenCaptureKit stamps buffers on the host clock. A timestamp that's far off "now" means
    /// that assumption broke, so fall back to the arrival time.
    private static func hostTime(of sampleBuffer: CMSampleBuffer, buffer: AVAudioPCMBuffer) -> TimeInterval {
        let arrival = HostClock.now() - Double(buffer.frameLength) / buffer.format.sampleRate
        let presentation = sampleBuffer.presentationTimeStamp
        guard presentation.isNumeric, abs(presentation.seconds - arrival) < 2 else { return arrival }
        return presentation.seconds
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sampleBuffer.formatDescription,
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: streamDescription)
        else { return nil }

        let frameCount = sampleBuffer.numSamples
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))
        else { return nil }
        buffer.frameLength = buffer.frameCapacity

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else {
            audioLogger.error("Couldn't read system audio samples (OSStatus \(status, privacy: .public))")
            return nil
        }
        return buffer
    }
}

extension SystemAudioCapture: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let buffer = Self.pcmBuffer(from: sampleBuffer),
              let chunk = resampler.process(buffer, hostTime: Self.hostTime(of: sampleBuffer, buffer: buffer))
        else { return }
        let continuation = state.withLockUnchecked { $0.continuation }
        continuation?.yield(chunk)
    }
}

extension SystemAudioCapture: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let continuation = state.withLockUnchecked { state -> Continuation? in
            guard state.phase != .stopped else { return nil }
            state.phase = .stopped
            defer {
                state.stream = nil
                state.continuation = nil
            }
            return state.continuation
        }
        guard let continuation else { return }

        // Stopping from the macOS menu bar capture indicator ends the session normally.
        if let error = error as? SCStreamError, error.code == .userStopped {
            audioLogger.info("System audio capture stopped by the user")
            continuation.finish()
            return
        }
        audioLogger.error("System audio capture stopped: \(error.localizedDescription, privacy: .public)")
        continuation.finish(throwing: Self.captureError(from: error))
    }
}
