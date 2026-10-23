@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import MixdownCore
import Synchronization
import os

/// What an `IOProcCapture` records from: a microphone or the system audio tap. Either runs a
/// Core Audio IO proc made with `IOProcCapture.ioBlock(writingTo:formats:)`.
protocol CaptureSource: AnyObject, Sendable {
    /// Names the capture in log messages, e.g. "Microphone capture on “AirPods”".
    var logName: String { get }
    /// The formats the IO proc has delivered in.
    var formats: FormatHistory { get }

    /// Runs before `start`, e.g. to ask for permission.
    func prepare() async throws
    /// Starts IO into `ring`.
    /// - Parameter onFailure: Called, possibly more than once, when the source can't be recorded
    ///   from anymore.
    func start(into ring: CaptureRing, onFailure: @escaping @Sendable (AudioCaptureError) -> Void) throws
    /// Stops IO and removes whatever `start` set up. Safe after a partial setup. Once it returns,
    /// the IO block isn't called anymore.
    func invalidate()
}

extension CaptureSource {
    func prepare() async throws {}
}

/// Records from a `CaptureSource` and turns its IO cycles into 16 kHz mono chunks.
///
/// The IO block runs on the device's real-time IO thread and only copies each cycle into a
/// `CaptureRing`, so it never allocates, takes a lock or waits. A timer on `sampleQueue` reads
/// the ring, converts and delivers.
///
/// `@unchecked Sendable`: mutable state lives behind `state`; `resampler`, `currentFormat` and
/// `reportedDrops` are only touched on `sampleQueue`.
final class IOProcCapture: AudioCapturing, @unchecked Sendable {
    private typealias Continuation = AsyncThrowingStream<AudioChunk, any Error>.Continuation

    private enum Phase { case idle, starting, running, stopped }

    private struct State {
        var phase: Phase = .idle
        var continuation: Continuation?
        var readTimer: (any DispatchSourceTimer)?
    }

    /// How often the ring is read. IO cycles are around 10 ms, so most reads find one.
    private static let readInterval: DispatchTimeInterval = .milliseconds(10)

    private let source: any CaptureSource
    private let ring = CaptureRing()
    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let sampleQueue = DispatchQueue(label: "app.mixdown.audio.capture", qos: .userInitiated)
    private let resampler: AudioResampler
    private var currentFormat: (generation: Int, format: AVAudioFormat)?
    private var reportedDrops = 0

    init(source: any CaptureSource) throws {
        self.source = source
        resampler = try AudioResampler()
    }

    deinit {
        // Released without `stop()`: end the stream so its reader isn't left waiting. The source
        // stops itself when it's released.
        let (continuation, readTimer) = state.withLockUnchecked { ($0.continuation, $0.readTimer) }
        readTimer?.cancel()
        continuation?.finish()
    }

