import Foundation
@testable import MixdownCore
import Testing

struct AudioTrackTests {
    @Test func concatenatesChunksWithoutHostTime() {
        var track = AudioTrack()
        track.append(Fixtures.chunk(seconds: 1))
        track.append(Fixtures.chunk(seconds: 0.5))
        #expect(track.samples.count == 24_000)
        #expect(track.startHostTime == nil)
    }

    @Test func fillsGapsWithSilence() {
        var track = AudioTrack()
        track.append(Fixtures.chunk(seconds: 1, hostTime: 50))
        // Nothing arrived for two seconds, like a source that drops out.
        track.append(Fixtures.chunk(seconds: 1, hostTime: 53))

        #expect(track.startHostTime == 50)
        #expect(track.duration == 4)
        #expect(track.samples[16_000..<48_000].allSatisfy { $0 == 0 })
        #expect(track.samples.last == 0.1)
    }

    @Test func appendsLaterTrackAfterTheGap() {
        var first = AudioTrack()
        first.append(Fixtures.chunk(seconds: 1, hostTime: 50))
        var second = AudioTrack()
        second.append(Fixtures.chunk(seconds: 1, hostTime: 51.5))

        first.append(second)
        first.append(AudioTrack())

        #expect(first.startHostTime == 50)
        #expect(first.duration == 2.5)
        #expect(first.samples[16_000..<24_000].allSatisfy { $0 == 0 })

        var empty = AudioTrack()
        empty.append(second)
        #expect(empty == second)
    }

    @Test func ignoresJitter() {
        var track = AudioTrack()
        track.append(Fixtures.chunk(seconds: 1, hostTime: 50))
        track.append(Fixtures.chunk(seconds: 1, hostTime: 51.1))
        track.append(Fixtures.chunk(seconds: 1, hostTime: 51.9))
        #expect(track.duration == 3)
    }

    @Test func offsetsAreRelativeToEarliestTrack() {
        var early = AudioTrack()
        early.append(Fixtures.chunk(seconds: 1, hostTime: 10))
        var late = AudioTrack()
        late.append(Fixtures.chunk(seconds: 1, hostTime: 10.75))
        let untimed = AudioTrack()

        #expect(AudioTrack.startOffsets(of: [late, early, untimed]) == [0.75, 0, 0])
        #expect(AudioTrack.startOffsets(of: [untimed, untimed]) == [0, 0])
    }
}
