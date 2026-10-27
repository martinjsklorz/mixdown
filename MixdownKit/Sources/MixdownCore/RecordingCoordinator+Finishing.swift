import Foundation
import os

extension RecordingCoordinator {
    /// Transcribes and saves a finished recording, one track per lane of `session`.
    func finish(_ session: Session, lanes: [LaneAudio], interruption: (any Error)?) async {
        reconcileSelection()

        let tracks = Self.recordedTracks(of: session, lanes: lanes)
        let duration = tracks.map(\.end).max() ?? 0
        guard duration >= Self.minimumRecordingDuration else {
            logger.info("Discarding \(duration, format: .fixed(precision: 2)) s recording as too short")
            if session.isStored { recordingStore?.delete(session.id) }
            // An interruption this early explains itself, like capture failing to start.
            phase = .failed(message: interruption?.localizedDescription ?? Self.tooShortMessage)
            return
        }

        phase = .transcribing(progress: 0)
        let input = NotePipeline.Input(
            tracks: tracks,
            options: session.options,
            liveText: engine.transcribesLive ? liveTranscript : nil,
            diarizer: session.diarizer,
            details: noteDetails(
                startedAt: session.startedAt,
                duration: duration,
                sources: session.devices,
                trigger: session.trigger,
                isCall: session.isCall,
                callApp: session.callApp,
                // Described up to now, as the user may have still been typing when it stopped.
                moments: moments,
                tracks: tracks,
                measuresTalkTime: session.measuresTalkTime,
                recordingID: session.isStored ? session.id : nil
            )
        )
        let recording = unfinishedRecording(of: session, lanes: lanes, duration: duration)
        // From here on, `makeNote` tells whether quitting keeps it.
        endingSession = nil
        await makeNote(from: input, keeping: recording, interruption: interruption)
    }

    /// What a recording's note says besides its transcript, whether it just ended or is made into a
    /// note later: `moments` within the audio and in order, and when the user and the others
    /// talked, if it `measuresTalkTime`.
    func noteDetails(
        startedAt: Date,
        duration: TimeInterval,
        sources: [AudioInputDevice],
        trigger: RecordingTrigger,
        isCall: Bool,
        callApp: String?,
        moments: [Moment],
        tracks: [NotePipeline.RecordedTrack],
        measuresTalkTime: Bool,
        recordingID: UUID?
    ) -> NotePipeline.NoteDetails {
        NotePipeline.NoteDetails(
            startedAt: startedAt,
            duration: duration,
            sources: sources,
            trigger: trigger,
            isCall: isCall,
            callApp: callApp,
            moments: moments.map { Moment(id: $0.id, time: min($0.time, duration), text: $0.text) }
                .sorted { $0.time < $1.time },
            talkTimeline: measuresTalkTime ? talkTimeline(of: tracks, duration: duration) : nil,
            recordingID: recordingID
        )
    }

    /// The tracks of `session`'s lanes, from what each recorded.
    static func recordedTracks(of session: Session, lanes: [LaneAudio]) -> [NotePipeline.RecordedTrack] {
        recordedTracks(of: startingDevices(of: session, lanes: lanes))
    }

    /// What each of `session`'s lanes recorded, with the device it started with.
    static func startingDevices(
        of session: Session,
        lanes: [LaneAudio]
    ) -> [(device: AudioInputDevice, audio: LaneAudio)] {
        zip(session.lanes, lanes).compactMap { lane, audio in lane.firstDevice.map { ($0, audio) } }
    }

    /// The tracks of a recording's lanes, each with the device it started with, lined up on the
    /// host clock.
    static func recordedTracks(
        of lanes: [(device: AudioInputDevice, audio: LaneAudio)]
    ) -> [NotePipeline.RecordedTrack] {
        let offsets = AudioTrack.startOffsets(of: lanes.map(\.audio.track))
        return lanes.enumerated().map { index, lane in
            NotePipeline.RecordedTrack(
                lane: index,
                device: lane.device,
                parts: lane.audio.parts,
                samples: lane.audio.track.samples,
                speech: lane.audio.speech,
                duration: lane.audio.track.duration,
                offset: offsets[index]
            )
        }
    }

