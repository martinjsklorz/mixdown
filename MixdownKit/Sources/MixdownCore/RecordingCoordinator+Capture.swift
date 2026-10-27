import Foundation
import os

extension RecordingCoordinator {
    public func startRecording() async {
        guard canStartRecording else { return }
        let devices = selectedDevices
        // Taken now, as the language can change while macOS asks for permission.
        let options = options
        let echoCancellation = cancelsEcho ? echoCancellation : nil
        // Loads a canceller while the recording gets under way; until one is ready, the
        // microphones are recorded as they are.
        echoCancellation?.prepare()
        phase = .startingCapture
        isStopPending = false
        // Held until `end(_:interruption:)` has transcribed the recording.
        holdEngine()

        let startedCaptures: [StartedCapture]
        do {
            startedCaptures = try await startCaptures(for: devices)
        } catch {
            logger.error("Starting capture failed: \(error.localizedDescription, privacy: .public)")
            abandonStart(with: .failed(message: error.localizedDescription))
            return
        }

        // Stopped before anything was recorded, e.g. during the permission prompt or by a quick
        // second press of the shortcut. That's no error, just a recording that didn't happen.
        guard !isStopPending else {
            logger.info("Recording stopped while starting; discarding it")
            for capture in startedCaptures.map(\.capture) {
                await capture.stop()
            }
            abandonStart(with: .idle)
            return
        }

        let session = Session(
            startedAt: now(),
            startHostTime: hostClock(),
            options: options,
            echoReference: echoCancellation == nil ? nil : EchoReference(),
            measuresTalkTime: measuresTalkTime,
            diarizer: speakerDiarizer
        )
        self.session = session
        recordingStartedAt = session.startedAt
        recordingSummaryTemplate = summaryTemplate
        isRecordingSummaryTemplateChosen = false
        moments = []
        session.keepsAudioOnDisk = keepsAudioOnDisk
        storeDescription(of: session)
        if engine.transcribesLive {
            liveTranscript = LiveTranscript(speakers: [])
            showsLiveTranscript = true
            startLiveCaptions(for: session)
        }
        talkTime = nil
        lastSpeech = nil
        for started in startedCaptures {
            attach(started, to: addLane(kind: started.device.kind, to: session), in: session)
        }
        phase = .recording(startedAt: session.startedAt)
        startStillRecordingCheck(for: session)
        let names = devices.map(\.name).joined(separator: " + ")
        logger.info(
            "Recording started on \(names, privacy: .public); echo removal \(echoCancellation == nil ? "off" : "on", privacy: .public)"
        )
        // Catches devices that changed while the captures were starting.
        reconcileSelection()
    }

    /// Undoes `startRecording()` for a recording that never got under way, ending in `phase`.
    private func abandonStart(with phase: Phase) {
        isStopPending = false
        releaseEngine()
        self.phase = phase
        reconcileSelection()
    }

    /// Adds a lane to `session`, and a source for it to `liveTranscript`. Starts counting
    /// `talkTime` once the session records both kinds of input, if it measures talk time.
    private func addLane(kind: AudioSourceKind, to session: Session) -> Lane {
        let lane = session.addLane(kind: kind)
        if showsLiveTranscript { liveTranscript.addSource() }
        if session.measuresTalkTime, talkTime == nil, Set(session.lanes.map(\.kind)).count > 1 {
            talkTime = TalkTime()
        }
        return lane
    }

