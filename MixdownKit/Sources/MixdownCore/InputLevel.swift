import Foundation

/// How loud one input was over the last metering interval. Drives the level meters and the
/// silent-input warning.
public struct InputLevel: Sendable, Equatable {
    /// Peaks at or below this (-80 dBFS) count as silence. A real microphone hisses above it; a
    /// muted input, or a system audio tap without permission, delivers exact zeros.
    static let silenceThreshold: Float = 0.0001

    /// Loudest sample magnitude in the interval, 0...1.
    public let peak: Float

    public init(peak: Float) {
        self.peak = peak
    }

    public var isSilent: Bool { peak <= Self.silenceThreshold }

    /// Position on a meter running from -60 dBFS (0) to full scale (1).
    public var meterValue: Double {
        guard peak > 0 else { return 0 }
        let decibels = 20 * log10(Double(min(peak, 1)))
        return max(0, 1 + decibels / 60)
    }
}

/// Folds captured chunks into one `InputLevel` per `interval` of audio, so the UI updates at a
/// steady, low rate however the capture slices its chunks.
struct LevelMeter: Sendable {
    static let interval: TimeInterval = 0.1

    private var peak: Float = 0
    private var pending: TimeInterval = 0

    /// Returns the level once `interval` of audio has accumulated since the last one, else `nil`.
    mutating func add(_ chunk: AudioChunk) -> InputLevel? {
        for sample in chunk.samples {
            peak = max(peak, abs(sample))
        }
        pending += chunk.duration
        guard pending >= Self.interval else { return nil }
        let level = InputLevel(peak: peak)
        peak = 0
        pending = 0
        return level
    }
}
