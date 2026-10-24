import Foundation
import os

/// Recordings kept on disk in the `recordingStore`, and quitting without losing them.
extension RecordingCoordinator {
    /// Whether quitting now keeps the recording in progress, or the one being made into a note, to
    /// make its note the next time: it's on disk.
    public var keepsRecordingWhenQuitting: Bool {
        if let session { return session.isStored }
        return isMakingNoteOfStoredRecording
    }

    /// Idle, the model is downloaded and there's a `noteWriter`.
    public var canTranscribeUnfinishedRecordings: Bool {
        isIdle && isModelDownloaded && noteWriter != nil
    }

    /// Makes a note of `recording` like of one that just ended, in the language it was recorded
    /// in, and deletes its audio once the note is saved. If that fails, it stays among
    /// `unfinishedRecordings`. Ignored unless it's one of them and
    /// `canTranscribeUnfinishedRecordings`.
    public func transcribe(_ recording: UnfinishedRecording) async {
        guard canTranscribeUnfinishedRecordings, unfinishedRecordings.contains(where: { $0.id == recording.id })
        else { return }
        unfinishedRecordings.removeAll { $0.id == recording.id }
        isTranscribingUnfinishedRecording = true
        holdEngine()
        phase = .transcribing(progress: 0)
        defer {
            isTranscribingUnfinishedRecording = false
            recordingSummaryTemplate = nil
            releaseEngine()
        }
        logger.info("Transcribing an unfinished recording of \(recording.duration, format: .fixed(precision: 1)) s")

        let stored: RecordingStore.StoredRecording
        do {
            stored = try await audio(of: recording)
        } catch {
            logger.error("Reading an unfinished recording failed: \(error.localizedDescription, privacy: .public)")
            keep(recording)
            phase = .failed(message: Self.unreadableRecordingMessage(for: error))
            return
        }

        let description = stored.description
        recordingSummaryTemplate = description.isCall ? callSummaryTemplate : summaryTemplate
        isRecordingSummaryTemplateChosen = false
        let tracks = Self.recordedTracks(of: stored.lanes)
        let duration = tracks.map(\.end).max() ?? 0
        let input = NotePipeline.Input(
            tracks: tracks,
            options: TranscriptionOptions(language: description.language),
            diarizer: speakerDiarizer,
            details: NotePipeline.NoteDetails(
                startedAt: description.startedAt,
                duration: duration,
                sources: description.sources,
                trigger: description.recordingTrigger,
                isCall: description.isCall,
                callApp: description.callApp,
                moments: description.recordedMoments
                    .map { Moment(id: $0.id, time: min($0.time, duration), text: $0.text) }
                    .sorted { $0.time < $1.time },
                recordingID: recording.isOnDisk ? recording.id : nil
            )
        )
        await makeNote(from: input, keeping: recording)
    }

    /// `recording` as kept in memory, or read from the `recordingStore`.
    private func audio(of recording: UnfinishedRecording) async throws -> RecordingStore.StoredRecording {
        if let audio = recordingsInMemory[recording.id] { return audio }
        guard recording.isOnDisk, let recordingStore else { throw CocoaError(.fileNoSuchFile) }
        return try await Task.detached(priority: .userInitiated) {
            try recordingStore.load(recording.id)
        }.value
    }

    /// Takes the `unfinishedRecordings` only kept in memory, to hand to the coordinator replacing
    /// this one, as Mixdown switches models.
    public func takeRecordingsInMemory() -> RecordingsInMemory {
        let recordings = unfinishedRecordings.filter { !$0.isOnDisk }.compactMap { recording in
            recordingsInMemory[recording.id].map { (recording, $0) }
        }
        unfinishedRecordings.removeAll { !$0.isOnDisk }
        recordingsInMemory = [:]
        return RecordingsInMemory(recordings: recordings)
    }

