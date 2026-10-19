import Foundation
import os

/// Removes the echo of what the Mac plays (the reference) from a microphone that hears it through
/// the speakers, one frame at a time. Stateful: each microphone capture has one of its own, and its
/// calls are made one after another.
public protocol EchoCanceller: AnyObject, Sendable {
    /// Samples per frame, at `AudioChunk.sampleRate`.
    var frameSize: Int { get }
    /// How many samples late the output comes out: the first `latency` output samples precede the
    /// first input sample.
    var latency: Int { get }
    /// Returns `frameSize` microphone samples without the echo of `reference`, the system audio
    /// for the same moment (both `frameSize` samples), `latency` samples late.
    func process(microphone: [Float], reference: [Float]) throws -> [Float]
}

/// Hands out echo cancellers. Loading one can take a while, and the first time downloads its
/// model, so they're prepared ahead and taken without waiting.
public protocol EchoCancellation: Sendable {
    /// Starts loading a canceller in the background, unless one is ready or loading.
    func prepare()
    /// A ready canceller, for one microphone capture; `nil` while none is loaded yet. Prepares the
    /// next one.
    func takeCanceller() -> (any EchoCanceller)?
}

/// A recording's system audio, kept for a few seconds so the microphones' echo of it can be
/// removed. Written by the system audio capture, read by the microphone captures.
///
/// Positions count samples from the first one written, with gaps in the host times filled with
/// silence, like `AudioTrack`.
final class EchoReference: @unchecked Sendable {
    /// Samples kept: 4 s, plenty for microphones running a little behind or ahead.
    static let capacity = 64_000

    struct State {
        /// Host time of the first sample; `nil` until something is written.
        var startHostTime: TimeInterval?
        /// Samples written so far.
        var count: Int
        /// Whether a system audio capture is writing.
        var isActive: Bool
    }

    private let lock = NSLock()
    private var timeline = AudioTrack(keepsSamples: false)
    private var ring = [Float](repeating: 0, count: capacity)
    private var count = 0
    private var writers = 0

    /// Called when a system audio capture starts writing.
    func beginWriting() {
        lock.withLock { writers += 1 }
    }

    /// Called when a system audio capture has written its last chunk.
    func endWriting() {
        lock.withLock { writers -= 1 }
    }

    func write(_ chunk: AudioChunk) {
        lock.withLock {
            let added = timeline.append(chunk)
            // Only the last `capacity` samples of a long gap can be read back.
            let start = max(0, added.count - Self.capacity)
            var position = (count + start) % Self.capacity
            for sample in added[start...] {
                ring[position] = sample
                position = position + 1 == Self.capacity ? 0 : position + 1
            }
            count += added.count
        }
    }

    var state: State {
        lock.withLock { State(startHostTime: timeline.startHostTime, count: count, isActive: writers > 0) }
    }

    /// `length` samples from `start` on, with silence for positions not written yet or no longer
    /// kept.
    func read(from start: Int, count length: Int) -> [Float] {
        lock.withLock {
            var samples = [Float](repeating: 0, count: length)
            let kept = max(0, count - Self.capacity)..<count
            for offset in 0..<length where kept.contains(start + offset) {
                samples[offset] = ring[(start + offset) % Self.capacity]
            }
            return samples
        }
    }
}

/// Takes the echo of an `EchoReference` out of one microphone capture's audio as it comes in.
///
/// Each microphone frame is paired with the system audio from `referenceLead` before it, by host
/// time. The canceller finds the actual delay of the echo, which depends on the speakers, but only
/// looks for echo that comes after the reference; the lead covers timestamps that put the echo
/// slightly ahead of it. A frame whose system audio hasn't arrived yet waits, for at most
/// `maximumWait`.
///
/// Returns as many samples as it's given, contiguously, though some come out only with a later
/// call or from `finish()`. Not thread-safe.
final class EchoRemover {
    /// How far ahead of the echo's timestamps the reference is read, in samples (100 ms).
    static let referenceLead = 1_600
    /// How much microphone audio may wait for its system audio, in samples (0.5 s).
    static let maximumWait = 8_000

