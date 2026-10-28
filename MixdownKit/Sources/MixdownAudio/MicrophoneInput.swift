@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import MixdownCore
import os

/// A specific Core Audio input device, recorded through an IO proc on the device itself, plus
/// listeners that keep its format current and notice when the device goes away or stops being
/// an input, or the audio service restarts.
///
/// Not `AVAudioEngine`: pointing the engine's input unit at a Bluetooth headset such as AirPods
/// left it running without delivering any audio, while the built-in microphone worked. Opening
/// the headset's input switches it to its call profile at a lower sample rate, and the engine
/// most likely kept the format from before the switch. An IO proc follows the device's format.
///
/// `@unchecked Sendable`: `start` and `invalidate` are called one after another on
/// `IOProcCapture`'s control queue, never concurrently; `formats` and `lifecycle` are safe from
/// the listener and IO threads.
final class MicrophoneInput: CaptureSource, @unchecked Sendable {
    /// How long a device may be without input streams before it counts as gone. A Bluetooth
    /// headset can drop them for a moment while it switches profiles.
    private static let lostInputGracePeriod: DispatchTimeInterval = .seconds(1)

    let formats = FormatHistory()
    private let lifecycle = CaptureSourceLifecycle()
    private let device: AudioInputDevice
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var listeners: [HALPropertyListener] = []

    init(device: AudioInputDevice) {
        self.device = device
    }

    deinit { invalidate() }

    var logName: String { "Microphone capture on “\(device.name)”" }

    func prepare() async throws {
        switch AudioPermissions.microphoneStatus() {
        case .granted:
            return
        case .denied:
            throw AudioCaptureError.microphonePermissionDenied
        case .notDetermined:
            guard await AudioPermissions.requestMicrophoneAccess() else {
                throw AudioCaptureError.microphonePermissionDenied
            }
        }
    }

    func start(into ring: CaptureRing, onFailure: @escaping @Sendable (AudioCaptureError) -> Void) throws {
        let name = device.name
        guard let deviceID = try CoreAudioHAL.deviceID(forUID: device.id) else {
            throw AudioCaptureError.deviceNotFound(name)
        }
        self.deviceID = deviceID

        guard let initialFormat = CoreAudioHAL.inputFormat(of: deviceID) else {
            throw AudioCaptureError.deviceUnavailable("“\(name)” has no usable input channels")
        }
        formats.update(initialFormat)

        let onChange: @Sendable () -> Void = { [weak self] in
            self?.deviceChanged(deviceID, onFailure: onFailure)
        }
        lifecycle.setFormatCheck(onChange)
        listeners = [
            HALPropertyListener(
                objectID: deviceID,
                selectors: [
                    kAudioDevicePropertyDeviceIsAlive,
                    kAudioDevicePropertyNominalSampleRate,
                    kAudioDevicePropertyStreams,
                    kAudioDevicePropertyStreamConfiguration,
                ],
                scope: kAudioObjectPropertyScopeWildcard,
                queue: lifecycle.listenerQueue,
                onChange: onChange
            ),
            lifecycle.serviceRestartListener(onFailure: onFailure),
        ]
        listeners.forEach { $0.install() }

        // No queue: the block runs right on the IO thread, which it never blocks.
        let block = IOProcCapture.ioBlock(writingTo: ring, formats: formats)
        try CoreAudioHAL.check(
            AudioDeviceCreateIOProcIDWithBlock(&ioProcID, deviceID, nil, block),
            "read from “\(name)”",
            deviceName: name
        )
        try CoreAudioHAL.check(AudioDeviceStart(deviceID, ioProcID), "start “\(name)”", deviceName: name)
    }

    func refreshFormat() {
        lifecycle.checkFormat()
    }

    func invalidate() {
        // After a restart of the audio service, the IO proc is gone and the device ID may belong
        // to another device, so it's only forgotten.
        let ownsObjects = lifecycle.invalidate()
        listeners.forEach { $0.remove(logsFailures: false) }
        listeners = []
        if ownsObjects, deviceID != AudioObjectID(kAudioObjectUnknown), let ioProcID {
            CoreAudioHAL.logFailure(AudioDeviceStop(deviceID, ioProcID), "AudioDeviceStop")
            CoreAudioHAL.logFailure(AudioDeviceDestroyIOProcID(deviceID, ioProcID), "AudioDeviceDestroyIOProcID")
        }
        ioProcID = nil
        deviceID = AudioObjectID(kAudioObjectUnknown)
    }

    /// A Bluetooth headset changes sample rate and streams when its microphone opens, an
    /// unplugged device stops being alive, and a device can lose its input streams while staying
    /// connected, which leaves the IO proc running without audio.
    private func deviceChanged(_ deviceID: AudioDeviceID, onFailure: @escaping @Sendable (AudioCaptureError) -> Void) {
        let name = device.name
        guard CoreAudioHAL.isAlive(deviceID) else {
            onFailure(.deviceNotFound(name))
            return
        }
        guard let newFormat = CoreAudioHAL.inputFormat(of: deviceID) else {
            let deadline = DispatchTime.now() + Self.lostInputGracePeriod
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: deadline) { [lifecycle] in
                // A capture that has stopped in the meantime ignores the failure.
                guard lifecycle.isLive, CoreAudioHAL.inputFormat(of: deviceID) == nil else { return }
                audioLogger.error("“\(name, privacy: .public)” has no input streams anymore")
                onFailure(.deviceNotFound(name))
            }
            return
        }
        if formats.update(newFormat) {
            audioLogger.info("“\(name, privacy: .public)” switched to \(newFormat, privacy: .public)")
        }
    }
}