    /// Makes and saves a note of a recording, and shows how that went. If it couldn't be made, or
    /// a track couldn't be transcribed, `recording` becomes one of `unfinishedRecordings`, to
    /// transcribe again; otherwise its audio in `recordingsInMemory` is let go. If capture ended
    /// with `interruption`, that's surfaced afterwards.
    func makeNote(
        from input: NotePipeline.Input,
        keeping recording: UnfinishedRecording?,
        interruption: (any Error)? = nil
    ) async {
        isMakingNoteOfStoredRecording = recording?.isOnDisk ?? false
        defer {
            isMakingNoteOfStoredRecording = false
            if let recording, !unfinishedRecordings.contains(where: { $0.id == recording.id }) {
                recordingsInMemory[recording.id] = nil
            }
        }
        do {
            try await prepareModelIfMissing()
            let outcome = try await pipeline.makeNote(from: input) {
                takeSummaryTemplate(otherwise: input.details.isCall ? callSummaryTemplate : summaryTemplate)
            }
            var messages = interruption.map { [Self.interruptedMessage(for: $0)] } ?? []
            messages += outcome.messages
            if !outcome.isComplete, let recording {
                keep(recording)
                messages.append(Self.keptRecordingMessage(for: recording))
            }
            show(messages)
            // A live model that failed to load needs the same retry as an offline one.
            if let interruption, case TranscriptionError.modelUnavailable = interruption {
                modelError = interruption.localizedDescription
            }
        } catch is CancellationError {
            logger.info("Finishing recording cancelled")
            if let recording { keep(recording) }
            phase = .idle
        } catch {
            logger.error("Finishing recording failed: \(error.localizedDescription, privacy: .public)")
            if let recording { keep(recording) }
            let message = [error.localizedDescription, recording.map(Self.keptRecordingMessage)]
                .compactMap { $0 }.joined(separator: " ")
            phase = .failed(message: message)
            if case TranscriptionError.modelUnavailable = error {
                modelError = error.localizedDescription
            }
        }
    }

    /// The summary template the user chose for the recording or import, as
    /// `recordingSummaryTemplate`, else `fallback`. It can't change once the summary is under way.
    func takeSummaryTemplate(otherwise fallback: SummaryTemplate) -> SummaryTemplate {
        defer { recordingSummaryTemplate = nil }
        return recordingSummaryTemplate ?? fallback
    }

    /// Ends a finished recording or import as idle, or with `messages` as its failure.
    func show(_ messages: [String]) {
        if messages.isEmpty {
            phase = .idle
        } else {
            let message = messages.joined(separator: " ")
            unsavedNoteMessage = pendingNotes.isEmpty ? nil : message
            phase = .failed(message: message)
        }
    }

    /// Clears the failure saying a note is waiting to be saved, once every note is.
    func pendingNotesDidSave() {
        if let unsavedNoteMessage, phase == .failed(message: unsavedNoteMessage) {
            phase = .idle
        }
        unsavedNoteMessage = nil
    }

    /// When the user and the others talked, from the microphone and system audio tracks. `nil`
    /// without both, or if nobody talked.
    private func talkTimeline(of tracks: [NotePipeline.RecordedTrack], duration: TimeInterval) -> TalkTimeline? {
        let speech = { (kind: AudioSourceKind) -> [Range<TimeInterval>]? in
            let ofKind = tracks.filter { $0.device.kind == kind }
            guard !ofKind.isEmpty else { return nil }
            return ofKind.flatMap { NotePipeline.shifted($0.speech, by: $0.offset) }
        }
        guard let microphone = speech(.microphone), let systemAudio = speech(.systemAudio) else { return nil }
        let timeline = TalkTimeline(
            labels: sourceLabels,
            microphone: microphone,
            systemAudio: systemAudio,
            duration: duration
        )
        return timeline.total.total > 0 ? timeline : nil
    }
}
