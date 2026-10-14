import Foundation

/// One source's audio from a recording, kept in step with the host clock.
///
/// Sources start at slightly different moments, and some deliver nothing while they're silent
/// (a microphone can drop out mid-recording). Chunks that carry a `hostTime`
/// therefore aren't simply concatenated: a gap in the timestamps is filled with silence, and
/// `startHostTime` lets `startOffsets(of:)` line several tracks up against each other.
public struct AudioTrack: Sendable, Equatable {
    /// Gaps shorter than this are treated as timestamp jitter, not missing audio.
    static let gapTolerance: TimeInterval = 0.2

    public private(set) var samples: [Float] = []
    /// Host time of the first sample, if the first chunk carried one.
    public private(set) var startHostTime: TimeInterval?

    public init() {}

    public var duration: TimeInterval { Double(samples.count) / AudioChunk.sampleRate }

    public mutating func append(_ chunk: AudioChunk) {
        if let hostTime = chunk.hostTime {
            if samples.isEmpty {
                startHostTime = hostTime
            } else if let startHostTime {
                let gap = hostTime - (startHostTime + duration)
                if gap > Self.gapTolerance {
                    samples.append(contentsOf: repeatElement(0, count: Int((gap * AudioChunk.sampleRate).rounded())))
                }
            }
        }
        samples.append(contentsOf: chunk.samples)
    }

    /// Seconds from the earliest track's first sample to each track's first sample. Tracks
    /// without a host time start at 0.
    public static func startOffsets(of tracks: [AudioTrack]) -> [TimeInterval] {
        guard let earliest = tracks.compactMap(\.startHostTime).min() else {
            return tracks.map { _ in 0 }
        }
        return tracks.map { track in track.startHostTime.map { max(0, $0 - earliest) } ?? 0 }
    }
}
