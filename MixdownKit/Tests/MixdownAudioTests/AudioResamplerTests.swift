@preconcurrency import AVFoundation
import MixdownCore
import Testing

@testable import MixdownAudio

struct AudioResamplerTests {
    @Test func averagesInterleavedInt16Channels() throws {
        let resampler = try AudioResampler()
        let format = try AudioFormats.interleaved(.pcmFormatInt16, sampleRate: 16_000, channels: 2)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        buffer.frameLength = 160
        let data = try #require(buffer.int16ChannelData?[0])
        for frame in 0..<160 {
            data[2 * frame] = 16_384
            data[2 * frame + 1] = -8_192
        }

        let chunk = try #require(resampler.process(buffer, hostTime: 5))
        #expect(chunk.samples == [Float](repeating: 0.125, count: 160))
        #expect(chunk.hostTime == 5)
    }

    @Test func passes16kHzThroughUnchanged() throws {
        let resampler = try AudioResampler()
        let samples = (0..<160).map { Float($0) / 160 }
        let chunk = try #require(resampler.process(try Self.buffer(samples, sampleRate: 16_000), hostTime: nil))
        #expect(chunk.samples == samples)
    }

    @Test func resamples48kHzToAThird() throws {
        let resampler = try AudioResampler()
        var count = 0
        for _ in 0..<100 {
            let buffer = try Self.buffer([Float](repeating: 0.5, count: 480), sampleRate: 48_000)
            count += resampler.process(buffer, hostTime: nil)?.samples.count ?? 0
        }
        // A third of the frames, less what the converter still holds back.
        #expect((15_800...16_000).contains(count))
    }

    /// A headset switching to its 16 kHz call profile and back: the second 48 kHz stretch must
    /// not start with what the converter held back from the first.
    @Test func startsAFreshConverterAfterA16kHzStretch() throws {
        let resampler = try AudioResampler()
        for _ in 0..<20 {
            _ = resampler.process(
                try Self.buffer([Float](repeating: 0.5, count: 480), sampleRate: 48_000),
                hostTime: nil
            )
        }
        for _ in 0..<5 {
            _ = resampler.process(try Self.buffer([Float](repeating: 0, count: 160), sampleRate: 16_000), hostTime: nil)
        }

        var samples: [Float] = []
        for _ in 0..<5 {
            let buffer = try Self.buffer([Float](repeating: 0, count: 480), sampleRate: 48_000)
            samples += resampler.process(buffer, hostTime: nil)?.samples ?? []
        }
        #expect(!samples.isEmpty)
        #expect(samples.allSatisfy { abs($0) < 0.01 })
    }

    private static func buffer(_ samples: [Float], sampleRate: Double) throws -> AVAudioPCMBuffer {
        let format = try AudioFormats.interleaved(sampleRate: sampleRate, channels: 1)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let data = try #require(buffer.floatChannelData?[0])
        data.update(from: samples, count: samples.count)
        return buffer
    }
}
