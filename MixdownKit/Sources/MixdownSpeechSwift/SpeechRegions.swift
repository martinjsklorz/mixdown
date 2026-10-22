import Foundation

/// Turns per-frame VAD speech probabilities into speech regions. Pure; no model types involved.
///
/// The same hysteresis as speech-swift's `VADPipeline.binarize`, but short pauses are bridged
/// before short regions are dropped. `binarize` drops first, so a short reply like "Yes." that
/// dips once in the middle becomes two bursts that are each too short, and vanishes.
enum SpeechRegions {
    struct Configuration: Equatable, Sendable {
        /// Speech starts at the first frame at or above this probability…
        var onset: Float
        /// …and ends at the first frame below this one.
        var offset: Float
        /// Pauses shorter than this are kept inside the region.
        var minSilenceDuration: TimeInterval
        /// Regions shorter than this, after bridging pauses, are dropped as noise.
        var minSpeechDuration: TimeInterval

        /// `VADConfig.sileroDefault`, except that it keeps speech from 0.1 s rather than 0.25 s:
        /// a clipped "Yes." or "No." can be shorter than that above the thresholds.
        static let silero = Configuration(onset: 0.5, offset: 0.35, minSilenceDuration: 0.1, minSpeechDuration: 0.1)
    }

    static func detect(in probabilities: [Float], frameDuration: TimeInterval) -> [TimeSpan] {
        let configuration = Configuration.silero
        var raw: [TimeSpan] = []
        var start: Int?
        for (index, probability) in probabilities.enumerated() {
            if let speechStart = start {
                if probability < configuration.offset {
                    raw.append(TimeSpan(start: Double(speechStart) * frameDuration, end: Double(index) * frameDuration))
                    start = nil
                }
            } else if probability >= configuration.onset {
                start = index
            }
        }
        if let start {
            raw.append(TimeSpan(start: Double(start) * frameDuration, end: Double(probabilities.count) * frameDuration))
        }

        var bridged: [TimeSpan] = []
        for region in raw {
            if let last = bridged.last, region.start - last.end < configuration.minSilenceDuration {
                bridged[bridged.count - 1].end = region.end
            } else {
                bridged.append(region)
            }
        }
        return bridged.filter { $0.duration >= configuration.minSpeechDuration }
    }
}