    private let canceller: any EchoCanceller
    private let reference: EchoReference
    /// Host time of the first sample given.
    private let startHostTime: TimeInterval?
    /// The reference position of the first sample given, once the reference has started.
    private var origin: Int?
    /// Samples given but not returned yet, from position `returnedCount` on.
    private var unreturned: [Float] = []
    private var returnedCount = 0
    /// Samples handed to the canceller, including the frame of silence that ends it.
    private var processedCount = 0
    /// Set once the canceller throws; the audio goes through as it is from then on.
    private var hasFailed = false
    private let logger = Logger(subsystem: "app.mixdown", category: "echo")

    /// - Parameter startHostTime: Host time of the first sample `process(_:)` will be given.
    init(canceller: any EchoCanceller, reference: EchoReference, startHostTime: TimeInterval?) {
        self.canceller = canceller
        self.reference = reference
        self.startHostTime = startHostTime
    }

    /// Adds microphone samples and returns those whose echo has been removed so far.
    func process(_ samples: [Float]) -> [Float] {
        unreturned.append(contentsOf: samples)
        return drain(isFinishing: false)
    }

    /// Returns the rest, with whatever system audio there is by now.
    func finish() -> [Float] {
        drain(isFinishing: true)
    }

    private func drain(isFinishing: Bool) -> [Float] {
        let frameSize = canceller.frameSize
        let latency = canceller.latency
        let total = returnedCount + unreturned.count
        var output: [Float] = []
        while !hasFailed {
            let waiting = total - processedCount
            if isFinishing {
                // Frames of silence push the last samples through the canceller's latency.
                guard processedCount - latency < total else { break }
            } else {
                guard waiting >= frameSize else { break }
            }
            let mayWait = !isFinishing && waiting < Self.maximumWait
            guard let referenceFrame = referenceFrame(at: processedCount, mayWait: mayWait) else { break }

            var microphoneFrame = [Float](repeating: 0, count: frameSize)
            let firstIndex = processedCount - returnedCount
            for offset in 0..<min(frameSize, max(0, total - processedCount)) {
                microphoneFrame[offset] = unreturned[firstIndex + offset]
            }
            let cleaned: [Float]
            do {
                cleaned = try canceller.process(microphone: microphoneFrame, reference: referenceFrame)
            } catch {
                logger.error(
                    "Echo cancellation failed, recording without it: \(error.localizedDescription, privacy: .public)"
                )
                hasFailed = true
                break
            }
            // The output is `latency` samples late; drop what precedes the first sample given and
            // what follows the last.
            let cleanedStart = processedCount - latency
            processedCount += frameSize
            let from = max(cleanedStart, returnedCount + output.count)
            let to = min(cleanedStart + cleaned.count, total)
            if from < to {
                output.append(contentsOf: cleaned[(from - cleanedStart)..<(to - cleanedStart)])
            }
        }
        if hasFailed {
            // The rest as it is, including what's still in the canceller.
            output.append(contentsOf: unreturned[output.count...])
        }
        unreturned.removeFirst(output.count)
        returnedCount += output.count
        return output
    }

    /// The system audio for the microphone frame at `position`, or `nil` if it should wait for it.
    private func referenceFrame(at position: Int, mayWait: Bool) -> [Float]? {
        let frameSize = canceller.frameSize
        let state = reference.state
        if origin == nil, let referenceStart = state.startHostTime {
            origin = startHostTime.map { Int((($0 - referenceStart) * AudioChunk.sampleRate).rounded()) } ?? 0
        }
        guard let origin else {
            return mayWait && state.isActive ? nil : [Float](repeating: 0, count: frameSize)
        }
        let start = origin + position - Self.referenceLead
        if mayWait, state.isActive, state.count < start + frameSize { return nil }
        return reference.read(from: start, count: frameSize)
    }
}
