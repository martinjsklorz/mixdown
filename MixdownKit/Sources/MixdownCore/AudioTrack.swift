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

    /// Empty unless the track keeps its samples.
    public private(set) var samples: [Float] = []
    /// Host time of the first sample, if the first chunk carried one.
    public private(set) var startHostTime: TimeInterval?
    public private(set) var sampleCount = 0
    private let keepsSamples: Bool

    /// - Parameter keepsSamples: Whether to keep the audio, or only follow its timing, e.g. when
    ///   it's transcribed as it comes in.
    public init(keepsSamples: Bool = true) {
        self.keepsSamples = keepsSamples
    }

    public var duration: TimeInterval { Double(sampleCount) / AudioChunk.sampleRate }

    /// Adds `chunk` and returns the samples it added: silence filling a gap before it, if any,
    /// then its own.
    @discardableResult
    public mutating func append(_ chunk: AudioChunk) -> [Float] {
        var added: [Float] = []
        if let hostTime = chunk.hostTime {
            if sampleCount == 0 {
                startHostTime = hostTime
            } else if let startHostTime {
                let gap = hostTime - (startHostTime + duration)
                if gap > Self.gapTolerance {
                    added = Array(repeating: 0, count: Int((gap * AudioChunk.sampleRate).rounded()))
                }
            }
        }
        added.append(contentsOf: chunk.samples)
        sampleCount += added.count
        if keepsSamples { samples.append(contentsOf: added) }
        return added
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
