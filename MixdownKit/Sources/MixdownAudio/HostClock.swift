@preconcurrency import AVFoundation

/// The host clock (`mach_absolute_time`) in seconds, the timebase of `AudioChunk.hostTime`.
/// AVAudioEngine tap times and ScreenCaptureKit sample buffers are stamped on the same clock,
/// which is what lets microphone and system audio be lined up.
enum HostClock {
    static func now() -> TimeInterval {
        AVAudioTime.seconds(forHostTime: mach_absolute_time())
    }
}
