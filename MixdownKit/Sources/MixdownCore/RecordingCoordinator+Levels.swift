import Foundation
import os

extension RecordingCoordinator {
    /// Shows `level` for the device, and adds `speech` seconds heard since its last level to
    /// `talkTime`.
    func updateLevel(
        _ level: InputLevel,
        speech: TimeInterval,
        of deviceID: String,
        kind: AudioSourceKind,
        sessionID: UUID
    ) {
        // Levels still in flight when the recording ends or the device is switched off are dropped.
        guard let session, session.id == sessionID, session.activeDevices.contains(where: { $0.id == deviceID })
        else { return }
        inputLevels[deviceID] = level
        if speech > 0 { talkTime?.add(speech, from: kind) }
        if !level.isSilent, heardDeviceIDs.insert(deviceID).inserted {
            silenceChecks.removeValue(forKey: deviceID)?.cancel()
            silentDevices.removeAll { $0.id == deviceID }
        }
    }

    /// Lists `device` in `silentDevices` if it's still recording but hasn't been heard once
    /// `silenceWarningDelay` has passed. For system audio, only the time other apps play audio
    /// counts, so a recording with nothing playing isn't flagged.
    func scheduleSilenceCheck(of device: AudioInputDevice, in session: Session) {
        silenceChecks[device.id]?.cancel()
        let playbackMonitor = device.kind == .systemAudio ? playbackMonitor : nil
        silenceChecks[device.id] = Task { [weak self, silenceWarningDelay] in
            let step = silenceWarningDelay / 10
            var silentFor = Duration.zero
            while silentFor < silenceWarningDelay {
                try? await Task.sleep(for: step)
                guard !Task.isCancelled else { return }
                if await playbackMonitor?.isOtherAudioPlaying() ?? true {
                    silentFor += step
                }
            }
            guard !Task.isCancelled else { return }
            self?.flagIfSilent(device, in: session)
        }
    }

    private func flagIfSilent(_ device: AudioInputDevice, in session: Session) {
        guard self.session === session, session.activeDevices.contains(where: { $0.id == device.id }),
            !heardDeviceIDs.contains(device.id), !silentDevices.contains(where: { $0.id == device.id })
        else { return }
        silentDevices.append(device)
        logger.info("No sound yet from \(device.name, privacy: .public)")
    }

    /// Forgets the level of a device the recording no longer records from.
    func clearLevel(of device: AudioInputDevice) {
        silenceChecks.removeValue(forKey: device.id)?.cancel()
        inputLevels[device.id] = nil
        silentDevices.removeAll { $0.id == device.id }
    }

    func resetLevels() {
        silenceChecks.values.forEach { $0.cancel() }
        silenceChecks = [:]
        heardDeviceIDs = []
        inputLevels = [:]
        silentDevices = []
        talkTime = nil
    }
}
