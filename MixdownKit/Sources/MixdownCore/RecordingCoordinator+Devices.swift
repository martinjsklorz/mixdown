import Foundation

extension RecordingCoordinator {
    /// Selects the devices to record and remembers them as preferred. While recording, the
    /// recording switches to them. Ignored while the recording starts, and for an empty list.
    /// Returns whether the selection was applied.
    @discardableResult
    public func selectDevices(_ selection: [AudioInputDevice]) -> Bool {
        guard !isStartingCapture, !selection.isEmpty else { return false }
        preferredDeviceIDs = selection.map(\.id)
        // Choosing a device that went away mid-recording tries it again, and so does choosing
        // System Default for the default microphone.
        if let session {
            session.unavailableDeviceIDs.subtract(preferredDeviceIDs)
            if followsDefaultMicrophone, let defaultMicrophone = Self.defaultMicrophone(in: devices) {
                session.unavailableDeviceIDs.remove(defaultMicrophone.id)
            }
        }
        // Devices that vanished since the menu was drawn are resolved like any other missing one.
        reconcileSelection()
        return true
    }

    /// Loads the device list, then follows changes until the calling task is cancelled.
    public func monitorDevices() async {
        // Subscribe first so a change during the initial load isn't missed.
        let updates = deviceProvider.deviceUpdates()
        applyDevices(await deviceProvider.availableDevices())
        for await list in updates {
            applyDevices(list)
        }
    }

    func applyDevices(_ list: [AudioInputDevice]) {
        devices = list
        // A device that went away and comes back may be recorded from again.
        session?.unavailableDeviceIDs.formIntersection(list.map(\.id))
        reconcileSelection()
    }

    /// Re-resolves the selection against `devices` and, while recording, switches the recording
    /// to it. That's how a recording follows a microphone being unplugged or plugged back in.
    func reconcileSelection() {
        guard !isStartingCapture else { return }
        guard let session else {
            let resolved = Self.resolveSelection(preferredIDs: preferredDeviceIDs, in: devices)
            if resolved != selectedDevices {
                selectedDevices = resolved
            }
            return
        }

        let available = devices.filter { !session.unavailableDeviceIDs.contains($0.id) }
        let resolved = Self.resolveSelection(
            preferredIDs: preferredDeviceIDs,
            in: available,
            fallsBackToAnyDevice: false
        )
        // With nothing left to switch to, the recording ends once its last input does.
        if !resolved.isEmpty, resolved != selectedDevices {
            selectedDevices = resolved
        }
        // A paused recording records from the selection once it resumes.
        guard !session.isPaused else { return }
        guard Set(selectedDevices.map(\.id)) != Set(session.activeDevices.map(\.id)) else { return }
        if session.isSyncing {
            // Set right away, so the running sync can't decide that no input is left first.
            session.needsSync = true
        } else {
            Task { await syncCaptures(of: session) }
        }
    }

    /// The preferred devices that are present. `AudioInputDevice.defaultMicrophoneID` stands for the
    /// default microphone. A preferred microphone that's missing is replaced by the default
    /// microphone too, so unplugging a headset doesn't silently drop the user's voice. With
    /// nothing preferred or available, the default microphone, else the first device unless
    /// `fallsBackToAnyDevice` is off. A recording doesn't start capturing system audio on its own.
    private nonisolated static func resolveSelection(
        preferredIDs: [String],
        in devices: [AudioInputDevice],
        fallsBackToAnyDevice: Bool = true
    ) -> [AudioInputDevice] {
        let defaultMicrophone = Self.defaultMicrophone(in: devices)

        var ids = Set<String>()
        for id in preferredIDs {
            if id == AudioInputDevice.defaultMicrophoneID {
                if let defaultMicrophone { ids.insert(defaultMicrophone.id) }
            } else if devices.contains(where: { $0.id == id }) {
                ids.insert(id)
            } else if id != AudioInputDevice.systemAudioID, let defaultMicrophone {
                ids.insert(defaultMicrophone.id)
            }
        }
        if ids.isEmpty, let fallback = defaultMicrophone ?? (fallsBackToAnyDevice ? devices.first : nil) {
            ids.insert(fallback.id)
        }
        return devices.filter { ids.contains($0.id) }
    }

    /// The system's default microphone, else the first one.
    private nonisolated static func defaultMicrophone(in devices: [AudioInputDevice]) -> AudioInputDevice? {
        devices.first { $0.kind == .microphone && $0.isDefault } ?? devices.first { $0.kind == .microphone }
    }
}
