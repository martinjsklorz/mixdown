import CoreAudio
import Foundation
import MixdownCore

/// Tells whether other apps play audio, from the HAL's process objects
/// (`kAudioProcessPropertyIsRunningOutput`).
public struct CoreAudioPlaybackMonitor: AudioPlaybackMonitoring {
    public init() {}

    /// Async so the HAL queries run off the main actor.
    public func isOtherAudioPlaying() async -> Bool {
        guard let processes = try? CoreAudioHAL.allProcessObjectIDs() else {
            // Can't tell, so silence from system audio is worth a warning.
            return true
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return processes.contains {
            CoreAudioHAL.boolProperty(kAudioProcessPropertyIsRunningOutput, of: $0)
                && CoreAudioHAL.processID(of: $0) != ownPID
        }
    }
}
