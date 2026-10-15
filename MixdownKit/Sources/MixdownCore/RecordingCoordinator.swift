import Foundation
import Observation
import os

/// Drives the record → transcribe → write-note flow and exposes its state to the UI.
///
/// Several inputs can be recorded at once, e.g. the microphone for the user and system audio for
/// the other people on a call. Each is captured into its own track, lined up on the host clock,
/// transcribed separately and labeled by `sourceLabels`; the transcripts are then merged by time.
/// A single input is transcribed as before, without labels.
///
/// Engines that transcribe live instead turn each input into text while it's recorded, shown as
/// `liveTranscript`, and the note is written from that text. Their audio isn't kept, so a long
/// recording takes no more memory than a short one.
///
/// All dependencies are protocols, so the coordinator is fully testable with doubles and
/// knows nothing about CoreAudio or the speech model.
@MainActor
@Observable
public final class RecordingCoordinator {
    public enum Phase: Equatable, Sendable {
        case idle
        /// Downloading or loading the model. `progress` is 0...1.
        case preparingModel(progress: Double)
        case recording(startedAt: Date)
        /// `progress` is 0...1 across all of the recording's sources.
        case transcribing(progress: Double)
        /// Summarizing the transcript before the note is saved.
        case summarizing
        case failed(message: String)
    }

    /// Recordings shorter than this are discarded without transcribing.
    nonisolated static let minimumRecordingDuration: TimeInterval = 0.5

    /// Audio is handed to live sessions in pieces of at least this many samples (320 ms, the step
    /// Nemotron works in) rather than per capture buffer, which can be a hundred times a second.
    nonisolated static let liveFeedSampleCount = 5_120

    public private(set) var phase: Phase = .idle {
        didSet { modelError = nil }
    }
    /// The message of a `.failed` phase caused by the model failing to download, load or delete,
    /// as opposed to e.g. a capture error. `nil` once the phase changes.
    public private(set) var modelError: String?
    public private(set) var devices: [AudioInputDevice] = []
    /// Inputs the next recording captures, in `devices` order.
    public private(set) var selectedDevices: [AudioInputDevice] = []
    /// Location of the most recently written note.
    public private(set) var lastNoteURL: URL?
    /// Whether the current recording is transcribed live. Stays true until its note is written.
    public private(set) var showsLiveTranscript = false
    /// What the inputs said so far while `showsLiveTranscript`, else empty.
    public private(set) var liveTranscript = LiveTranscript(speakers: [])
    /// Saves finished notes. `nil` while there's no folder to save to; recording waits for one.
    public var noteWriter: (any NoteWriting)?
    /// Adds a summary to each note. `nil` while summaries are off.
    public var summarizer: (any Summarizer)?
    public var options: TranscriptionOptions
    /// Speaker names for multi-source recordings.
    public var sourceLabels: SourceLabels

    /// Each source's level while recording, by device ID. Changes about ten times a second, so
    /// only read it from views that draw meters.
    public private(set) var inputLevels: [String: InputLevel] = [:]

    /// Sources of the current recording that haven't made a sound since it started, once
    /// `silenceWarningDelay` has passed. A source leaves the list as soon as it's heard.
    ///
    /// Without the System Audio Recording permission the tap keeps running but delivers silence,
    /// so this is the only way a denial shows up before the note comes out empty.
    public private(set) var silentDevices: [AudioInputDevice] = []

    /// How long a source may stay silent before it's listed in `silentDevices`.
    var silenceWarningDelay: Duration = .seconds(10)

    public var engineInfo: TranscriptionEngineInfo { engine.info }

    /// Whether the model is on disk. Recording waits for it, since fetching it can take many
    /// minutes; `prepareEngine()` downloads it.
    public private(set) var isModelDownloaded: Bool

    /// True while `deleteModel()` removes the model's files.
    public private(set) var isDeletingModel = false

    public var isRecording: Bool {
        switch phase {
        case .recording: true
        default: false
        }
    }

    /// Preparing the model, transcribing or summarizing.
    public var isBusy: Bool {
        switch phase {
        case .preparingModel, .transcribing, .summarizing: true
        default: false
        }
    }

