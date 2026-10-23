import Foundation
import os

extension RecordingCoordinator {
    /// Transcribes and saves a finished recording, one track per lane of `session`.
    func finish(_ session: Session, lanes: [LaneAudio], interruption: (any Error)?) async {
        reconcileSelection()
        defer {
            showsLiveTranscript = false
            liveTranscript = LiveTranscript(speakers: [])
            liveCaptions = nil
        }

        let offsets = AudioTrack.startOffsets(of: lanes.map(\.track))
        let tracks: [NotePipeline.RecordedTrack] = zip(session.lanes, lanes).enumerated().compactMap { index, pair in
            guard let device = pair.0.firstDevice else { return nil }
            return NotePipeline.RecordedTrack(
                lane: index,
                device: device,
                parts: pair.1.parts,
                samples: pair.1.track.samples,
                speech: pair.1.speech,
                duration: pair.1.track.duration,
                offset: offsets[index]
            )
        }
        let duration = tracks.map(\.end).max() ?? 0
        guard duration >= Self.minimumRecordingDuration else {
            logger.info("Discarding \(duration, format: .fixed(precision: 2)) s recording as too short")
            // An interruption this early explains itself, like capture failing to start.
            phase = .failed(message: interruption?.localizedDescription ?? Self.tooShortMessage)
            return
        }

        phase = .transcribing(progress: 0)
        do {
            try await prepareModelIfMissing()
            let input = NotePipeline.Input(
                tracks: tracks,
                options: session.options,
                liveText: engine.transcribesLive ? liveTranscript : nil,
                diarizer: session.diarizer,
                details: NotePipeline.NoteDetails(
                    startedAt: session.startedAt,
                    duration: duration,
                    sources: session.devices,
                    trigger: session.trigger,
                    isCall: session.isCall,
                    // Described up to now, as the user may have still been typing when it stopped.
                    moments: moments.map { Moment(id: $0.id, time: min($0.time, duration), text: $0.text) }
                        .sorted { $0.time < $1.time },
                    talkTimeline: session.measuresTalkTime ? talkTimeline(of: tracks, duration: duration) : nil
                )
            )
            let messages = try await pipeline.makeNote(from: input) {
                takeSummaryTemplate(otherwise: session.isCall ? callSummaryTemplate : summaryTemplate)
            }
            show(interruption.map { [Self.interruptedMessage(for: $0)] + messages } ?? messages)
            // A live model that failed to load needs the same retry as an offline one.
            if let interruption, case TranscriptionError.modelUnavailable = interruption {
                modelError = interruption.localizedDescription
            }
        } catch is CancellationError {
            logger.info("Finishing recording cancelled")
            phase = .idle
        } catch {
            logger.error("Finishing recording failed: \(error.localizedDescription, privacy: .public)")
            if case TranscriptionError.modelUnavailable = error {
                failWithModelError(error)
            } else {
                phase = .failed(message: error.localizedDescription)
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
