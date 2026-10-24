import Foundation
import os

extension RecordingCoordinator {
    /// Marks the recording in progress as a call in `app`, if known, so its note says so and is
    /// titled as one, e.g. "Zoom call about …", and, if Mixdown started it by itself, as started
    /// automatically. Ignored when not recording.
    public func markRecordingAsCall(in app: String? = nil, automatically: Bool = false) {
        guard let session else { return }
        session.isCall = true
        session.callApp = app
        if automatically { session.trigger = .automatic }
        if !isRecordingSummaryTemplateChosen {
            recordingSummaryTemplate = callSummaryTemplate
        }
        storeDescription(of: session)
    }

    /// Summarizes the recording in progress, or the one being transcribed, with `template`
    /// instead of the default. Ignored when there's no such recording or its summary has begun.
    public func chooseSummaryTemplate(_ template: SummaryTemplate) {
        guard recordingSummaryTemplate != nil else { return }
        recordingSummaryTemplate = template
        isRecordingSummaryTemplateChosen = true
    }

    /// Takes the user's edits to templates into the recording in progress: its template, if
    /// `templates` has one with the same id, is replaced by that. A deleted template is kept.
    public func updateRecordingSummaryTemplate(from templates: [SummaryTemplate]) {
        guard let current = recordingSummaryTemplate,
            let edited = templates.first(where: { $0.id == current.id }), edited != current
        else { return }
        recordingSummaryTemplate = edited
    }

    /// How far the recording in progress has got, paused or not, in seconds not counting pauses:
    /// where a moment marked now goes. `nil` when not recording.
    public var momentTime: TimeInterval? {
        switch phase {
        case .recording(let startedAt): max(now().timeIntervalSince(startedAt), 0)
        case .paused(let recorded): recorded
        default: nil
        }
    }

    /// Adds a moment at `time` (see `momentTime`) to the note of the recording in progress, with
    /// `text` trimmed. Returns it, or `nil` when not recording.
    @discardableResult
    public func addMoment(at time: TimeInterval, text: String = "") -> Moment? {
        guard isRecording else { return nil }
        let moment = Moment(time: time, text: text.trimmingCharacters(in: .whitespacesAndNewlines))
        moments.append(moment)
        if let session { storeDescription(of: session) }
        logger.info("Moment added at \(time, format: .fixed(precision: 1)) s")
        return moment
    }

    /// Sums up the last `duration` seconds of the live text with `summarizer`, for someone who
    /// drifted off: in the language the live text is translated into, if it is, else the
    /// recording's. Works paused, too, up to where it paused.
    ///
    /// Throws `CatchUpError` when not recording, without live text, or if nothing (worth summing
    /// up) was said in that time, and `SummarizationError` if `summarizer` isn't available or
    /// fails.
    public func catchUp(onLast duration: TimeInterval, with summarizer: any Summarizer) async throws -> CatchUp {
        guard let session, let time = momentTime else { throw CatchUpError.notRecording }
        guard showsLiveTranscript else { throw CatchUpError.noLiveText }
        if case .unavailable(let reason) = summarizer.availability {
            throw SummarizationError.unavailable(reason)
        }
        let transcript = liveTranscript.transcript(since: time - duration, language: session.options.language)
        guard !transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CatchUpError.nothingSaid
        }
        let language = liveCaptions?.language
        logger.info("Catching up on \(transcript.segments.count) line(s) of the last \(Int(duration)) s")
        let points = try await summarizer.catchUp(on: transcript, language: language)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !points.isEmpty else { throw CatchUpError.nothingSaid }
        return CatchUp(duration: min(duration, time), points: points)
    }
}
