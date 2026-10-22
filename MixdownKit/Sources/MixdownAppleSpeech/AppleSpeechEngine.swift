@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import MixdownCore
import Speech
import Synchronization
import os

private let logger = Logger(subsystem: "app.mixdown", category: "transcription")

/// Transcribes with Apple's on-device speech model (`SpeechTranscriber`), the one behind the
/// transcripts in Notes and Voice Memos.
///
/// macOS downloads the model, one per language, keeps it up to date and shares it with other apps;
/// Mixdown never stores it. Needs a Mac that supports the model (see `isSupported`). The model
/// doesn't detect the language: without one, it uses the Mac's language. It doesn't label speakers
/// or translate.
public actor AppleSpeechEngine: TranscriptionEngine {
    public static let displayName = "Apple Speech"

    public nonisolated let info = TranscriptionEngineInfo(
        id: "apple-speech",
        displayName: AppleSpeechEngine.displayName
    )

    /// Whether this Mac can use the model at all, whatever the language.
    public static var isSupported: Bool { SpeechTranscriber.isAvailable }

    private struct State {
        /// `TranscriptionOptions.language`, from `languageDidChange(to:)`.
        var language: String?
        /// Languages (`nil` for the Mac's) whose model was installed when last checked.
        var installedLanguages: Set<String?> = []
    }

    /// Outside the actor, so `isDownloaded` can be read from the main actor without waiting.
    private nonisolated let state = Mutex(State())
    /// Transcriptions run one after another, as macOS only allows a few analyses at once.
    private let transcriptions = SerialTaskQueue()

    public init() {}

    public nonisolated var isDownloaded: Bool {
        state.withLock { $0.installedLanguages.contains($0.language) }
    }

    public nonisolated func languageDidChange(to language: String?) {
        state.withLock { $0.language = language }
    }

    /// Whether macOS has the model for `language` (`nil` for the Mac's), without downloading it.
    /// `false` for a language or Mac the model doesn't support.
    public static func isInstalled(language: String?) async -> Bool {
        guard isSupported else { return false }
        return (try? await AppleSpeech.isInstalled(language: language)) ?? false
    }

    public func refreshDownloadStatus() async {
        let language = currentLanguage
        // An unsupported language isn't installed either; `prepare` says why.
        setInstalled(await Self.isInstalled(language: language), for: language)
    }

    /// Asks macOS to download the model for the current language, if it isn't on the Mac already.
    /// Throws `TranscriptionError.modelUnavailable` on an unsupported Mac or language.
    public func prepare(progress: (@Sendable (Double) -> Void)?) async throws {
        let language = currentLanguage
        try await AppleSpeech.install(language: language, progress: progress)
        setInstalled(true, for: language)
        progress?(1)
    }

    /// Gives up Mixdown's claim on the current language's model. macOS removes it later, unless
    /// another app uses it.
    public func deleteModel() async throws {
        let language = currentLanguage
        try await AppleSpeech.release(language: language)
        setInstalled(false, for: language)
    }

    /// Transcribes 16 kHz mono samples into one segment per phrase the model reports. The language
    /// is `options.language`, else the Mac's.
    public func transcribe(
        _ samples: [Float],
        options: TranscriptionOptions,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> Transcript {
        guard !samples.isEmpty else {
            progress?(1)
            return Transcript(segments: [], language: options.language)
        }
        let transcript = try await transcriptions.run {
            try await AppleSpeech.transcribe(samples, language: options.language, progress: progress)
        }
        progress?(1)
        return transcript
    }

    // MARK: - Helpers

    private nonisolated var currentLanguage: String? {
        state.withLock { $0.language }
    }

    private nonisolated func setInstalled(_ installed: Bool, for language: String?) {
        state.withLock {
            if installed {
                _ = $0.installedLanguages.insert(language)
            } else {
                _ = $0.installedLanguages.remove(language)
            }
        }
    }
}

private enum AppleSpeech {
    /// Audio handed to the analyzer at a time.
    static let chunkDuration: TimeInterval = 10

    static func isInstalled(language: String?) async throws -> Bool {
        let transcriber = try await makeTranscriber(language: language)
        return await AssetInventory.status(forModules: [transcriber]) == .installed
    }

    static func install(language: String?, progress: (@Sendable (Double) -> Void)?) async throws {
        let transcriber = try await makeTranscriber(language: language)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            return
        }
        // The request reports progress as an `NSProgress`; poll it rather than observe it.
        let reporter = progress.map { progress in
            Task {
                while !Task.isCancelled {
                    progress(request.progress.fractionCompleted)
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }
        defer { reporter?.cancel() }
        do {
            try await withTaskCancellationHandler {
                try await request.downloadAndInstall()
            } onCancel: {
                request.progress.cancel()
            }
        } catch {
            try Task.checkCancellation()
            throw TranscriptionError.unavailable(error)
        }
        try Task.checkCancellation()
        let locale = transcriber.selectedLocales.first?.identifier ?? "?"
        logger.info("Apple speech model for \(locale, privacy: .public) installed")
    }

    static func release(language: String?) async throws {
        let locale = try await locale(for: language)
        _ = await AssetInventory.release(reservedLocale: locale)
        logger.info("Released Apple speech model for \(locale.identifier, privacy: .public)")
    }

    static func transcribe(
        _ samples: [Float],
        language: String?,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> Transcript {
        let transcriber = try await makeTranscriber(language: language)
        // macOS may have removed the model since it was downloaded. The coordinator fetches it again
        // before transcribing, with progress; this covers it going in between.
        try await install(language: language, progress: nil)

        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: AudioChunk.sampleRate,
                channels: 1,
                interleaved: false
            )
        else {
            throw TranscriptionError.failed("Couldn't create the 16 kHz audio format")
        }
        let converter = try await makeConverter(from: format, for: transcriber)
        let feed = AnalyzerFeed(samples: samples, format: format, converter: converter)
        // Pulled by the analyzer, so the recording is converted as it goes rather than all at once.
        let inputs = AsyncStream<AnalyzerInput>(unfolding: { feed.next() })

        let started = ContinuousClock.now
        let audioDuration = Double(samples.count) / AudioChunk.sampleRate
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let results = Task {
            var segments: [TranscriptSegment] = []
            for try await result in transcriber.results {
                let start = result.range.start.seconds
                let end = result.range.end.seconds
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty, start.isFinite, end.isFinite {
                    segments.append(TranscriptSegment(start: start, end: max(end, start), text: text))
                }
                if end.isFinite { progress?(min(end / audioDuration, 1)) }
            }
            return segments
        }

        let segments = try await withTaskCancellationHandler {
            do {
                if let lastSampleTime = try await analyzer.analyzeSequence(inputs) {
                    try await analyzer.finalizeAndFinish(through: lastSampleTime)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } catch {
                await analyzer.cancelAndFinishNow()
                results.cancel()
                if error is CancellationError { throw error }
                throw TranscriptionError.failed(error.localizedDescription)
            }
            if let error = feed.error { throw TranscriptionError.failed(error.localizedDescription) }
            return try await results.value
        } onCancel: {
            results.cancel()
        }
        try Task.checkCancellation()

        logger.info(
            "Transcribed \(audioDuration, format: .fixed(precision: 1)) s with Apple's speech model, \(segments.count) segments, \(String(describing: ContinuousClock.now - started), privacy: .public)"
        )
        let locale = transcriber.selectedLocales.first
        return Transcript(segments: segments, language: locale?.language.languageCode?.identifier)
    }

    /// Apple's converter on macOS 27, else `AudioFormatConverter` to the format the model prefers.
    private static func makeConverter(
        from format: AVAudioFormat,
        for transcriber: SpeechTranscriber
    ) async throws -> any AnalyzerInputConverting {
        if #available(macOS 27, *) {
            do {
                return try await AnalyzerInputConverter.converter(compatibleWith: [transcriber])
            } catch {
                throw TranscriptionError.failed(error.localizedDescription)
            }
        }
        guard
            let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber],
                considering: format
            )
        else {
            throw TranscriptionError.failed("No audio format for Apple's speech model")
        }
        return try AudioFormatConverter(from: format, to: analyzerFormat)
    }

    private static func makeTranscriber(language: String?) async throws -> SpeechTranscriber {
        let locale = try await locale(for: language)
        // Final results only, with no alternatives: the analyzer gets the whole recording at once.
        return SpeechTranscriber(locale: locale, preset: .transcription)
    }

    /// The model's locale for `language` (an ISO 639-1 code), or for the Mac's language without one.
    private static func locale(for language: String?) async throws -> Locale {
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionError.modelUnavailable("This Mac doesn't support Apple's speech model.")
        }
        let requested = language.map { Locale(identifier: $0) } ?? Locale.current
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            let name = Locale.current.localizedString(forIdentifier: requested.identifier) ?? requested.identifier
            throw TranscriptionError.modelUnavailable("Apple's speech model doesn't support \(name).")
        }
        return locale
    }
}