    /// Deletes `recording`'s audio. Ignored unless it's one of `unfinishedRecordings`, so not
    /// while it's being transcribed.
    public func discard(_ recording: UnfinishedRecording) {
        guard unfinishedRecordings.contains(where: { $0.id == recording.id }) else { return }
        unfinishedRecordings.removeAll { $0.id == recording.id }
        recordingsInMemory[recording.id] = nil
        if recording.isOnDisk { recordingStore?.delete(recording.id) }
        logger.info("Discarded an unfinished recording")
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
        self.session = nil
        recordingStartedAt = nil
        liveCaptioning?.cancel()
        liveCaptioning = nil
        resetLevels()
        stopStillRecordingCheck()
        let lanes = await endCaptures(of: session)
        for live in session.lanes.flatMap({ $0.captures.compactMap(\.live) }) {
            _ = await live.value
        }

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

        showsLiveTranscript = false
        liveTranscript = LiveTranscript(speakers: [])
        liveCaptions = nil
        recordingSummaryTemplate = nil
        moments = []
        phase = .idle
        reconcileSelection()
        releaseEngine()
    }

    // MARK: - Store

    /// Writes down what `session` has recorded so far in the `recordingStore`, if it keeps its
    /// audio on disk, so its audio can be made into a note if Mixdown quits before it is. Its audio
    /// is only written once this has been.
    func storeDescription(of session: Session) {
        guard session.keepsAudioOnDisk, let recordingStore else { return }
        do {
            try recordingStore.save(description(of: session), of: session.id)
            session.isStored = true
        } catch {
            logger.error("Keeping the recording on disk failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// `session` as an unfinished recording, to keep if its note isn't made. One that isn't on disk
    /// has its audio put in `recordingsInMemory`, unless it wasn't kept, as by a live model; then
    /// there's none.
    func unfinishedRecording(of session: Session, lanes: [LaneAudio], duration: TimeInterval) -> UnfinishedRecording? {
        if !session.isStored {
            guard !engine.transcribesLive else { return nil }
            recordingsInMemory[session.id] = RecordingStore.StoredRecording(
                description: description(of: session),
                lanes: Self.startingDevices(of: session, lanes: lanes)
            )
        }
        return UnfinishedRecording(
            id: session.id,
            startedAt: session.startedAt,
            duration: duration,
            sources: session.devices,
            isOnDisk: session.isStored
        )
    }

    /// What `session` is, besides its audio, with the moments marked so far.
    private func description(of session: Session) -> RecordingStore.Description {
        RecordingStore.Description(
            startedAt: session.startedAt,
            language: session.options.language,
            trigger: session.trigger.rawValue,
            isCall: session.isCall,
            callApp: session.callApp,
            lanes: session.lanes.map { lane in
                RecordingStore.Description.Lane(
                    kind: lane.kind.rawValue,
                    captures: lane.captures.map { RecordingStore.Description.Device($0.device) }
                )
            },
            moments: moments.map { RecordingStore.Description.Mark(id: $0.id, time: $0.time, text: $0.text) }
        )
    }

    /// Lists the recordings in the `recordingStore` as `unfinishedRecordings`, except those of
    /// `pendingIDs`, whose notes are waiting to be saved. Deletes those too short to transcribe.
    func loadUnfinishedRecordings(except pendingIDs: Set<UUID>) {
        guard let recordingStore else { return }
        unfinishedRecordings = recordingStore.recordings().filter { recording in
            guard !pendingIDs.contains(recording.id) else { return false }
            guard recording.duration >= Self.minimumRecordingDuration else {
                recordingStore.delete(recording.id)
                return false
            }
            return true
        }
        if !unfinishedRecordings.isEmpty {
            logger.info("Found \(self.unfinishedRecordings.count) unfinished recording(s)")
        }
    }

    /// Adds `recording` to `unfinishedRecordings`, if it isn't there yet.
    func keep(_ recording: UnfinishedRecording) {
        guard !unfinishedRecordings.contains(where: { $0.id == recording.id }) else { return }
        unfinishedRecordings.append(recording)
        unfinishedRecordings.sort { $0.startedAt < $1.startedAt }
    }
}
