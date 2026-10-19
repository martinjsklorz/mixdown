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
    private var sampleCount = 0
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
        var added = [Float](repeating: 0, count: gap(before: chunk.hostTime))
        added.append(contentsOf: chunk.samples)
        sampleCount += added.count
        if keepsSamples { samples.append(contentsOf: added) }
        return added
    }

    /// Appends a later recording of the same source, e.g. from the device it switched to, with
    /// the time between the two filled with silence. Both should keep their samples, or neither.
    public mutating func append(_ track: AudioTrack) {
        guard track.sampleCount > 0 else { return }
        let silence = gap(before: track.startHostTime)
        sampleCount += silence + track.sampleCount
        if keepsSamples {
            samples.append(contentsOf: repeatElement(0, count: silence))
            samples.append(contentsOf: track.samples)
        }
    }

    /// Samples of silence that fill the time between the track's end and audio starting at
    /// `hostTime`. Records `hostTime` as the start of an empty track.
    private mutating func gap(before hostTime: TimeInterval?) -> Int {
        guard let hostTime else { return 0 }
        guard sampleCount > 0 else {
            startHostTime = hostTime
            return 0
        }
        guard let startHostTime else { return 0 }
        let gap = hostTime - (startHostTime + duration)
        return gap > Self.gapTolerance ? Int((gap * AudioChunk.sampleRate).rounded()) : 0
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
