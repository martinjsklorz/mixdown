import Foundation
import Testing

@testable import MixdownCore

struct CaptureLoopTests {
    private struct Failure: Error {}

    private func loop(
        kind: AudioSourceKind = .microphone,
        keepsAudio: Bool = true,
        hostTimeShift: TimeInterval = 0,
        liveFeed: AsyncStream<CaptureLoop.LiveFeed>.Continuation? = nil,
        levels: LockedValue<[InputLevel]> = LockedValue([])
    ) -> CaptureLoop {
        CaptureLoop(
            kind: kind,
            deviceName: "Test",
            keepsAudio: keepsAudio,
            hostTimeShift: hostTimeShift,
            echoReference: nil,
            echoCancellation: nil,
            liveFeed: liveFeed,
            reportLevel: { level, _ in levels.update { $0.append(level) } }
        )
    }

    private func stream(_ chunks: [AudioChunk], error: (any Error)? = nil) -> AsyncThrowingStream<AudioChunk, any Error>
    {
        AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish(throwing: error)
        }
    }

    @Test func drainsTheStreamIntoATrackWithGapsFilled() async {
        let levels = LockedValue<[InputLevel]>([])
        let output = await loop(levels: levels).start(
            stream([Fixtures.chunk(seconds: 1, hostTime: 50), Fixtures.chunk(seconds: 1, hostTime: 52)])
        ).value

        #expect(output.track.duration == 3)
        #expect(output.track.startHostTime == 50)
        #expect(output.error == nil)
        // One per chunk captured, as each is longer than a level's interval; none for the gap.
        #expect(levels.current.count == 2)
    }

    @Test func movesTheAudioBackByTheTimePaused() async {
        let output = await loop(hostTimeShift: 30).start(stream([Fixtures.chunk(seconds: 1, hostTime: 80)])).value

        #expect(output.track.startHostTime == 50)
    }

    @Test func countsWithoutKeepingSamples() async {
        let output = await loop(keepsAudio: false).start(stream([Fixtures.chunk(seconds: 1)])).value

        #expect(output.track.duration == 1)
        #expect(output.track.samples.isEmpty)
    }

    @Test func returnsTheErrorThatEndedTheStreamWithWhatCameBefore() async {
        let output = await loop().start(stream([Fixtures.chunk(seconds: 1)], error: Failure())).value

        #expect(output.error is Failure)
        #expect(output.track.duration == 1)
    }

    @Test func feedsTheLiveSessionInPiecesAndFinishesIt() async {
        let (feed, continuation) = AsyncStream<CaptureLoop.LiveFeed>.makeStream()
        let chunks = (0..<10).map { Fixtures.chunk(seconds: 0.1, hostTime: 7 + Double($0) / 10) }
        let output = await loop(liveFeed: continuation).start(stream(chunks)).value

        var pieces: [CaptureLoop.LiveFeed] = []
        for await piece in feed {
            pieces.append(piece)
        }
        // At least `liveFeedSampleCount` at a time, and the rest once the capture ends.
        #expect(pieces.map(\.samples.count) == [6_400, 6_400, 3_200])
        #expect(pieces.allSatisfy { $0.startHostTime == 7 })
        #expect(output.track.samples.count == 16_000)
    }
}
