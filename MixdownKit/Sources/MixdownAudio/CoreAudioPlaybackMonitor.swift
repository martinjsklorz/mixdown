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
        return processes.contains { Self.isRunningOutput($0) && Self.processID(of: $0) != ownPID }
    }

    private static func isRunningOutput(_ objectID: AudioObjectID) -> Bool {
        var address = CoreAudioHAL.propertyAddress(kAudioProcessPropertyIsRunningOutput)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &running)
        return status == noErr && running != 0
    }

    private static func processID(of objectID: AudioObjectID) -> pid_t? {
        var address = CoreAudioHAL.propertyAddress(kAudioProcessPropertyPID)
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &pid) == noErr else { return nil }
        return pid
    }
}
