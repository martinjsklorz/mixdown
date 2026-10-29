@preconcurrency import AVFoundation
import Foundation
import MixdownCore
import Speech

/// Hands a recording to the analyzer `chunkDuration` at a time, converted to the analyzer's
/// format. Only used from the input stream's `unfolding` closure, which runs one call at a time.
final class AnalyzerFeed: @unchecked Sendable {
    /// Audio handed to the analyzer at a time.
    static let chunkDuration: TimeInterval = 10

    private let samples: [Float]
    private let format: AVAudioFormat
    private let converter: any AnalyzerInputConverting
    private var position = 0
    /// Converted audio not handed over yet. A piece can convert into several inputs, or none.
    private var pending: [AnalyzerInput] = []
    private var isFlushed = false
    /// Why the feed ended early, if it did.
    private(set) var error: (any Error)?

    init(samples: [Float], format: AVAudioFormat, converter: any AnalyzerInputConverting) {
        self.samples = samples
        self.format = format
        self.converter = converter
    }

    /// The next piece of audio, or `nil` once all of it has been handed over or conversion failed.
    func next() -> AnalyzerInput? {
        while pending.isEmpty, !isFlushed, error == nil {
            do {
                if position < samples.count {
                    pending = try converter.convert(nextBuffer())
                } else {
                    // Whatever the converter held back.
                    pending = try converter.flush()
                    isFlushed = true
                }
            } catch {
                self.error = error
            }
        }
        return pending.isEmpty ? nil : pending.removeFirst()
    }

    private func nextBuffer() throws -> AVAudioPCMBuffer {
        let count = min(Int(Self.chunkDuration * format.sampleRate), samples.count - position)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
            let channel = buffer.floatChannelData?[0]
        else {
            throw TranscriptionError.failed("Out of memory for audio")
        }
        samples[position..<position + count].withUnsafeBufferPointer { piece in
            if let base = piece.baseAddress { channel.update(from: base, count: count) }
        }
        buffer.frameLength = AVAudioFrameCount(count)
        position += count
        return buffer
    }
}

/// Turns pieces of a recording into analyzer input, in order.
protocol AnalyzerInputConverting {
    func convert(_ buffer: AVAudioPCMBuffer) throws -> [AnalyzerInput]
    /// Whatever the converter held back, after the last piece.
    func flush() throws -> [AnalyzerInput]
}

@available(macOS 27, *)
extension AnalyzerInputConverter: AnalyzerInputConverting {
    func convert(_ buffer: AVAudioPCMBuffer) throws -> [AnalyzerInput] {
        try convert(buffer, at: nil)
    }
}

/// `AVAudioConverter` in place of `AnalyzerInputConverter`, which macOS 26 doesn't have.
final class AudioFormatConverter: AnalyzerInputConverting {
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    /// `nil` when the analyzer takes the audio as it is.
    private let converter: AVAudioConverter?
    private let headroom: AVAudioFrameCount

    /// - Parameter headroom: Room in each output buffer for samples the converter held back from
    ///   earlier pieces. Output that doesn't fit goes into further buffers.
    init(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat, headroom: AVAudioFrameCount = 1024) throws {
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.headroom = max(headroom, 1)
        if inputFormat == outputFormat {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw TranscriptionError.failed("Can't convert audio to \(outputFormat) for Apple's speech model")
            }
            // Without priming, the converted audio isn't shifted, so the segments' times stay right.
            converter.primeMethod = .none
            self.converter = converter
        }
    }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> [AnalyzerInput] {
        try converted(buffer).map { AnalyzerInput(buffer: $0) }
    }

    func flush() throws -> [AnalyzerInput] {
        try flushed().map { AnalyzerInput(buffer: $0) }
    }

    /// `buffer` in the output format, in as many buffers as it takes.
    func converted(_ buffer: AVAudioPCMBuffer) throws -> [AVAudioPCMBuffer] {
        guard let converter else { return [buffer] }
        return try run(converter, on: buffer, frames: buffer.frameLength)
    }

    /// Whatever the converter held back, after the last piece.
    func flushed() throws -> [AVAudioPCMBuffer] {
        guard let converter else { return [] }
        return try run(converter, on: nil, frames: 0)
    }

    /// Converts `buffer`, or with `nil` ends the stream so the converter hands over what it held back.
    private func run(
        _ converter: AVAudioConverter,
        on buffer: AVAudioPCMBuffer?,
        frames: AVAudioFrameCount
    ) throws
        -> [AVAudioPCMBuffer]
    {
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(frames) * ratio).rounded(.up)) + headroom
        // Hand the piece over once, then say more may come (or, flushing, that none will), so the
        // converter keeps its state between pieces.
        let pending = PendingBuffer(buffer)
        let isFlushing = buffer == nil
        var outputs: [AVAudioPCMBuffer] = []
        // `.haveData` means the output buffer filled up before the converter ran out, so go on
        // into another one.
        var status = AVAudioConverterOutputStatus.haveData
        while status == .haveData {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
                throw TranscriptionError.failed("Out of memory for audio")
            }
            var conversionError: NSError?
            status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                if let buffer = pending.take() {
                    inputStatus.pointee = .haveData
                    return buffer
                }
                inputStatus.pointee = isFlushing ? .endOfStream : .noDataNow
                return nil
            }
            if status == .error {
                throw TranscriptionError.failed(conversionError?.localizedDescription ?? "Audio conversion failed")
            }
            guard output.frameLength > 0 else { break }
            outputs.append(output)
        }
        return outputs
    }
}

/// One-shot holder for the converter's input block, which runs synchronously inside `convert`.
private final class PendingBuffer: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer?) {
        self.buffer = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}
