@preconcurrency internal import AudioCommon
import Foundation
import MixdownCore
@preconcurrency internal import SpeechEnhancement
import Synchronization
import os

/// Echo cancellation with speech-swift's LocalVQE v1.4-AEC: it finds the delay between the system
/// audio and its echo in the microphone (up to about a second), removes the echo with an adaptive
/// filter, and what that leaves with a small Core ML model. The model (about 1 MB) is downloaded
/// the first time.
///
/// Keeps one canceller loaded ahead, so a microphone gets one without waiting.
public final class LocalVQEEchoCancellation: EchoCancellation {
    /// How long to wait after a failed load before trying again, e.g. when offline the first time.
    private static let retryDelay: TimeInterval = 60

    private struct State {
        var spare: LocalVQEFrameCanceller?
        var isLoading = false
        var lastFailure: Date?
    }

    private let state = Mutex(State())

    public init() {}

    public func prepare() {
        let startsLoading = state.withLock { state -> Bool in
            guard state.spare == nil, !state.isLoading else { return false }
            if let lastFailure = state.lastFailure, Date().timeIntervalSince(lastFailure) < Self.retryDelay {
                return false
            }
            state.isLoading = true
            return true
        }
        guard startsLoading else { return }
        Task.detached(priority: .userInitiated) { [self] in
            let canceller = await LocalVQEFrameCanceller.load()
            self.state.withLock { state in
                state.spare = canceller
                state.isLoading = false
                state.lastFailure = canceller == nil ? Date() : nil
            }
        }
    }

    public func takeCanceller() -> (any EchoCanceller)? {
        let canceller = state.withLock { state -> LocalVQEFrameCanceller? in
            defer { state.spare = nil }
            return state.spare
        }
        prepare()
        return canceller
    }
}

/// One `LocalVQEEchoCanceller`, for one microphone capture.
///
/// `@unchecked Sendable`: handed from the loading task to the capture that takes it, which makes
/// its calls one after another.
private final class LocalVQEFrameCanceller: EchoCanceller, @unchecked Sendable {
    private static let logger = Logger(subsystem: "app.mixdown", category: "echo")

    let frameSize = LocalVQEEchoCanceller.frameSize
    let latency = LocalVQEEchoCanceller.algorithmicLatencySamples
    private let canceller: LocalVQEEchoCanceller
    private var loggedDelay = 0

    private init(canceller: LocalVQEEchoCanceller) {
        self.canceller = canceller
    }

    /// Loads from the cache, else downloads. `nil` if neither works; the reason is logged.
    static func load() async -> LocalVQEFrameCanceller? {
        do {
            let repositoryID = LocalVQEEchoCanceller.defaultModelId
            let directory = try ModelCache.directory(for: repositoryID, base: SpeechSwiftEngine.modelDirectory())
            let canceller = try await ModelCache.loadPreferringCache(
                repositoryID,
                cacheLooksComplete: ModelCache.contains(
                    ["config.json", "LocalVQEAECResidualMask.mlmodelc", "LocalVQEAECFrontend.npz"],
                    in: directory
                ),
                progress: { _ in }
            ) { offline, _ in
                try await LocalVQEEchoCanceller.fromPretrained(cacheDir: directory, offlineMode: offline)
            }
            return LocalVQEFrameCanceller(canceller: canceller)
        } catch {
            logger.error("Loading echo cancellation failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func process(microphone: [Float], reference: [Float]) throws -> [Float] {
        let output = try canceller.processFrame(microphone: microphone, reference: reference)
        // Logged when the delay is found, which says the echo was recognized and how late it is.
        // Counted from the reference as given, which `EchoRemover` reads 100 ms early.
        let delay = canceller.currentDelaySamples
        if delay != loggedDelay {
            loggedDelay = delay
            let milliseconds = Double(delay) / AudioChunk.sampleRate * 1000
            Self.logger.info(
                "Echo delay \(milliseconds, format: .fixed(precision: 0)) ms after the reference, confidence \(self.canceller.delayConfidence, format: .fixed(precision: 1))"
            )
        }
        return output
    }
}