    /// Estimated seconds until the model is ready or the note is transcribed, while preparing or
    /// transcribing. `nil` until there's enough progress to extrapolate from (a few seconds in).
    public var timeRemaining: TimeInterval? {
        switch phase {
        case .preparingModel, .transcribing: return progressEstimator.remaining
        default: return nil
        }
    }

    /// Nothing is downloading, deleting, recording, transcribing or summarizing. An error may be
    /// showing.
    public var isIdle: Bool {
        guard !isCapturing, !isDeletingModel else { return false }
        switch phase {
        case .idle, .failed: return true
        default: return false
        }
    }

    /// Idle, at least one device is selected, the model is downloaded and there's a `noteWriter`.
    public var canStartRecording: Bool {
        isIdle && !selectedDevices.isEmpty && isModelDownloaded && noteWriter != nil
    }

    private let deviceProvider: any AudioDeviceProvider
    private let captureFactory: any AudioCaptureFactory
    private let engine: any TranscriptionEngine
    private let now: @Sendable () -> Date
    private let logger = Logger(subsystem: "app.mixdown", category: "coordinator")

    @ObservationIgnored private var preferredDeviceIDs: [String]
    @ObservationIgnored private var session: Session?
    /// The in-flight `engine.prepare` call, kept so `cancelPreparation()` can stop it.
    @ObservationIgnored private var preparation: Task<Void, any Error>?
    /// True while the captures are starting; blocks a second start.
    private var isStartingCapture = false
    /// Sources of the current recording that delivered sound at least once.
    @ObservationIgnored private var heardDeviceIDs: Set<String> = []
    /// Fills `silentDevices` once `silenceWarningDelay` has passed.
    @ObservationIgnored private var silenceCheck: Task<Void, Never>?
    /// Fed by whichever of preparing and transcribing is running.
    private var progressEstimator = RemainingTimeEstimator()
    /// Per-track progress of the transcription in flight.
    @ObservationIgnored private var transcriptionProgress: TranscriptionProgress?

    /// One recording from start to stop, across all of its sources.
    private struct Session {
        let id: UUID
        let sources: [Source]
        let startedAt: Date

        var devices: [AudioInputDevice] { sources.map(\.device) }
    }

    /// One input of a session.
    private struct Source: Sendable {
        let device: AudioInputDevice
        let capture: any AudioCapturing
        /// Drains the capture stream off the main actor and returns the track.
        let consumer: Task<CaptureResult, Never>
        /// Feeds the audio to a live session, if the engine transcribes live. Returns the error
        /// that stopped it early, if any.
        let live: Task<(any Error)?, Never>?
    }

    /// Audio the consumer just added to a track, on its way to the live session.
    private struct LiveFeed: Sendable {
        let samples: [Float]
        /// The track's `startHostTime`.
        let startHostTime: TimeInterval?
    }

    /// Everything a capture stream produced, plus the error that ended it early, if any.
    private struct CaptureResult: Sendable {
        var track: AudioTrack
        var error: (any Error)?
    }

    /// A finished source's audio, positioned on the recording's timeline.
    private struct RecordedTrack: Sendable {
        let device: AudioInputDevice
        /// Empty when the engine transcribes live.
        let samples: [Float]
        let duration: TimeInterval
        /// Seconds from the start of the recording to the track's first sample.
        let offset: TimeInterval

        var end: TimeInterval { offset + duration }
    }

    /// Combines the progress of a recording's tracks, each weighted by its length. speech-swift
    /// transcribes them one after another, so the total keeps moving at about the same pace.
    private struct TranscriptionProgress {
        let sessionID: UUID
        let sampleCounts: [Int]
        var fractions: [Double]

        init(sessionID: UUID, tracks: [RecordedTrack]) {
            self.sessionID = sessionID
            sampleCounts = tracks.map(\.samples.count)
            fractions = Array(repeating: 0, count: tracks.count)
        }

        var total: Double {
            let samples = Double(sampleCounts.reduce(0, +))
            guard samples > 0 else { return 0 }
            return zip(sampleCounts, fractions).reduce(0) { $0 + Double($1.0) * $1.1 } / samples
        }
    }

