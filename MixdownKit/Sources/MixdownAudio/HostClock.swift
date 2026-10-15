@preconcurrency import AVFoundation
import CoreAudio

/// The host clock (`mach_absolute_time`) in seconds, the timebase of `AudioChunk.hostTime`.
/// Core Audio stamps IO cycles on the same clock, which is what lets microphone and system
/// audio be lined up.
enum HostClock {
    static func now() -> TimeInterval {
        AVAudioTime.seconds(forHostTime: mach_absolute_time())
    }

    /// When the first sample of an IO buffer was captured. A timestamp that's missing or far off
    /// "now" means the host clock assumption broke, so fall back to the arrival time.
    static func captureTime(of time: AudioTimeStamp, buffer: AVAudioPCMBuffer) -> TimeInterval {
        let arrival = now() - Double(buffer.frameLength) / buffer.format.sampleRate
        guard time.mFlags.contains(.hostTimeValid) else { return arrival }
        let stamped = AVAudioTime.seconds(forHostTime: time.mHostTime)
        return abs(stamped - arrival) < 2 ? stamped : arrival
    }
}