/// Hands a recording to the analyzer `AppleSpeech.chunkDuration` at a time, converted to the
/// analyzer's format. Only used from the input stream's `unfolding` closure, which runs one call
/// at a time.
private final class AnalyzerFeed: @unchecked Sendable {
    private let samples: [Float]
    private let format: AVAudioFormat
    private let converter: any AnalyzerInputConverting
    private var position = 0
    /// Converted audio not handed over yet. A piece can convert into several inputs, or none.
    private var pending: [AnalyzerInput] = []
    private var isFlushed = false
    /// Why the feed ended early, if it did.
    private(set) var error: (any Error)?

    init(samples: [Float], format: AVAudioFormat, converter: any AnalyzerInputConverting) {
        self.samples = samples
        self.format = format
        self.converter = converter
    }

    /// The next piece of audio, or `nil` once all of it has been handed over or conversion failed.
    func next() -> AnalyzerInput? {
        while pending.isEmpty, !isFlushed, error == nil {
            do {
                if position < samples.count {
                    pending = try converter.convert(nextBuffer())
                } else {
                    // Whatever the converter held back.
                    pending = try converter.flush()
                    isFlushed = true
                }
            } catch {
                self.error = error
            }
        }
        return pending.isEmpty ? nil : pending.removeFirst()
    }

