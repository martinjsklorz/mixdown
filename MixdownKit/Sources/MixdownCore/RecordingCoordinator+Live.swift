import Foundation
import os

extension RecordingCoordinator {
    // MARK: - Live transcription

    /// Labels the live transcript's sources like the note's: only when there are several.
    func labelLiveSources(of session: Session) {
        let devices = session.lanes.compactMap(\.firstDevice)
        for lane in session.lanes {
            let label = devices.count > 1 ? lane.firstDevice.map { sourceLabels.label(for: $0, among: devices) } : nil
            liveTranscript.setSpeaker(label, ofSource: lane.index)
        }
    }

    /// Feeds one capture's audio to a live session and adds what it recognizes to
    /// `liveTranscript`, until the capture ends. Returns the error that stopped it early, if any.
    func transcribeLive(
        _ feed: AsyncStream<CaptureLoop.LiveFeed>,
        source index: Int,
        options: TranscriptionOptions
    ) async -> (any Error)? {
        do {
            // Loads the model if it isn't yet; the feed buffers the audio meanwhile.
            let live = try await engine.makeLiveSession(options: options)
            // Its words come from another device than the lane's previous session's.
            liveTranscript.breakSegment(ofSource: index)
            var startHostTime: TimeInterval?
            for await item in feed {
                startHostTime = item.startHostTime
                let update = try await live.push(item.samples)
                liveTranscript.apply(update, fromSource: index, startHostTime: startHostTime)
            }
            let update = try await live.finish()
            liveTranscript.apply(update, fromSource: index, startHostTime: startHostTime)
            return nil
        } catch {
            logger.error("Live transcription failed: \(error.localizedDescription, privacy: .public)")
            return error
        }
    }

    /// Waits for `session`'s live sessions to transcribe the rest of their input. Returns the
    /// first error that stopped one.
    func finishLiveTranscription(of session: Session) async -> (any Error)? {
        let live = session.lanes.flatMap { $0.captures.compactMap(\.live) }
        guard !live.isEmpty else { return nil }
        phase = .transcribing(progress: 0)
        var firstError: (any Error)?
        for task in live {
            if let error = await task.value { firstError = firstError ?? error }
        }
        return firstError
    }

    // MARK: - Live captions

    /// Starts translating `liveTranscript` as `session` records, if there's a language to
    /// translate into and live text is to be translated.
    func startLiveCaptions(for session: Session) {
        guard translatesLiveText, let translator, let language = translationLanguage else { return }
        liveCaptions = LiveCaptions(language: language)
        liveCaptioning = Task { [weak self] in
            await self?.captionLiveText(of: session, with: translator)
        }
    }

    /// Translates the live text's lines that changed, one at a time, until `session` ends. Waits
    /// `liveCaptionInterval` between rounds, so lines are translated again as they grow.
    private func captionLiveText(of session: Session, with translator: any Translator) async {
        while self.session === session, !Task.isCancelled {
            for line in liveCaptions?.linesToTranslate(in: liveTranscript) ?? [] {
                await caption(line, in: session, with: translator)
                guard self.session === session, !Task.isCancelled else { return }
            }
            try? await Task.sleep(for: liveCaptionInterval)
        }
    }

    /// Translates `line` on its own into `liveCaptions`, from the recording's language or, for
    /// automatic, whichever the line is in, so either side of a call can be in another.
    private func caption(_ line: LiveTranscript.Line, in session: Session, with translator: any Translator) async {
        guard let language = liveCaptions?.language else { return }
        let text = line.text
        let transcript = Transcript(
            segments: [TranscriptSegment(start: line.start, end: line.end, text: text)],
            language: session.options.language
        )
        let result: Result<Transcript?, any Error>
        do {
            result = .success(try await translator.translate(transcript, to: language))
        } catch {
            result = .failure(error)
        }
        // A new recording may have started meanwhile, with captions of its own.
        guard self.session === session else { return }
        switch result {
        case .success(let translation):
            liveCaptions?.setTranslation(translation?.text, of: text, forLine: line.id)
        case .failure(let error) where error is CancellationError:
            break
        case .failure(let error):
            logger.debug("Translating live text failed: \(error.localizedDescription, privacy: .public)")
            // Only missing languages are worth mentioning; a line too short to tell its language
            // from, say, isn't.
            let isNotInstalled = if case .notInstalled = error as? TranscriptTranslationError { true } else { false }
            liveCaptions?.setFailure(
                of: text,
                forLine: line.id,
                problem: isNotInstalled ? error.localizedDescription : nil
            )
        }
    }
}