    /// - Parameters:
    ///   - preferredDeviceIDs: Devices to select when they're available, e.g. the user's last choice.
    ///   - now: Clock used for recording start times. Injectable for tests.
    public init(
        deviceProvider: any AudioDeviceProvider,
        captureFactory: any AudioCaptureFactory,
        engine: any TranscriptionEngine,
        noteWriter: (any NoteWriting)?,
        summarizer: (any Summarizer)? = nil,
        options: TranscriptionOptions = .init(),
        sourceLabels: SourceLabels = .init(),
        preferredDeviceIDs: [String] = [],
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.deviceProvider = deviceProvider
        self.captureFactory = captureFactory
        self.engine = engine
        self.isModelDownloaded = engine.isDownloaded
        self.noteWriter = noteWriter
        self.summarizer = summarizer
        self.options = options
        self.sourceLabels = sourceLabels
        self.preferredDeviceIDs = preferredDeviceIDs
        self.now = now
    }

    // MARK: - Devices

    /// Selects the devices for the next recording and remembers them as preferred. Ignored while
    /// recording, and for an empty list. Returns whether the selection was applied.
    @discardableResult
    public func selectDevices(_ selection: [AudioInputDevice]) -> Bool {
        guard !isRecording, !isCapturing, !selection.isEmpty else { return false }
        preferredDeviceIDs = selection.map(\.id)
        // Devices that vanished since the menu was drawn are resolved like any other missing one.
        selectedDevices = Self.resolveSelection(preferredIDs: preferredDeviceIDs, in: devices)
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

    private func applyDevices(_ list: [AudioInputDevice]) {
        devices = list
        reconcileSelection()
    }

    private var isCapturing: Bool { session != nil || isStartingCapture }

    /// Re-resolves the selection against `devices`. Skipped mid-capture so a vanished device
    /// surfaces as a capture error instead of silently switching inputs.
    private func reconcileSelection() {
        guard !isCapturing else { return }
        let resolved = Self.resolveSelection(preferredIDs: preferredDeviceIDs, in: devices)
        if resolved != selectedDevices {
            selectedDevices = resolved
        }
    }

    /// The preferred devices that are present. A preferred microphone that's missing is replaced by
    /// the default microphone, so unplugging a headset doesn't silently drop the user's voice. With
    /// nothing preferred or available, the default microphone, else the first device.
    nonisolated static func resolveSelection(
        preferredIDs: [String],
        in devices: [AudioInputDevice]
    ) -> [AudioInputDevice] {
        let defaultMicrophone =
            devices.first { $0.kind == .microphone && $0.isDefault }
            ?? devices.first { $0.kind == .microphone }

        var ids = Set<String>()
        for id in preferredIDs {
            if devices.contains(where: { $0.id == id }) {
                ids.insert(id)
            } else if id != AudioInputDevice.systemAudioID, let defaultMicrophone {
                ids.insert(defaultMicrophone.id)
            }
        }
        if ids.isEmpty, let fallback = defaultMicrophone ?? devices.first {
            ids.insert(fallback.id)
        }
        return devices.filter { ids.contains($0.id) }
    }

    // MARK: - Engine

    /// Downloads/loads the model ahead of the first recording, reporting progress via `phase`.
    /// Stopped by `cancelPreparation()` or by cancelling the calling task.
    public func prepareEngine() async {
        guard isIdle else { return }

        progressEstimator = RemainingTimeEstimator()
        progressEstimator.add(progress: 0, at: now())
        phase = .preparingModel(progress: 0)
        let preparation = Task { [engine] in
            // Progress arrives on arbitrary threads; hop to the main actor before touching state.
            try await engine.prepare { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.updatePreparationProgress(progress)
                }
            }
        }
        self.preparation = preparation
        let result = await withTaskCancellationHandler {
            await preparation.result
        } onCancel: {
            preparation.cancel()
        }

        // After a cancel, a newer preparation may own `phase` already.
        guard self.preparation == preparation else { return }
        self.preparation = nil
        // Checked on every outcome: a failed or cancelled download may still have finished.
        isModelDownloaded = engine.isDownloaded
        switch result {
        case .success:
            logger.info("Transcription engine ready")
            phase = .idle
        case .failure where preparation.isCancelled:
            logger.info("Preparing engine cancelled")
            phase = .idle
        case .failure(let error):
            logger.error("Preparing engine failed: \(error.localizedDescription, privacy: .public)")
            failWithModelError(error)
        }
    }

