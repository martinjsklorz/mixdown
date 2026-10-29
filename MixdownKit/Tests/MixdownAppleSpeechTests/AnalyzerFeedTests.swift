@preconcurrency import AVFoundation
import Foundation
import Speech
import Testing

@testable import MixdownAppleSpeech

struct AnalyzerFeedTests {
    private let input = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!
    /// A format like the one Apple's model asks for. `AnalyzerInput` takes 16-bit audio only.
    private let output = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!
    /// 25 s of a 440 Hz tone at 16 kHz.
    private let samples = (0..<400_000).map { Float(0.5 * sin(2 * Double.pi * 440 * Double($0) / 16_000)) }

    /// Every input the feed hands over, in order.
    private func drain(_ feed: AnalyzerFeed) -> [AnalyzerInput] {
        var inputs: [AnalyzerInput] = []
        while let next = feed.next() { inputs.append(next) }
        return inputs
    }

    /// `samples[range]` as a buffer in `input`.
    private func buffer(_ range: Range<Int>) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(range.count))!
        for (offset, index) in range.enumerated() { buffer.floatChannelData![0][offset] = samples[index] }
        buffer.frameLength = AVAudioFrameCount(range.count)
        return buffer
    }

    /// The recording through `converter` in the feed's 10 s pieces, then the flush.
    private func convertAll(
        with converter: AudioFormatConverter
    ) throws -> (pieces: [AVAudioPCMBuffer], flush: [AVAudioPCMBuffer]) {
        let pieces = try [0..<160_000, 160_000..<320_000, 320_000..<400_000].flatMap {
            try converter.converted(buffer($0))
        }
        return (pieces, try converter.flushed())
    }

    private func pcm(of buffers: [AVAudioPCMBuffer]) -> [Int16] {
        buffers.flatMap { Array(UnsafeBufferPointer(start: $0.int16ChannelData![0], count: Int($0.frameLength))) }
    }

    @Test func handsOverChunksInOrderThenTheFlush() {
        let converter = RecordingConverter()
        let feed = AnalyzerFeed(samples: samples, format: input, converter: converter)

        let inputs = drain(feed)

        #expect(converter.calls == ["convert 160000", "convert 160000", "convert 80000", "flush"])
        #expect(inputs.count == 4)
        #expect(feed.next() == nil)
        #expect(feed.error == nil)
    }

    @Test func stopsAtTheFirstConversionError() {
        let converter = RecordingConverter(failingAt: 2)
        let feed = AnalyzerFeed(samples: samples, format: input, converter: converter)

        let inputs = drain(feed)

        #expect(inputs.count == 1)
        #expect(converter.calls.count == 2)
        #expect(feed.error != nil)
    }

    @Test func resamplesTheWholeRecording() throws {
        let converted = try convertAll(with: AudioFormatConverter(from: input, to: output))

        let buffers = converted.pieces + converted.flush
        let frames = buffers.reduce(0) { $0 + Int($1.frameLength) }
        #expect(converted.pieces.count == 3)
        #expect(abs(frames - 3 * samples.count) <= 480)
        #expect(buffers.allSatisfy { $0.format == output })
    }

    @Test func feedsTheConvertedRecording() throws {
        let feed = AnalyzerFeed(
            samples: samples,
            format: input,
            converter: try AudioFormatConverter(from: input, to: output)
        )

        let inputs = drain(feed)

        #expect(inputs.count >= 3)
        #expect(feed.error == nil)
    }

    @Test func outputThatOverflowsABufferGoesIntoMore() throws {
        let roomy = try convertAll(with: AudioFormatConverter(from: input, to: output))
        // The flush holds a few hundred frames, more than this leaves room for.
        let tight = try convertAll(with: AudioFormatConverter(from: input, to: output, headroom: 256))

        #expect(tight.flush.count > roomy.flush.count)
        #expect(pcm(of: tight.pieces + tight.flush) == pcm(of: roomy.pieces + roomy.flush))
    }

    @Test func sameFormatPassesThrough() throws {
        let converter = try AudioFormatConverter(from: input, to: input)
        let piece = buffer(0..<1_000)

        #expect(try converter.converted(piece) == [piece])
        #expect(try converter.flushed().isEmpty)
    }
}

/// Logs what the feed asks of it, and answers each call with one short input.
private final class RecordingConverter: AnalyzerInputConverting {
    private struct ConversionError: Error {}

    private(set) var calls: [String] = []
    private let failingAt: Int?

    /// - Parameter failingAt: The call (1 for the first) that throws.
    init(failingAt: Int? = nil) {
        self.failingAt = failingAt
    }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> [AnalyzerInput] {
        try answer("convert \(buffer.frameLength)")
    }

    func flush() throws -> [AnalyzerInput] {
        try answer("flush")
    }

    private func answer(_ call: String) throws -> [AnalyzerInput] {
        calls.append(call)
        if calls.count == failingAt { throw ConversionError() }
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
        buffer.frameLength = 1
        return [AnalyzerInput(buffer: buffer)]
    }
}
