@preconcurrency import AVFoundation
import CoreAudio

/// The host clock (`mach_absolute_time`) in seconds, the timebase of `AudioChunk.hostTime`.
/// Core Audio stamps IO cycles on the same clock, which is what lets microphone and system
/// audio be lined up.
enum HostClock {
    /// When the first sample of an IO cycle was captured. A timestamp that's missing or far off
    /// the cycle's arrival means the host clock assumption broke, so fall back to the arrival time.
    static func captureTime(
        of cycle: CapturedCycle,
        frameCount: AVAudioFrameCount,
        sampleRate: Double
    ) -> TimeInterval {
        let arrival = AVAudioTime.seconds(forHostTime: cycle.arrivalHostTime) - Double(frameCount) / sampleRate
        guard let hostTime = cycle.hostTime else { return arrival }
        let stamped = AVAudioTime.seconds(forHostTime: hostTime)
        return abs(stamped - arrival) < 2 ? stamped : arrival
    }
}
