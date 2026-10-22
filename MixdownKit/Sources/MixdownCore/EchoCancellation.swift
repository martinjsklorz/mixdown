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
    /// Forgets what it learned about the echo, for when the reference is moved against the
    /// microphone.
    func reset()
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
/// Each microphone frame is paired with the system audio from `lead` after it, by host time, so
/// the canceller hears the reference `lead` sooner and finds the echo that much later after it.
/// The canceller only looks for echo that comes after the reference, up to about a second. How
/// late the echo really is depends on the speakers and microphone (Bluetooth adds a lot) and on
/// how far their timestamps disagree, and may even be early. So an `EchoDelayEstimator` looks for
/// it either way while the recording runs, and if the echo falls outside `alignedEchoDelays`, the
/// lead is changed to put it at `targetEchoDelay` and the canceller starts over. A frame whose
/// system audio hasn't arrived yet waits, for at most `maximumWait` plus the lead.
///
/// Returns as many samples as it's given, contiguously, though some come out only with a later
/// call or from `finish()`. Not thread-safe.
final class EchoRemover {
    /// How far ahead of the microphone's timestamps the reference is read at first, in samples
    /// (100 ms): room for timestamps that put the echo slightly before its system audio.
    static let referenceLead = 1_600
    /// How much microphone audio may wait for its system audio, on top of the lead, in samples
    /// (0.5 s).
    static let maximumWait = 8_000
    /// How late after the reference it's given the canceller should find the echo, in samples:
    /// from 32 ms, as it doesn't look before the reference, to 800 ms, short of where it stops
    /// looking.
    static let alignedEchoDelays = 512...12_800
    /// Where moving the reference puts the echo, in samples (100 ms): room for it to drift either
    /// way.
    static let targetEchoDelay = 1_600
    /// How close two estimates must be to agree, in samples (32 ms). The lead only changes once
    /// two in a row do, so a stray one doesn't start the canceller over.
    static let estimateTolerance = 512

    /// How far ahead of the microphone's timestamps the reference is read, in samples.
    private(set) var lead = EchoRemover.referenceLead

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
    private var estimator = EchoDelayEstimator()
    /// The microphone audio last handed to the canceller, ending at `processedCount`, for the
    /// estimator.
    private var recentMicrophone: [Float] = []
    /// Where the last window given to the estimator ended.
    private var estimatedUpTo = 0
    /// The latest estimate, and the one before if it's waiting for this one to agree.
    private var latestEstimate: EchoDelayEstimator.Estimate?
    private var unconfirmedDelay: Int?
    private let dump = EchoDump.startIfEnabled()
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
        let output = drain(isFinishing: true)
        dump?.finish()
        let delay = latestEstimate.map { "\(Self.milliseconds($0.delay)) ms after the system audio" } ?? "not found"
        logger.info("Echo removal finished; echo \(delay, privacy: .public)")
        return output
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
            let mayWait = !isFinishing && waiting < Self.maximumWait + lead
            guard let referenceFrame = referenceFrame(at: processedCount, mayWait: mayWait) else { break }

            var microphoneFrame = [Float](repeating: 0, count: frameSize)
            let firstIndex = processedCount - returnedCount
            for offset in 0..<min(frameSize, max(0, total - processedCount)) {
                microphoneFrame[offset] = unreturned[firstIndex + offset]
            }
            let cleaned: [Float]
            do {
                cleaned = try canceller.process(microphone: microphoneFrame, reference: referenceFrame)
                dump?.write(microphone: microphoneFrame, systemAudio: referenceFrame, cleaned: cleaned)
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
            if !isFinishing { estimateDelay(adding: microphoneFrame) }
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

    /// Remembers `microphoneFrame`, just handed to the canceller, and every `hop` gives the
    /// estimator the latest window that has system audio. Moves the reference once two estimates
    /// agree that the echo is out of the canceller's reach.
    private func estimateDelay(adding microphoneFrame: [Float]) {
        let windowSize = EchoDelayEstimator.windowSize
        // Enough to go back to while the system audio runs behind. Trimmed now and then, not
        // with every frame.
        let kept = windowSize + Self.maximumWait + EchoDelayEstimator.maximumDelay + Self.targetEchoDelay
        recentMicrophone.append(contentsOf: microphoneFrame)
        if recentMicrophone.count > 2 * kept { recentMicrophone.removeFirst(recentMicrophone.count - kept) }

        guard let origin else { return }
        let end = min(processedCount, reference.state.count - origin)
        let recentStart = processedCount - recentMicrophone.count
        guard end >= estimatedUpTo + EchoDelayEstimator.hop, end - windowSize >= max(recentStart, 0) else { return }
        estimatedUpTo = end
        let microphone = Array(recentMicrophone[(end - windowSize - recentStart)..<(end - recentStart)])
        let systemAudio = reference.read(from: origin + end - windowSize, count: windowSize)
        guard let estimate = estimator.add(microphone: microphone, reference: systemAudio) else { return }

        if latestEstimate.map({ abs($0.delay - estimate.delay) > Self.estimateTolerance }) ?? true {
            logger.debug(
                "Echo found \(Self.milliseconds(estimate.delay)) ms after the system audio, confidence \(estimate.confidence, format: .fixed(precision: 1))"
            )
        }
        latestEstimate = estimate
        guard !Self.alignedEchoDelays.contains(estimate.delay + lead) else {
            unconfirmedDelay = nil
            return
        }
        guard let previous = unconfirmedDelay, abs(previous - estimate.delay) <= Self.estimateTolerance else {
            unconfirmedDelay = estimate.delay
            return
        }
        unconfirmedDelay = nil
        // Never behind the microphone: the canceller finds an echo that late by itself.
        let newLead = min(
            max(Self.targetEchoDelay - estimate.delay, 0),
            EchoDelayEstimator.maximumDelay + Self.targetEchoDelay
        )
        guard newLead != lead else { return }
        logger.info(
            "Echo out of the canceller's reach at \(Self.milliseconds(estimate.delay + self.lead)) ms; now reading the system audio \(Self.milliseconds(newLead)) ms ahead and starting it over"
        )
        lead = newLead
        canceller.reset()
    }

    private static func milliseconds(_ samples: Int) -> Int {
        Int((Double(samples) / AudioChunk.sampleRate * 1000).rounded())
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
        let start = origin + position + lead
        if mayWait, state.isActive, state.count < start + frameSize { return nil }
        return reference.read(from: start, count: frameSize)
    }
}
