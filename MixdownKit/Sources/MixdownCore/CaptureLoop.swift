import Foundation
import os

/// Drains one capture's stream into a track, off the main actor, until the capture ends.
///
/// On the way it fills gaps with silence, moves the audio back by the time the recording spent
/// paused, writes system audio into the echo reference and takes the echo out of microphones,
/// measures the level and finds speech, and hands the audio to a live session in
/// `RecordingCoordinator.liveFeedSampleCount` pieces.
struct CaptureLoop: Sendable {
    /// Audio handed to a live session.
    struct LiveFeed: Sendable {
        let samples: [Float]
        /// The capture's `startHostTime`, which the session's times count from.
        let startHostTime: TimeInterval?
    }

    /// Everything a capture stream produced, plus the error that ended it early, if any.
    struct Output: Sendable {
        var track: AudioTrack
        /// When there was speech, in seconds from the track's first sample.
        var speech: [Range<TimeInterval>] = []
        var error: (any Error)?
    }

    let kind: AudioSourceKind
    /// For the log.
    let deviceName: String
    /// Whether the track keeps its samples, rather than only counting them.
    let keepsAudio: Bool
    /// Taken off every chunk's host time: the time the recording spent paused before the capture
    /// started, so the pauses leave no gap to fill.
    let hostTimeShift: TimeInterval
    /// The recording's system audio. System audio is written into it; microphones take its echo
    /// out once it's active and `echoCancellation` has a canceller ready. `nil` without echo
    /// cancellation.
    let echoReference: EchoReference?
    let echoCancellation: (any EchoCancellation)?
    /// Gets the audio as it's kept, once the echo is out; `nil` unless transcribing live. Finished
    /// when the loop ends.
    let liveFeed: AsyncStream<LiveFeed>.Continuation?
    /// Called about ten times a second with the level and the seconds of speech since the last
    /// call. Mustn't block, so a busy main actor never holds up capture.
    let reportLevel: @Sendable (InputLevel, TimeInterval) -> Void

    nonisolated static let echoLogger = Logger(subsystem: "app.mixdown", category: "echo")

    /// Starts draining `stream` on a task of its own, which returns the output once the stream ends.
    func start(_ stream: AsyncThrowingStream<AudioChunk, any Error>) -> Task<Output, Never> {
        // Right away, so microphones count on system audio from now on.
        if kind == .systemAudio { echoReference?.beginWriting() }
        return Task.detached(priority: .userInitiated) { [self] in await drain(stream) }
    }

    private func drain(_ stream: AsyncThrowingStream<AudioChunk, any Error>) async -> Output {
        // Where the captured samples go, gaps filled; `track` gets them once their echo is
        // removed, in step with it.
        var timeline = AudioTrack(keepsSamples: false)
        var track = AudioTrack(keepsSamples: keepsAudio)
        var echoRemover: EchoRemover?
        // Whether system audio recorded alongside, which tells why `echoRemover` never started.
        var sawSystemAudio = false
        var meter = LevelMeter()
        // Judges the audio as it's kept, so the microphones' echo doesn't count as the user
        // talking.
        var speechDetector = SpeechActivityDetector()
        var unsentSpeech: TimeInterval = 0
        var unfed: [Float] = []
        defer {
            if kind == .systemAudio { echoReference?.endWriting() }
            if !unfed.isEmpty {
                liveFeed?.yield(LiveFeed(samples: unfed, startHostTime: track.startHostTime))
            }
            liveFeed?.finish()
        }
        func keep(_ samples: [Float]) {
            guard !samples.isEmpty else { return }
            unsentSpeech += speechDetector.add(samples)
            track.append(AudioChunk(samples: samples, hostTime: timeline.startHostTime.map { $0 + track.duration }))
            guard let liveFeed else { return }
            unfed.append(contentsOf: samples)
            if unfed.count >= RecordingCoordinator.liveFeedSampleCount {
                liveFeed.yield(LiveFeed(samples: unfed, startHostTime: track.startHostTime))
                unfed.removeAll(keepingCapacity: true)
            }
        }
        var captureError: (any Error)?
        do {
            for try await captured in stream {
                let chunk =
                    hostTimeShift > 0
                    ? AudioChunk(samples: captured.samples, hostTime: captured.hostTime.map { $0 - hostTimeShift })
                    : captured
                // Including silence filled into a gap, so the live session's clock stays in step
                // with the track's.
                let added = timeline.append(chunk)
                if kind == .systemAudio { echoReference?.write(chunk) }
                // Starts once system audio records too and a canceller is ready.
                if kind == .microphone, echoRemover == nil, let echoReference, echoReference.state.isActive {
                    sawSystemAudio = true
                    if let canceller = echoCancellation?.takeCanceller() {
                        let start = timeline.startHostTime.map {
                            $0 + timeline.duration - Double(added.count) / AudioChunk.sampleRate
                        }
                        echoRemover = EchoRemover(
                            canceller: canceller,
                            reference: echoReference,
                            startHostTime: start
                        )
                    }
                }
                keep(echoRemover?.process(added) ?? added)
                if let level = meter.add(chunk) {
                    reportLevel(level, unsentSpeech)
                    unsentSpeech = 0
                }
            }
        } catch {
            captureError = error
        }
        if let echoRemover {
            keep(echoRemover.finish())
        } else if kind == .microphone, echoReference != nil {
            let reason = sawSystemAudio ? "no canceller loaded in time" : "no system audio recorded alongside"
            Self.echoLogger.info(
                "Recorded \(deviceName, privacy: .public) without echo removal: \(reason, privacy: .public)"
            )
        }
        return Output(track: track, speech: speechDetector.spans, error: captureError)
    }
}