    func start() async throws -> AsyncThrowingStream<AudioChunk, any Error> {
        let (stream, continuation) = AsyncThrowingStream<AudioChunk, any Error>.makeStream()
        try state.withLockUnchecked { state in
            guard state.phase == .idle else { throw AudioCaptureError.alreadyRunning }
            state.phase = .starting
            state.continuation = continuation
        }

        let source = source
        do {
            try await source.prepare()
            // stop() may have run while a permission prompt was showing.
            guard state.withLockUnchecked({ $0.phase == .starting }) else { return stream }
            try source.start(into: ring) { [weak self] error in
                guard let self else { return }
                Task { await self.finish(throwing: error) }
            }
        } catch {
            source.invalidate()
            state.withLockUnchecked { state in
                state.phase = .stopped
                state.continuation = nil
            }
            continuation.finish(throwing: error)
            throw error
        }

        let readTimer = DispatchSource.makeTimerSource(queue: sampleQueue)
        readTimer.schedule(deadline: .now() + Self.readInterval, repeating: Self.readInterval, leeway: .milliseconds(5))
        readTimer.setEventHandler { [weak self] in
            // Once `finish` has taken the continuation, it reads what's left itself.
            guard let self, let continuation = state.withLockUnchecked({ $0.continuation }) else { return }
            readRing(into: continuation)
        }
        // Activated either way: releasing a timer that never was crashes.
        readTimer.activate()

        let isStillStarting = state.withLockUnchecked { state -> Bool in
            guard state.phase == .starting else { return false }
            state.phase = .running
            state.readTimer = readTimer
            return true
        }
        guard isStillStarting else {
            // stop() ran while the source was starting; it already finished the continuation.
            readTimer.cancel()
            source.invalidate()
            return stream
        }

        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.stop() }
        }
        audioLogger.info("\(source.logName, privacy: .public) started")
        return stream
    }

    func stop() async {
        await finish(throwing: nil)
    }

    /// Stops the source and ends the stream, with `error` if the capture failed.
    private func finish(throwing error: (any Error)?) async {
        let (wasRunning, continuation, readTimer) = state.withLockUnchecked {
            state -> (Bool, Continuation?, (any DispatchSourceTimer)?) in
            let wasRunning = state.phase == .running
            guard state.phase != .stopped else { return (wasRunning, nil, nil) }
            state.phase = .stopped
            defer {
                state.continuation = nil
                state.readTimer = nil
            }
            return (wasRunning, state.continuation, state.readTimer)
        }
        guard let continuation else { return }

        // While starting, `start()` stops the source itself once it notices.
        if wasRunning { source.invalidate() }
        // Deliver what the IO proc wrote before it stopped, then end the stream.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            sampleQueue.async { [self] in
                readTimer?.cancel()
                readRing(into: continuation)
                done.resume()
            }
        }
        if let error {
            audioLogger.error(
                "\(self.source.logName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
            )
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
            audioLogger.info("\(self.source.logName, privacy: .public) stopped")
        }
    }

    // MARK: - IO thread

    /// The IO block for a source's IO proc: copies each cycle's first input stream into `ring`,
    /// tagged with the current format. Pass no dispatch queue with it, so it runs right on the
    /// IO thread. Only reads atomics and copies memory, nothing that could block it.
    static func ioBlock(writingTo ring: CaptureRing, formats: FormatHistory) -> AudioDeviceIOBlock {
        { _, inputData, inputTime, _, _ in
            let arrivalHostTime = mach_absolute_time()
            let generation = formats.currentGeneration
            // A device with several input streams (some audio interfaces) delivers one buffer
            // per stream; the first is the main input.
            guard generation >= 0, inputData.pointee.mNumberBuffers > 0 else { return }
            let buffer = inputData.pointee.mBuffers
            guard let data = buffer.mData, buffer.mDataByteSize > 0 else { return }
            let time = inputTime.pointee
            let cycle = CapturedCycle(
                channelCount: buffer.mNumberChannels,
                formatGeneration: generation,
                hostTime: time.mFlags.contains(.hostTimeValid) ? time.mHostTime : nil,
                arrivalHostTime: arrivalHostTime
            )
            ring.write(cycle, bytes: UnsafeRawBufferPointer(start: data, count: Int(buffer.mDataByteSize)))
        }
    }

    // MARK: - Samples

    /// Converts and delivers every cycle in the ring.
    private func readRing(into continuation: Continuation) {
        ring.readAll { cycle, bytes in
            guard let chunk = chunk(from: cycle, bytes: bytes) else { return }
            continuation.yield(chunk)
        }
        let drops = ring.droppedCycles
        if drops > reportedDrops {
            audioLogger.error(
                "\(self.source.logName, privacy: .public) dropped \(drops - self.reportedDrops, privacy: .public) IO cycles: samples weren't read fast enough"
            )
            reportedDrops = drops
        }
    }

    private func chunk(from cycle: CapturedCycle, bytes: UnsafeRawBufferPointer) -> AudioChunk? {
        // Right after a format change the IO proc can run before the format listener has caught
        // up, so a mismatched buffer is dropped.
        guard let format = format(generation: cycle.formatGeneration), cycle.channelCount == format.channelCount
        else { return nil }
        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: cycle.channelCount,
                mDataByteSize: UInt32(bytes.count),
                mData: UnsafeMutableRawPointer(mutating: bytes.baseAddress)
            )
        )
        return withUnsafePointer(to: &bufferList) { bufferList -> AudioChunk? in
            // No copy needed: the resampler copies while downmixing, before the ring reuses the bytes.
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: bufferList, deallocator: nil)
            else { return nil }
            let hostTime = HostClock.captureTime(
                of: cycle,
                frameCount: buffer.frameLength,
                sampleRate: format.sampleRate
            )
            return resampler.process(buffer, hostTime: hostTime)
        }
    }

    private func format(generation: Int) -> AVAudioFormat? {
        if let currentFormat, currentFormat.generation == generation { return currentFormat.format }
        guard let format = source.formats.format(generation: generation) else { return nil }
        currentFormat = (generation, format)
        return format
    }
}

/// Every format a source's IO proc has delivered in, numbered, so the IO thread can tag each
/// cycle with its format by reading one atomic, and the samples are read in the format they
/// arrived in even if it has changed since.
///
/// `@unchecked Sendable`: the formats are behind a lock; the generation is atomic.
final class FormatHistory: @unchecked Sendable {
    private let formats = OSAllocatedUnfairLock<[AVAudioFormat]>(uncheckedState: [])
    private let current = Atomic<Int>(-1)

    /// The current format's number, -1 before there's one. Safe on the IO thread.
    var currentGeneration: Int { current.load(ordering: .acquiring) }

    /// Makes `format` the current one. Returns `false` if it already was.
    @discardableResult
    func update(_ format: AVAudioFormat) -> Bool {
        formats.withLockUnchecked { formats in
            guard formats.last != format else { return false }
            formats.append(format)
            // Inside the lock, so updates from two listener queues can't publish out of order.
            current.store(formats.count - 1, ordering: .releasing)
            return true
        }
    }

    func format(generation: Int) -> AVAudioFormat? {
        formats.withLockUnchecked { formats in
            formats.indices.contains(generation) ? formats[generation] : nil
        }
    }
}