    /// Stops an in-progress model download. Files already fetched are kept, so the next
    /// `prepareEngine()` (or recording) resumes from them.
    public func cancelPreparation() {
        guard case .preparingModel = phase, let preparation else { return }
        preparation.cancel()
        self.preparation = nil
        isModelDownloaded = engine.isDownloaded
        phase = .idle
    }

    /// Deletes the downloaded model to free disk space. Recording is unavailable until it's
    /// downloaded again. Ignored unless idle with the model on disk.
    public func deleteModel() async {
        guard isIdle, isModelDownloaded else { return }
        isDeletingModel = true
        do {
            try await engine.deleteModel()
            logger.info("Deleted transcription model")
            phase = .idle
        } catch {
            logger.error("Deleting model failed: \(error.localizedDescription, privacy: .public)")
            failWithModelError(error)
        }
        // Checked either way: a failed delete may have removed some files.
        isModelDownloaded = engine.isDownloaded
        isDeletingModel = false
    }

    private func failWithModelError(_ error: any Error) {
        phase = .failed(message: error.localizedDescription)
        modelError = error.localizedDescription
    }

    private func updatePreparationProgress(_ progress: Double) {
        guard case .preparingModel = phase, progress.isFinite else { return }
        let clamped = min(max(progress, 0), 1)
        progressEstimator.add(progress: clamped, at: now())
        phase = .preparingModel(progress: clamped)
    }

    // MARK: - Recording

    public func startRecording() async {
        guard canStartRecording else { return }
        let devices = selectedDevices
        isStartingCapture = true

        let startedCaptures: [StartedCapture]
        do {
            startedCaptures = try await startCaptures(for: devices)
        } catch {
            logger.error("Starting capture failed: \(error.localizedDescription, privacy: .public)")
            isStartingCapture = false
            phase = .failed(message: error.localizedDescription)
            reconcileSelection()
            return
        }

        let sessionID = UUID()
        let startedAt = now()
        let transcribesLive = engine.transcribesLive
        let options = options
        let sources = startedCaptures.enumerated().map { index, started -> Source in
            let stream = started.stream
            let deviceID = started.device.id
            let feed = transcribesLive ? AsyncStream<LiveFeed>.makeStream() : nil
            let consumer = Task.detached(priority: .userInitiated) { [weak self] () async -> CaptureResult in
                var track = AudioTrack(keepsSamples: !transcribesLive)
                var meter = LevelMeter()
                var unfed: [Float] = []
                defer {
                    if !unfed.isEmpty {
                        feed?.continuation.yield(LiveFeed(samples: unfed, startHostTime: track.startHostTime))
                    }
                    feed?.continuation.finish()
                }
                do {
                    for try await chunk in stream {
                        // Including silence filled into a gap, so the live session's clock stays in
                        // step with the track's.
                        let added = track.append(chunk)
                        if feed != nil {
                            unfed.append(contentsOf: added)
                            if unfed.count >= RecordingCoordinator.liveFeedSampleCount {
                                feed?.continuation.yield(LiveFeed(samples: unfed, startHostTime: track.startHostTime))
                                unfed.removeAll(keepingCapacity: true)
                            }
                        }
                        // Fire and forget, so a busy main actor never holds up capture.
                        if let level = meter.add(chunk) {
                            Task { @MainActor [weak self] in
                                self?.updateLevel(level, of: deviceID, sessionID: sessionID)
                            }
                        }
                    }
                } catch {
                    return CaptureResult(track: track, error: error)
                }
                return CaptureResult(track: track, error: nil)
            }
            let live = feed.map { feed in
                Task { [weak self] () -> (any Error)? in
                    guard let self else { return nil }
                    return await self.transcribeLive(feed.stream, source: index, options: options)
                }
            }
            return Source(device: started.device, capture: started.capture, consumer: consumer, live: live)
        }
        session = Session(id: sessionID, sources: sources, startedAt: startedAt)
        if transcribesLive {
            let labels: [String?] =
                devices.count > 1 ? devices.map { sourceLabels.label(for: $0, among: devices) } : [nil]
            liveTranscript = LiveTranscript(speakers: labels)
            showsLiveTranscript = true
        }
        isStartingCapture = false
        silenceCheck = Task { [weak self, silenceWarningDelay] in
            try? await Task.sleep(for: silenceWarningDelay)
            guard !Task.isCancelled else { return }
            self?.flagSilentDevices(sessionID: sessionID)
        }
        phase = .recording(startedAt: startedAt)
        let names = devices.map(\.name).joined(separator: " + ")
        logger.info("Recording started on \(names, privacy: .public)")

        // A stream can also end without `stopRecording()`: the device disappears, permission is
        // revoked, or the user stops capture from the system's menu bar indicator. Any source
        // ending ends the whole recording, and so does live transcription failing, since the note
        // would miss everything after.
        for source in sources {
            let consumer = source.consumer
            Task { [weak self] in
                _ = await consumer.value
                await self?.captureDidEnd(sessionID: sessionID)
            }
            if let live = source.live {
                Task { [weak self] in
                    if await live.value != nil { await self?.captureDidEnd(sessionID: sessionID) }
                }
            }
        }
    }