    /// Makes `started` the lane's current capture: drains its stream into a track with a
    /// `CaptureLoop`, watches for it ending on its own, and checks that it isn't silent. With a live
    /// engine, also transcribes it.
    private func attach(_ started: StartedCapture, to lane: Lane, in session: Session) {
        // The first input to start again after a pause ends it.
        if let pausedAt = session.pausedAt {
            session.pausedDuration += max(hostClock() - pausedAt, 0)
            session.pausedAt = nil
        }
        let deviceID = started.device.id
        let sessionID = session.id
        let kind = lane.kind
        let transcribesLive = engine.transcribesLive
        let feed = transcribesLive ? AsyncStream<CaptureLoop.LiveFeed>.makeStream() : nil
        let echoReference = session.echoReference
        let loop = CaptureLoop(
            kind: kind,
            deviceName: started.device.name,
            keepsAudio: session.keepsAudio(of: kind, transcribesLive: transcribesLive),
            audioFile: session.isStored
                ? recordingStore?.audioURL(of: session.id, lane: lane.index, capture: lane.captures.count) : nil,
            hostTimeShift: session.pausedDuration,
            echoReference: echoReference,
            echoCancellation: echoReference == nil ? nil : echoCancellation,
            liveFeed: feed?.continuation,
            reportLevel: { [weak self] level, speech in
                Task { @MainActor [weak self] in
                    self?.updateLevel(level, speech: speech, of: deviceID, kind: kind, sessionID: sessionID)
                }
            }
        )
        let consumer = loop.start(started.stream)
        let live = feed.map { feed in
            // A lane's captures are transcribed one after another, so its words stay in order.
            let previous = lane.captures.last?.live
            let source = lane.index
            let options = session.options
            return Task { [weak self] () -> (any Error)? in
                _ = await previous?.value
                guard let self else { return nil }
                return await self.transcribeLive(feed.stream, source: source, options: options)
            }
        }
        let capture = Capture(device: started.device, capture: started.capture, consumer: consumer, live: live)
        lane.add(capture)
        storeDescription(of: session)
        Task { [weak self] in
            let result = await consumer.value
            await self?.captureDidEnd(capture, of: lane, in: session, result: result)
        }
        // The note would miss everything after live transcription stops, so the recording ends.
        if let live {
            Task { [weak self] in
                if let error = await live.value { await self?.end(session, interruption: error) }
            }
        }
        scheduleSilenceCheck(of: started.device, in: session)
        if showsLiveTranscript { labelLiveSources(of: session) }
    }

