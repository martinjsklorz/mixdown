@preconcurrency internal import AudioCommon
import Foundation
import MixdownCore
@preconcurrency internal import SpeechVAD

/// Silero VAD over a whole recording.
///
/// Uses the Core ML backend (Neural Engine): ~0.06 ms per 32 ms frame vs ~0.5 ms on MLX, i.e. seconds
/// rather than about a minute for an hour of audio, and it leaves the GPU to the ASR model.
final class VoiceActivityDetector: @unchecked Sendable {
    struct Detection {
        var regions: [TimeSpan]
        /// One speech probability per `frameDuration`, used to pick split points.
        var probabilities: [Float]
    }

    static let frameDuration = Double(SileroVADModel.chunkSize) / Double(SileroVADModel.sampleRate)

    private let model: SileroVADModel

    private init(model: SileroVADModel) {
        self.model = model
    }

    static let cachedModel = CachedModel(
        repositoryID: SileroVADModel.defaultCoreMLModelId,
        requiredFiles: ["silero_vad.mlmodelc"]
    )

    static func load(
        cacheBase: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> VoiceActivityDetector {
        let model = try await cachedModel.load(base: cacheBase, progress: progress) { directory, offline, progress in
            try await SileroVADModel.fromPretrained(
                engine: .coreml,
                cacheDir: directory,
                offlineMode: offline,
                progressHandler: { fraction, _ in progress(fraction) }
            )
        }
        return VoiceActivityDetector(model: model)
    }

    /// Same frames as `SileroVADModel.detectSpeech(audio:sampleRate:config:)` (512 samples, last one
    /// zero-padded), but it keeps the per-frame probabilities, checks for cancellation and reports
    /// progress as it goes, and finds regions with `SpeechRegions` so short replies survive.
    func detect(_ samples: [Float], progress: (Double) -> Void) throws -> Detection {
        let frameSize = SileroVADModel.chunkSize
        model.resetState()
        defer { model.resetState() }

        var probabilities: [Float] = []
        probabilities.reserveCapacity(samples.count / frameSize + 1)
        var frame = [Float](repeating: 0, count: frameSize)
        var offset = 0
        while offset < samples.count {
            // Every 1024 frames ≈ 33 s of audio.
            if probabilities.count % 1024 == 0 {
                try Task.checkCancellation()
                progress(Double(offset) / Double(samples.count))
            }
            let end = min(offset + frameSize, samples.count)
            frame.withUnsafeMutableBufferPointer { buffer in
                for index in 0..<frameSize {
                    buffer[index] = offset + index < end ? samples[offset + index] : 0
                }
            }
            probabilities.append(model.processChunk(frame))
            offset = end
        }
        progress(1)
        let regions = SpeechRegions.detect(in: probabilities, frameDuration: Self.frameDuration)
        return Detection(regions: regions, probabilities: probabilities)
    }
}