    /// Feeds one input's audio to a live session and adds what it recognizes to `liveTranscript`,
    /// until the input ends. Returns the error that stopped it early, if any.
    private func transcribeLive(
        _ feed: AsyncStream<LiveFeed>,
        source index: Int,
        options: TranscriptionOptions
    ) async -> (any Error)? {
        do {
            // Loads the model if it isn't yet; the feed buffers the audio meanwhile.
            let live = try await engine.makeLiveSession(options: options)
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

    private typealias CaptureStream = AsyncThrowingStream<AudioChunk, any Error>

    private struct StartedCapture {
        let device: AudioInputDevice
        let capture: any AudioCapturing
        let stream: CaptureStream
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

    /// Stops capture, transcribes, writes the note and updates `lastNoteURL`.
    public func stopRecording() async {
        guard let session else { return }
        // Clearing the session first makes repeated stops and the end-of-stream handlers no-ops.
        self.session = nil
        resetLevels()

        // An error racing a user-initiated stop doesn't matter; keep whatever was captured.
        let results = await endCaptures(of: session)
        await finish(session, results: results, interruption: nil)
    }

    /// Stops every capture of `session` and collects what each one recorded. Live sessions are
    /// waited for while they transcribe the rest of their input; an error that stopped one counts
    /// as its capture's.
    private func endCaptures(of session: Session) async -> [CaptureResult] {
        await withTaskGroup(of: Void.self) { group in
            for capture in session.sources.map(\.capture) {
                group.addTask { await capture.stop() }
            }
        }
        var results: [CaptureResult] = []
        for source in session.sources {
            results.append(await source.consumer.value)
        }
        if session.sources.contains(where: { $0.live != nil }) {
            phase = .transcribing(progress: 0)
        }
        for (index, source) in session.sources.enumerated() {
            guard let live = source.live, let error = await live.value else { continue }
            results[index].error = results[index].error ?? error
        }
        return results
    }

    /// Transcribes and saves a finished recording. If capture ended with `interruption`, the
    /// partial recording is still saved and the error is surfaced afterwards.
    private func finish(_ session: Session, results: [CaptureResult], interruption: (any Error)?) async {
        reconcileSelection()
        defer {
            showsLiveTranscript = false
            liveTranscript = LiveTranscript(speakers: [])
        }

        let offsets = AudioTrack.startOffsets(of: results.map(\.track))
        let tracks = session.sources.indices.map { index in
            RecordedTrack(
                device: session.sources[index].device,
                samples: results[index].track.samples,
                duration: results[index].track.duration,
                offset: offsets[index]
            )
        }
        let duration = tracks.map(\.end).max() ?? 0
        guard duration >= Self.minimumRecordingDuration else {
            logger.info("Discarding \(duration, format: .fixed(precision: 2)) s recording as too short")
            phase = interruption.map { Phase.failed(message: $0.localizedDescription) } ?? .idle
            return
        }

        progressEstimator = RemainingTimeEstimator()
        progressEstimator.add(progress: 0, at: now())
        phase = .transcribing(progress: 0)
        do {
            let transcript: Transcript
            if engine.transcribesLive {
                transcript = transcriptFromLiveText(tracks, session: session)
            } else if let track = tracks.first, tracks.count == 1 {
                transcriptionProgress = TranscriptionProgress(sessionID: session.id, tracks: tracks)
                transcript = try await engine.transcribe(
                    track.samples,
                    options: options,
                    progress: progressHandler(track: 0, sessionID: session.id)
                )
            } else {
                transcript = try await transcribeSeparately(tracks, session: session)
            }
            let summary = await summarize(transcript)
            let note = Note(
                title: Self.noteTitle(for: session.startedAt),
                createdAt: session.startedAt,
                duration: duration,
                sources: session.devices,
                engine: engine.info,
                transcript: transcript,
                summary: summary
            )
            // The folder can go away mid-recording, e.g. when its drive is disconnected.
            guard let noteWriter else { throw NoteWritingError.noFolder }
            let url = try await noteWriter.write(note)
            lastNoteURL = url
            logger.info("Wrote note to \(url.path(percentEncoded: false), privacy: .private)")
            if let interruption {
                phase = .failed(message: Self.interruptedMessage(for: interruption))
                // A live model that failed to load needs the same retry as an offline one.
                if case TranscriptionError.modelUnavailable = interruption {
                    modelError = interruption.localizedDescription
                }
            } else {
                phase = .idle
            }
        } catch {
            logger.error("Finishing recording failed: \(error.localizedDescription, privacy: .public)")
            if case TranscriptionError.modelUnavailable = error {
                failWithModelError(error)
            } else {
                phase = .failed(message: error.localizedDescription)
            }
        }
    }

    /// The transcript's summary, or `nil` if there's no summarizer, it isn't available or it
    /// fails. The note is saved either way, so a failure is only logged.
    private func summarize(_ transcript: Transcript) async -> NoteSummary? {
        guard let summarizer, !transcript.isEmpty else { return nil }
        let name = summarizer.info.displayName
        if case .unavailable(let reason) = summarizer.availability {
            logger.info("Not summarizing, \(name, privacy: .public) is unavailable: \(reason, privacy: .public)")
            return nil
        }
        phase = .summarizing
        do {
            let summary = try await summarizer.summarize(transcript)
            return summary.isEmpty ? nil : summary
        } catch {
            logger.error(
                "Summarizing with \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// The note's transcript from what the live sessions recognized: per source like
    /// `transcribeSeparately`, merged by time when there are several.
    private func transcriptFromLiveText(_ tracks: [RecordedTrack], session: Session) -> Transcript {
        let transcripts = tracks.indices.map { index in
            let segments = liveTranscript.segments(fromSource: index).map { segment in
                var segment = segment
                segment.start += tracks[index].offset
                segment.end += tracks[index].offset
                return segment
            }
            return Transcript(segments: segments, language: options.language)
        }
        guard tracks.count > 1 else { return transcripts.first ?? Transcript(segments: []) }
        let sources = zip(tracks, transcripts).map { track, transcript in
            SourceTranscript(
                device: track.device,
                label: sourceLabels.label(for: track.device, among: session.devices),
                transcript: transcript
            )
        }
        return TranscriptMerger.merge(sources)
    }

    /// Transcribes each track on its own, so speech stays attributed to its source, then merges the
    /// labeled transcripts by time. Tracks are submitted together; the engine decides how many it
    /// runs at once (speech-swift runs one at a time, since they share the GPU anyway).
    private func transcribeSeparately(_ tracks: [RecordedTrack], session: Session) async throws -> Transcript {
        let engine = engine
        let options = options
        let sourceLabels = sourceLabels
        let audible = tracks.filter {
            Double($0.samples.count) / AudioChunk.sampleRate >= Self.minimumRecordingDuration
        }
        for track in tracks {
            let duration = Double(track.samples.count) / AudioChunk.sampleRate
            logger.info(
                "Track \(track.device.name, privacy: .public): \(duration, format: .fixed(precision: 1)) s starting at \(track.offset, format: .fixed(precision: 2)) s"
            )
        }

        transcriptionProgress = TranscriptionProgress(sessionID: session.id, tracks: audible)
        let transcripts = try await withThrowingTaskGroup(
            of: (Int, Transcript).self,
            returning: [Transcript].self
        ) { group in
            for (index, track) in audible.enumerated() {
                let progress = progressHandler(track: index, sessionID: session.id)
                group.addTask {
                    var transcript = try await engine.transcribe(track.samples, options: options, progress: progress)
                    for i in transcript.segments.indices {
                        transcript.segments[i].start += track.offset
                        transcript.segments[i].end += track.offset
                    }
                    return (index, transcript)
                }
            }
            var transcripts = [Transcript?](repeating: nil, count: audible.count)
            for try await (index, transcript) in group {
                transcripts[index] = transcript
            }
            return transcripts.compactMap { $0 }
        }

        let sources = zip(audible, transcripts).map { track, transcript in
            SourceTranscript(
                device: track.device,
                label: sourceLabels.label(for: track.device, among: session.devices),
                transcript: transcript
            )
        }
        return TranscriptMerger.merge(sources)
    }

    /// Forwards one track's progress to `updateTranscriptionProgress` from any thread.
    private func progressHandler(track index: Int, sessionID: UUID) -> @Sendable (Double) -> Void {
        { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.updateTranscriptionProgress(progress, track: index, sessionID: sessionID)
            }
        }
    }

    private func updateTranscriptionProgress(_ progress: Double, track index: Int, sessionID: UUID) {
        // Updates still in flight when the transcription ends are dropped.
        guard case .transcribing = phase, var transcriptionProgress, transcriptionProgress.sessionID == sessionID,
            transcriptionProgress.fractions.indices.contains(index), progress.isFinite
        else { return }
        transcriptionProgress.fractions[index] = max(transcriptionProgress.fractions[index], min(max(progress, 0), 1))
        self.transcriptionProgress = transcriptionProgress
        let total = transcriptionProgress.total
        progressEstimator.add(progress: total, at: now())
        phase = .transcribing(progress: total)
    }

    public func toggleRecording() async {
        if isRecording {
            await stopRecording()
        } else {
            await startRecording()
        }
    }

    /// Clears a `.failed` phase.
    public func dismissError() {
        if case .failed = phase {
            phase = .idle
        }
    }

    private func captureDidEnd(sessionID: UUID) async {
        // A stop already in progress owns the session.
        guard let session, session.id == sessionID else { return }
        self.session = nil
        resetLevels()

        let results = await endCaptures(of: session)
        let error = results.lazy.compactMap(\.error).first
        if let error {
            logger.error("Capture failed: \(error.localizedDescription, privacy: .public)")
        } else {
            logger.info("Capture ended by the system")
        }
        await finish(session, results: results, interruption: error)
    }

    // MARK: - Levels

    private func updateLevel(_ level: InputLevel, of deviceID: String, sessionID: UUID) {
        // Levels still in flight when the recording ends are dropped.
        guard session?.id == sessionID else { return }
        inputLevels[deviceID] = level
        if !level.isSilent, heardDeviceIDs.insert(deviceID).inserted {
            silentDevices.removeAll { $0.id == deviceID }
        }
    }

    private func flagSilentDevices(sessionID: UUID) {
        guard let session, session.id == sessionID else { return }
        let silent = session.devices.filter { !heardDeviceIDs.contains($0.id) }
        guard !silent.isEmpty else { return }
        silentDevices = silent
        let names = silent.map(\.name).joined(separator: ", ")
        logger.info("No sound yet from \(names, privacy: .public)")
    }

    private func resetLevels() {
        silenceCheck?.cancel()
        silenceCheck = nil
        heardDeviceIDs = []
        inputLevels = [:]
        silentDevices = []
    }

    nonisolated static func interruptedMessage(for error: any Error) -> String {
        "Recording stopped early. \(error.localizedDescription) The note has everything recorded until then."
    }

    nonisolated static func noteTitle(for date: Date) -> String {
        "Recording \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}
