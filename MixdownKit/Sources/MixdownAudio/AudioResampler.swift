@preconcurrency import AVFoundation
import MixdownCore
import os

/// Turns PCM buffers of any layout and sample rate into 16 kHz mono `AudioChunk`s.
///
/// Channels are averaged into mono at the source rate first (works for any channel count and
/// sample format without relying on channel layouts), then `AVAudioConverter` does the sample-rate
/// conversion. Not thread-safe: each capture feeds it from a single serial callback context.
final class AudioResampler {
    private let targetFormat: AVAudioFormat
    private var sourceFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    init() throws {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: AudioChunk.sampleRate,
                channels: 1,
                interleaved: false
            )
        else {
            throw AudioCaptureError.deviceUnavailable("Couldn't create the 16 kHz output format")
        }
        targetFormat = format
    }

    /// Converts one buffer. `hostTime` (see `AudioChunk.hostTime`) is passed through.
    func process(_ buffer: AVAudioPCMBuffer, hostTime: TimeInterval?) -> AudioChunk? {
        guard buffer.frameLength > 0, let mono = downmix(buffer) else { return nil }

        let samples: [Float]
        if mono.format.sampleRate == AudioChunk.sampleRate {
            samples = Self.samples(of: mono)
        } else {
            guard let resampled = resample(mono) else { return nil }
            samples = resampled
        }
        guard !samples.isEmpty else { return nil }

        return AudioChunk(samples: samples, hostTime: hostTime)
    }

    // MARK: - Downmix

    /// Averages all channels into a mono Float32 buffer at the source sample rate.
    private func downmix(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let sampleRate = buffer.format.sampleRate
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        guard sampleRate > 0, channels > 0 else { return nil }

        let format: AVAudioFormat
        if let sourceFormat, sourceFormat.sampleRate == sampleRate {
            format = sourceFormat
        } else {
            guard
                let newFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: sampleRate,
                    channels: 1,
                    interleaved: false
                )
            else { return nil }
            format = newFormat
        }

        guard let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
            let output = mono.floatChannelData?[0]
        else { return nil }
        mono.frameLength = buffer.frameLength
        output.update(repeating: 0, count: frames)

        if let data = buffer.floatChannelData {
            Self.mix(data, of: buffer, into: output, scale: 1) { $0 }
        } else if let data = buffer.int16ChannelData {
            Self.mix(data, of: buffer, into: output, scale: 1 / 32_768) { Float($0) }
        } else if let data = buffer.int32ChannelData {
            Self.mix(data, of: buffer, into: output, scale: 1 / 2_147_483_648) { Float($0) }
        } else {
            audioLogger.error("Unsupported capture sample format: \(buffer.format, privacy: .public)")
            return nil
        }
        return mono
    }

    /// Sums every channel of `buffer` into `output`, then scales by `scale / channelCount`.
    private static func mix<Sample>(
        _ data: UnsafePointer<UnsafeMutablePointer<Sample>>,
        of buffer: AVAudioPCMBuffer,
        into output: UnsafeMutablePointer<Float>,
        scale: Float,
        convert: (Sample) -> Float
    ) {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let interleaved = buffer.format.isInterleaved
        let stride = buffer.stride

        for channel in 0..<channels {
            // Interleaved buffers expose a single pointer; channels are offset within each frame.
            let base = interleaved ? data[0] + channel : data[channel]
            for frame in 0..<frames {
                output[frame] += convert(base[frame * stride])
            }
        }

        let gain = scale / Float(channels)
        guard gain != 1 else { return }
        for frame in 0..<frames {
            output[frame] *= gain
        }
    }

    // MARK: - Sample-rate conversion

    private func resample(_ mono: AVAudioPCMBuffer) -> [Float]? {
        let format = mono.format
        if converter == nil || sourceFormat?.sampleRate != format.sampleRate {
            guard let newConverter = AVAudioConverter(from: format, to: targetFormat) else {
                audioLogger.error("Couldn't create converter from \(format.sampleRate, privacy: .public) Hz")
                return nil
            }
            newConverter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            converter = newConverter
            sourceFormat = format
        }
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / format.sampleRate
        // Headroom for samples the converter held back from the previous call.
        let capacity = AVAudioFrameCount((Double(mono.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        // Hand the buffer over exactly once, then report `.noDataNow` so the converter keeps its
        // filter state for the next buffer instead of flushing as if the stream had ended.
        let feed = ConverterFeed(mono)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            guard let buffer = feed.take() else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return buffer
        }

        if status == .error {
            let reason = error?.localizedDescription ?? "unknown error"
            audioLogger.error("Audio conversion failed: \(reason, privacy: .public)")
            return nil
        }
        return Self.samples(of: output)
    }

    private static func samples(of buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    }
}

/// One-shot holder for the converter's input block, which runs synchronously inside `convert`.
private final class ConverterFeed: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}
