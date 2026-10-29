import CoreAudio
import MixdownCore
import Testing

@testable import MixdownAudio

struct CoreAudioHALTests {
    @Test func describesFourCharacterCodes() {
        #expect(CoreAudioHAL.describe(kAudioHardwareBadDeviceError) == "'!dev'")
        #expect(CoreAudioHAL.describe(kAudioHardwareUnspecifiedError) == "'what'")
    }

    @Test func describesOtherStatusesAsNumbers() {
        #expect(CoreAudioHAL.describe(-50) == "-50")
        #expect(CoreAudioHAL.describe(1) == "1")
    }

    @Test func passesSuccess() throws {
        try CoreAudioHAL.check(noErr, "start “Headset”", deviceName: "Headset")
    }

    @Test(arguments: [kAudioHardwareBadDeviceError, kAudioHardwareBadObjectError])
    func reportsAVanishedDeviceAsNotFound(status: OSStatus) {
        #expect(throws: AudioCaptureError.deviceNotFound("Headset")) {
            try CoreAudioHAL.check(status, "start “Headset”", deviceName: "Headset")
        }
    }

    @Test func reportsOtherFailuresAsUnavailable() {
        #expect(throws: AudioCaptureError.deviceUnavailable("Couldn't start “Headset” (OSStatus 'what')")) {
            try CoreAudioHAL.check(kAudioHardwareUnspecifiedError, "start “Headset”", deviceName: "Headset")
        }
        // Without a device to blame, even a bad device is only unavailable.
        #expect(throws: AudioCaptureError.deviceUnavailable("Couldn't create the system audio tap (OSStatus '!dev')")) {
            try CoreAudioHAL.check(kAudioHardwareBadDeviceError, "create the system audio tap")
        }
    }
}