    private func nextBuffer() throws -> AVAudioPCMBuffer {
        let count = min(Int(AppleSpeech.chunkDuration * format.sampleRate), samples.count - position)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
            let channel = buffer.floatChannelData?[0]
        else {
            throw TranscriptionError.failed("Out of memory for audio")
        }
        samples[position..<position + count].withUnsafeBufferPointer { piece in
            if let base = piece.baseAddress { channel.update(from: base, count: count) }
        }
        buffer.frameLength = AVAudioFrameCount(count)
        position += count
        return buffer
    }
}

/// Turns pieces of a recording into analyzer input, in order.
private protocol AnalyzerInputConverting {
    func convert(_ buffer: AVAudioPCMBuffer) throws -> [AnalyzerInput]
    /// Whatever the converter held back, after the last piece.
    func flush() throws -> [AnalyzerInput]
}

@available(macOS 27, *)
extension AnalyzerInputConverter: AnalyzerInputConverting {
    fileprivate func convert(_ buffer: AVAudioPCMBuffer) throws -> [AnalyzerInput] {
        try convert(buffer, at: nil)
    }
}

/// `AVAudioConverter` in place of `AnalyzerInputConverter`, which macOS 26 doesn't have.
private final class AudioFormatConverter: AnalyzerInputConverting {
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    /// `nil` when the analyzer takes the audio as it is.
    private let converter: AVAudioConverter?

    init(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) throws {
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        if inputFormat == outputFormat {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw TranscriptionError.failed("Can't convert audio to \(outputFormat) for Apple's speech model")
            }
            // Without priming, the converted audio isn't shifted, so the segments' times stay right.
            converter.primeMethod = .none
            self.converter = converter
        }
    }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> [AnalyzerInput] {
        guard let converter else { return [AnalyzerInput(buffer: buffer)] }
        return try run(converter, on: buffer, frames: buffer.frameLength)
    }

    func flush() throws -> [AnalyzerInput] {
        guard let converter else { return [] }
        return try run(converter, on: nil, frames: 0)
    }

    /// Converts `buffer`, or with `nil` ends the stream so the converter hands over what it held back.
    private func run(
        _ converter: AVAudioConverter,
        on buffer: AVAudioPCMBuffer?,
        frames: AVAudioFrameCount
    ) throws
        -> [AnalyzerInput]
    {
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        // Headroom for samples the converter held back from earlier pieces.
        let capacity = AVAudioFrameCount((Double(frames) * ratio).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw TranscriptionError.failed("Out of memory for audio")
        }
        // Hand the piece over once, then say more may come (or, flushing, that none will), so the
        // converter keeps its state between pieces.
        let pending = PendingBuffer(buffer)
        let isFlushing = buffer == nil
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if let buffer = pending.take() {
                inputStatus.pointee = .haveData
                return buffer
            }
            inputStatus.pointee = isFlushing ? .endOfStream : .noDataNow
            return nil
        }
        if status == .error {
            throw TranscriptionError.failed(conversionError?.localizedDescription ?? "Audio conversion failed")
        }
        return output.frameLength > 0 ? [AnalyzerInput(buffer: output)] : []
    }
}

/// One-shot holder for the converter's input block, which runs synchronously inside `convert`.
private final class PendingBuffer: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer?) {
        self.buffer = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}