    /// Starts one capture per device, all at once so they begin as close together as possible.
    /// If any fails, the others are stopped again and the first device's error is thrown.
    private func startCaptures(for devices: [AudioInputDevice]) async throws -> [StartedCapture] {
        let captures = try devices.map { try captureFactory.makeCapture(for: $0) }
        let results = await withTaskGroup(
            of: (Int, Result<CaptureStream, any Error>).self,
            returning: [Result<CaptureStream, any Error>].self
        ) { group in
            for (index, capture) in captures.enumerated() {
                group.addTask {
                    do {
                        return (index, .success(try await capture.start()))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            var results = [Result<CaptureStream, any Error>?](repeating: nil, count: captures.count)
            for await (index, result) in group {
                results[index] = result
            }
            return results.compactMap { $0 }
        }

        var started: [StartedCapture] = []
        var firstError: (any Error)?
        for (index, result) in results.enumerated() {
            switch result {
            case .success(let stream):
                started.append(StartedCapture(device: devices[index], capture: captures[index], stream: stream))
            case .failure(let error): firstError = firstError ?? error
            }
        }
        if let firstError {
            for capture in started.map(\.capture) {
                await capture.stop()
            }
            throw firstError
        }
        return started
    }

    /// Stops `captures` all at once.
    nonisolated static func stop(_ captures: [any AudioCapturing]) async {
        await withTaskGroup(of: Void.self) { group in
            for capture in captures {
                group.addTask { await capture.stop() }
            }
        }
    }

    // MARK: - Pausing

    /// Pauses the recording: its inputs stop until `resumeRecording()`. Ignored unless recording
    /// and not paused.
    public func pauseRecording() async {
        guard let session, case .recording = phase else { return }
        session.isPaused = true
        // Already set if no input started again since the last pause, which then still counts.
        session.pausedAt = session.pausedAt ?? hostClock()
        phase = .paused(recorded: session.recordedTime(at: hostClock()))
        // Pausing is an answer too; the wait starts over once it resumes.
        if isAskingIfStillRecording { isAskingIfStillRecording = false }
        let running = session.takeCurrentCaptures()
        for capture in running {
            clearLevel(of: capture.device)
        }
        await session.stopWhilePaused(running.map(\.capture)).value
        logger.info("Recording paused")
    }

    /// Records again from the selected inputs, which may have changed while paused. The recording
    /// ends, keeping what it has, if none of them starts. Ignored unless paused.
    public func resumeRecording() async {
        guard let session, case .paused(let recorded) = phase else { return }
        session.isPaused = false
        phase = .recording(startedAt: now().addingTimeInterval(-recorded))
        logger.info("Recording resumed")
        // An input may not start again on a device it hasn't stopped on yet.
        let pausing = session.pausing
        await pausing?.value
        // A pause since may have stopped more.
        if session.pausing == pausing { session.pausing = nil }
        guard self.session === session, !session.isPaused else { return }
        await syncCaptures(of: session)
    }

    public func togglePause() async {
        if isPaused {
            await resumeRecording()
        } else {
            await pauseRecording()
        }
    }

    // MARK: - Stopping

    /// Stops capture, transcribes, writes the note and updates `lastNoteURL`. While the captures
    /// are starting, e.g. waiting on a permission prompt, it stops them as soon as they've started.
    public func stopRecording() async {
        guard !isStartingCapture else {
            isStopPending = true
            return
        }
        // An error racing a user-initiated stop doesn't matter; keep whatever was captured.
        guard let session else { return }
        await end(session, interruption: nil)
    }

    /// Stops the recording in progress without making its note, keeping its audio in the
    /// `recordingStore` to make one later, as one of `unfinishedRecordings`. For quitting without
    /// waiting for the note, e.g. while logging out; unless it's on disk, the recording is lost. While
    /// the captures start, they're stopped as soon as they have, like by `stopRecording()`.
    public func stopRecordingWithoutNote() async {
        guard !isStartingCapture else {
            isStopPending = true
            return
        }
        guard let session else { return }
        // Its live text isn't needed, so the live sessions don't catch up on what they were behind.
        let (lanes, _) = await tearDown(session, finishingLiveText: false)

        storeDescription(of: session)
        let tracks = Self.recordedTracks(of: session, lanes: lanes)
        let duration = tracks.map(\.end).max() ?? 0
        if session.isStored, duration >= Self.minimumRecordingDuration {
            keep(
                UnfinishedRecording(
                    id: session.id,
                    startedAt: session.startedAt,
                    duration: duration,
                    sources: session.devices,
                    isOnDisk: true
                )
            )
        } else if session.isStored {
            recordingStore?.delete(session.id)
        }
        logger.info("Recording stopped without a note")

        endingSession = nil
        clearRecordingUI()
        phase = .idle
        reconcileSelection()
        releaseEngine()
    }

    /// Stops every capture of `session`, then transcribes and saves what they recorded. If capture
    /// ended with `interruption`, a note of the partial recording is still saved and the error is
    /// surfaced afterwards.
    private func end(_ session: Session, interruption: (any Error)?) async {
        guard self.session === session else { return }
        let (lanes, liveError) = await tearDown(session, finishingLiveText: true)
        await finish(session, lanes: lanes, interruption: interruption ?? liveError)
        endingSession = nil
        clearRecordingUI()
        releaseEngine()
    }

    /// Ends `session` as the recording in progress, as `endingSession`, and stops all of it: its
    /// captures, then its live sessions, which first transcribe the rest of their input if
    /// `finishingLiveText`. Returns what each lane recorded, and the first error that stopped a
    /// live session.
    private func tearDown(
        _ session: Session,
        finishingLiveText: Bool
    ) async -> (lanes: [LaneAudio], liveError: (any Error)?) {
        // Clearing the session first makes repeated stops and the end-of-stream handlers no-ops.
        self.session = nil
        endingSession = session
        // No longer recording, so it can't be paused, marked as a call or stopped again.
        phase = .transcribing(progress: 0)
        recordingStartedAt = nil
        liveCaptioning?.cancel()
        liveCaptioning = nil
        resetLevels()
        stopStillRecordingCheck()
        let lanes = await endCaptures(of: session)
        guard finishingLiveText else {
            let live = session.lanes.flatMap { $0.captures.compactMap(\.live) }
            live.forEach { $0.cancel() }
            // Waited for even so, to let go of the engine only once its sessions are done.
            for task in live {
                _ = await task.value
            }
            return (lanes, nil)
        }
        return (lanes, await finishLiveTranscription(of: session))
    }

    /// Clears what's shown of the recording that ended: its live text and captions, moments and
    /// summary template.
    private func clearRecordingUI() {
        showsLiveTranscript = false
        liveTranscript = LiveTranscript(speakers: [])
        liveCaptions = nil
        recordingSummaryTemplate = nil
        moments = []
    }

    /// Stops every capture of `session` and joins what each lane recorded into one track per lane.
    func endCaptures(of session: Session) async -> [LaneAudio] {
        await Self.stop(session.takeCurrentCaptures().map(\.capture))
        var lanes: [LaneAudio] = []
        for lane in session.lanes {
            let keepsAudio = session.keepsAudio(of: lane.kind, transcribesLive: engine.transcribesLive)
            var audio = LaneAudio(track: AudioTrack(keepsSamples: keepsAudio))
            for capture in lane.captures {
                let result = await capture.consumer.value
                audio.append(result.track, from: capture.device, speech: result.speech)
                if result.diskWriteFailed { session.lostAudioOnDisk = true }
            }
            lanes.append(audio)
        }
        return lanes
    }

    // MARK: - Switching inputs

    /// Handles a capture that ended without being stopped. A device that went away is replaced by
    /// the default microphone, and one cut off by the audio service restarting is started again;
    /// anything else ends the whole recording: permission was revoked, or the user stopped capture
    /// from the system's menu bar indicator.
    private func captureDidEnd(
        _ capture: Capture,
        of lane: Lane,
        in session: Session,
        result: CaptureLoop.Output
    ) async {
        // Captures stopped on purpose, by a switch or the end of the recording, aren't current.
        guard self.session === session, lane.current?.id == capture.id else { return }

        let captureError = result.error as? AudioCaptureError
        switch captureError {
        case .deviceNotFound?:
            logger.info("\(capture.device.name, privacy: .public) went away, looking for a replacement")
            session.unavailableDeviceIDs.insert(capture.device.id)
        case .audioServiceRestarted?:
            // Starting it again fails if the device is really gone, which marks it unavailable.
            logger.info("Audio service restarted, starting \(capture.device.name, privacy: .public) again")
        default:
            if let error = result.error {
                logger.error("Capture failed: \(error.localizedDescription, privacy: .public)")
            } else {
                logger.info("Capture ended by the system")
            }
            await end(session, interruption: result.error)
            return
        }

        lane.current = nil
        clearLevel(of: capture.device)
        session.lastCaptureError = captureError
        session.pendingReplacements += 1
        await capture.capture.stop()
        try? await Task.sleep(for: deviceSwitchDelay)
        let devices = await deviceProvider.availableDevices()
        session.pendingReplacements -= 1
        guard self.session === session else { return }
        applyDevices(devices)
        await syncCaptures(of: session)
    }

    /// Starts and stops captures until `session` records `selectedDevices`, then ends the
    /// recording if no input is left. Calls made while it runs make it go around once more.
    func syncCaptures(of session: Session) async {
        // Resuming syncs again.
        guard self.session === session, !session.isPaused else { return }
        guard !session.isSyncing else {
            session.needsSync = true
            return
        }
        session.isSyncing = true
        repeat {
            session.needsSync = false
            await applySelection(to: session)
        } while session.needsSync && self.session === session && !session.isPaused
        session.isSyncing = false

        guard self.session === session, !session.isPaused, session.activeDevices.isEmpty,
            session.pendingReplacements == 0
        else { return }
        logger.error("No input left to record from")
        await end(session, interruption: session.lastCaptureError)
    }

    /// One pass of `syncCaptures(of:)`. Inputs that are no longer selected stop first, so a lane
    /// switching devices never records from both at once.
    private func applySelection(to session: Session) async {
        let wanted = selectedDevices.filter { !session.unavailableDeviceIDs.contains($0.id) }

        for lane in session.lanes {
            guard let current = lane.current, !wanted.contains(where: { $0.id == current.device.id }) else { continue }
            lane.current = nil
            clearLevel(of: current.device)
            await current.capture.stop()
            logger.info("Stopped recording from \(current.device.name, privacy: .public)")
            guard self.session === session else { return }
        }

        for device in wanted where !session.activeDevices.contains(where: { $0.id == device.id }) {
            guard self.session === session, !session.isPaused else { return }
            let started: StartedCapture
            do {
                let capture = try captureFactory.makeCapture(for: device)
                started = StartedCapture(device: device, capture: capture, stream: try await capture.start())
            } catch {
                logger.error(
                    "Couldn't switch to \(device.name, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                session.unavailableDeviceIDs.insert(device.id)
                session.lastCaptureError = error
                // Falls back to the default microphone, if that's another device.
                reconcileSelection()
                continue
            }
            // Paused while it started. Resuming waits for it to stop, like for the paused inputs.
            guard self.session === session, !session.isPaused else {
                await session.stopWhilePaused([started.capture]).value
                return
            }
            // A microphone replacing another continues its track.
            let lane =
                session.lanes.first { $0.kind == device.kind && $0.current == nil }
                ?? addLane(kind: device.kind, to: session)
            attach(started, to: lane, in: session)
            logger.info("Now recording from \(device.name, privacy: .public)")
        }
    }
}
