@preconcurrency import AVFoundation
import MixdownCore
import Synchronization
import Testing

@testable import MixdownAudio

/// A `CaptureSource` without Core Audio: tests write IO cycles into the ring it was started with,
/// fail it, and hold it in `prepare` the way a permission prompt does.
final class FakeCaptureSource: CaptureSource {
    struct Calls: Equatable {
        var start = 0
        var invalidate = 0
        var refreshFormat = 0
    }

    let logName = "Fake capture"
    let formats = FormatHistory()
    /// What `refreshFormat` publishes, as if it read the device's format again.
    let refreshedFormat: AVAudioFormat?
    private let holdsInPrepare: Bool
    private let state = Mutex<State>(State())
    private let (prepareEntered, prepareEnteredContinuation) = AsyncStream<Void>.makeStream()
    private let (prepareRelease, prepareReleaseContinuation) = AsyncStream<Void>.makeStream()

    private struct State {
        var calls = Calls()
        var ring: CaptureRing?
        var onFailure: (@Sendable (AudioCaptureError) -> Void)?
    }

    init(format: AVAudioFormat, refreshedFormat: AVAudioFormat? = nil, holdsInPrepare: Bool = false) {
        self.refreshedFormat = refreshedFormat
        self.holdsInPrepare = holdsInPrepare
        formats.update(format)
    }

    var calls: Calls { state.withLock { $0.calls } }

    func prepare() async throws {
        guard holdsInPrepare else { return }
        prepareEnteredContinuation.yield()
        for await _ in prepareRelease { break }
    }

    /// Waits until `prepare` has started.
    func waitUntilPreparing() async {
        for await _ in prepareEntered { break }
    }

    /// Lets `prepare` return.
    func finishPreparing() {
        prepareReleaseContinuation.yield()
    }

    func start(into ring: CaptureRing, onFailure: @escaping @Sendable (AudioCaptureError) -> Void) throws {
        state.withLock { state in
            state.calls.start += 1
            state.ring = ring
            state.onFailure = onFailure
        }
    }

    func refreshFormat() {
        state.withLock { $0.calls.refreshFormat += 1 }
        if let refreshedFormat { formats.update(refreshedFormat) }
    }

    func invalidate() {
        state.withLock { $0.calls.invalidate += 1 }
    }

    /// Reports `error` as the source's IO proc would.
    func fail(_ error: AudioCaptureError) {
        let onFailure = state.withLock { $0.onFailure }
        onFailure?(error)
    }

    /// Writes one IO cycle of interleaved `samples`, tagged with `generation` (the current
    /// format's by default), as the IO block would.
    func write(_ samples: [Float], channelCount: UInt32, generation: Int? = nil) {
        guard let ring = state.withLock({ $0.ring }) else {
            preconditionFailure("The source hasn't been started")
        }
        let cycle = CapturedCycle(
            channelCount: channelCount,
            formatGeneration: generation ?? formats.currentGeneration,
            hostTime: nil,
            arrivalHostTime: mach_absolute_time()
        )
        let written = samples.withUnsafeBytes { ring.write(cycle, bytes: $0) }
        precondition(written, "The ring is full")
    }
}

enum AudioFormats {
    /// Interleaved samples, as an IO proc delivers them.
    static func interleaved(
        _ commonFormat: AVAudioCommonFormat = .pcmFormatFloat32,
        sampleRate: Double,
        channels: AVAudioChannelCount
    ) throws -> AVAudioFormat {
        try #require(
            AVAudioFormat(commonFormat: commonFormat, sampleRate: sampleRate, channels: channels, interleaved: true)
        )
    }
}
