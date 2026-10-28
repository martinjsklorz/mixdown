@preconcurrency import AVFoundation
import MixdownCore
import Testing

@testable import MixdownAudio

struct IOProcCaptureTests {
    @Test func deliversEverythingWrittenBeforeStopThenFinishes() async throws {
        let source = FakeCaptureSource(format: try AudioFormats.interleaved(sampleRate: 48_000, channels: 2))
        let capture = try IOProcCapture(source: source)
        let stream = try await capture.start()

        // Half a second of 48 kHz stereo in 10 ms cycles.
        for _ in 0..<50 {
            source.write([Float](repeating: 0.25, count: 960), channelCount: 2)
        }
        await capture.stop()

        let samples = try await Self.samples(of: stream)
        // A third of the frames, less what the converter still holds back.
        #expect((7_800...8_000).contains(samples.count))
        #expect(source.calls == FakeCaptureSource.Calls(start: 1, invalidate: 1))
    }

    @Test func stopWhilePreparingNeverStartsTheSource() async throws {
        let source = FakeCaptureSource(
            format: try AudioFormats.interleaved(sampleRate: 16_000, channels: 1),
            holdsInPrepare: true
        )
        let capture = try IOProcCapture(source: source)
        let starting = Task { try await capture.start() }

        await source.waitUntilPreparing()
        await capture.stop()
        source.finishPreparing()

        let stream = try await starting.value
        #expect(try await Self.samples(of: stream).isEmpty)
        #expect(source.calls.start == 0)
    }

    @Test func failureEndsTheStreamWithItsErrorAndStopsTheSourceOnce() async throws {
        let source = FakeCaptureSource(format: try AudioFormats.interleaved(sampleRate: 16_000, channels: 1))
        let capture = try IOProcCapture(source: source)
        let stream = try await capture.start()

        source.fail(.deviceNotFound("Headset"))
        source.fail(.deviceNotFound("Headset"))

        await #expect(throws: AudioCaptureError.deviceNotFound("Headset")) {
            _ = try await Self.samples(of: stream)
        }
        #expect(source.calls == FakeCaptureSource.Calls(start: 1, invalidate: 1))
    }

    @Test func secondStartThrows() async throws {
        let source = FakeCaptureSource(format: try AudioFormats.interleaved(sampleRate: 16_000, channels: 1))
        let capture = try IOProcCapture(source: source)
        // Kept, as dropping the stream stops the capture.
        let stream = try await capture.start()

        await #expect(throws: AudioCaptureError.alreadyRunning) {
            _ = try await capture.start()
        }
        await capture.stop()
        #expect(try await Self.samples(of: stream).isEmpty)
        #expect(source.calls == FakeCaptureSource.Calls(start: 1, invalidate: 1))
    }

    @Test func convertsACycleInTheFormatItArrivedIn() async throws {
        let source = FakeCaptureSource(format: try AudioFormats.interleaved(sampleRate: 16_000, channels: 1))
        let capture = try IOProcCapture(source: source)
        let stream = try await capture.start()

        source.formats.update(try AudioFormats.interleaved(sampleRate: 48_000, channels: 2))
        source.write([Float](repeating: 0.5, count: 160), channelCount: 1, generation: 0)
        await capture.stop()

        // At 16 kHz mono the cycle passes through as it is; read as 48 kHz stereo it wouldn't.
        #expect(try await Self.samples(of: stream) == [Float](repeating: 0.5, count: 160))
    }

    @Test func readsTheFormatAgainWhenCyclesStopMatchingIt() async throws {
        let source = FakeCaptureSource(
            format: try AudioFormats.interleaved(sampleRate: 16_000, channels: 2),
            refreshedFormat: try AudioFormats.interleaved(sampleRate: 16_000, channels: 1)
        )
        let capture = try IOProcCapture(source: source)
        let stream = try await capture.start()

        // The device went mono without a notification. Once the source has read its format
        // again, the cycles tagged with the new one come through.
        for _ in 0..<IOProcCapture.formatRefreshCycles {
            source.write([Float](repeating: 0.5, count: 160), channelCount: 1, generation: 0)
        }
        source.write([Float](repeating: 0.25, count: 160), channelCount: 1, generation: 1)
        await capture.stop()

        #expect(try await Self.samples(of: stream) == [Float](repeating: 0.25, count: 160))
        #expect(source.calls.refreshFormat == 1)
    }

    @Test func failsWhenTheFormatCantBeRead() async throws {
        let source = FakeCaptureSource(
            format: try AudioFormats.interleaved(.pcmFormatFloat64, sampleRate: 16_000, channels: 1)
        )
        let capture = try IOProcCapture(source: source)
        let stream = try await capture.start()

        for _ in 0..<IOProcCapture.unusableCycleLimit {
            source.write([Float](repeating: 0, count: 320), channelCount: 1)
        }

        await #expect(throws: AudioCaptureError.self) {
            _ = try await Self.samples(of: stream)
        }
        #expect(source.calls.refreshFormat == 1)
        #expect(source.calls.invalidate == 1)
    }

    private static func samples(of stream: AsyncThrowingStream<AudioChunk, any Error>) async throws -> [Float] {
        var samples: [Float] = []
        for try await chunk in stream {
            samples += chunk.samples
        }
        return samples
    }
}

struct FormatHistoryTests {
    @Test func numbersEachNewFormat() throws {
        let mono = try AudioFormats.interleaved(sampleRate: 16_000, channels: 1)
        let stereo = try AudioFormats.interleaved(sampleRate: 48_000, channels: 2)
        let history = FormatHistory()
        #expect(history.currentGeneration == -1)
        #expect(history.format(generation: 0) == nil)

        #expect(history.update(mono))
        #expect(!history.update(mono))
        #expect(history.currentGeneration == 0)
        #expect(history.update(stereo))
        #expect(history.update(mono))

        #expect(history.currentGeneration == 2)
        #expect(history.format(generation: 0) == mono)
        #expect(history.format(generation: 1) == stereo)
        #expect(history.format(generation: 2) == mono)
        #expect(history.format(generation: 3) == nil)
    }
}

struct HostClockTests {
    private static let arrival = AVAudioTime.hostTime(forSeconds: 1_000)

    private static func captureTime(hostTime: UInt64?) -> TimeInterval {
        let cycle = CapturedCycle(channelCount: 1, formatGeneration: 0, hostTime: hostTime, arrivalHostTime: arrival)
        return HostClock.captureTime(of: cycle, frameCount: 480, sampleRate: 48_000)
    }

    @Test func keepsAStampNearTheArrival() {
        let stamp = AVAudioTime.hostTime(forSeconds: 999.98)
        #expect(Self.captureTime(hostTime: stamp) == AVAudioTime.seconds(forHostTime: stamp))
    }

    @Test(arguments: [nil, AVAudioTime.hostTime(forSeconds: 990)])
    func fallsBackToTheArrivalLessTheCycle(hostTime: UInt64?) {
        #expect(abs(Self.captureTime(hostTime: hostTime) - 999.99) < 1e-6)
    }
}
