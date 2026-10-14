@preconcurrency internal import AudioCommon
import Foundation
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

    static let repositoryID = SileroVADModel.defaultCoreMLModelId

    static func load(cacheBase: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> VoiceActivityDetector {
        let directory = try ModelCache.directory(for: repositoryID, base: cacheBase)
        let model = try await ModelCache.loadPreferringCache(
            repositoryID,
            cacheLooksComplete: cacheLooksComplete(in: directory),
            progress: progress
        ) { offline, progress in
            try await SileroVADModel.fromPretrained(
                engine: .coreml,
                cacheDir: directory,
                offlineMode: offline,
                progressHandler: { fraction, _ in progress(fraction) }
            )
        }
        return VoiceActivityDetector(model: model)
    }

    static func cacheLooksComplete(in directory: URL) -> Bool {
        ModelCache.contains(weightsAnd: ["silero_vad.mlmodelc"], in: directory)
    }

    /// Same computation as `SileroVADModel.detectSpeech(audio:sampleRate:config:)` (512-sample frames, last
    /// one zero-padded, `VADConfig.sileroDefault` hysteresis), but it keeps the per-frame probabilities and
    /// checks for cancellation as it goes.
    func detect(_ samples: [Float]) throws -> Detection {
        let frameSize = SileroVADModel.chunkSize
        model.resetState()
        defer { model.resetState() }

        var probabilities: [Float] = []
        probabilities.reserveCapacity(samples.count / frameSize + 1)
        var frame = [Float](repeating: 0, count: frameSize)
        var offset = 0
        while offset < samples.count {
            // Every 1024 frames ≈ 33 s of audio.
            if probabilities.count % 1024 == 0 { try Task.checkCancellation() }
            let end = min(offset + frameSize, samples.count)
            frame.withUnsafeMutableBufferPointer { buffer in
                for index in 0..<frameSize {
                    buffer[index] = offset + index < end ? samples[offset + index] : 0
                }
            }
            probabilities.append(model.processChunk(frame))
            offset = end
        }
        guard !probabilities.isEmpty else { return Detection(regions: [], probabilities: []) }

        let defaults = VADConfig.sileroDefault
        let pipeline = VADPipeline(
            config: VADConfig(
                onset: defaults.onset,
                offset: defaults.offset,
                minSpeechDuration: defaults.minSpeechDuration,
                minSilenceDuration: defaults.minSilenceDuration,
                // Makes `VADPipeline.frameDuration` equal one Silero frame.
                windowDuration: Float(Double(probabilities.count) * Self.frameDuration),
                stepRatio: 1
            ),
            sampleRate: SileroVADModel.sampleRate,
            framesPerChunk: probabilities.count
        )
        let regions = pipeline.binarize(probs: probabilities).map {
            TimeSpan(start: TimeInterval($0.startTime), end: TimeInterval($0.endTime))
        }
        return Detection(regions: regions, probabilities: probabilities)
    }
}
