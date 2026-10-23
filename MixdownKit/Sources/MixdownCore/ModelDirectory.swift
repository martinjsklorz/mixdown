import Foundation
import os

/// Where Mixdown keeps the models it downloads, speech and language models alike, so they're all
/// in one place.
public enum ModelDirectory {
    /// `Application Support/Mixdown/Models`, inside the container when sandboxed. `nil` if there's
    /// no Application Support directory, which callers report with their own error.
    public static var url: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Mixdown/Models", isDirectory: true)
    }

    /// The space every downloaded model takes up, partial downloads included. Apple's speech and
    /// language models aren't in here: macOS keeps those.
    public static var diskUsage: DiskUsage {
        url.map { DiskUsage.of($0) } ?? DiskUsage()
    }
}

extension ModelDirectory {
    /// Loads a model from disk without touching the network first, then falls back to an online
    /// load, which downloads what's missing and repairs what's damaged.
    ///
    /// Downloaders ask the Hub for the file list before loading, so starting offline keeps
    /// launches fast and makes downloaded models work without a connection. Files that are all
    /// there but don't load, such as a download cut short, would fail every offline load; the
    /// online load fetches them again. Progress is only forwarded for the online attempt, so a
    /// failed offline attempt doesn't leave the bar stuck partway.
    ///
    /// - Parameters:
    ///   - name: The model's name (e.g. its repository), for the log.
    ///   - cacheLooksComplete: Whether every file the model needs is on disk; checking files only.
    ///   - load: Loads the model, from disk only if `offline` is true.
    public static func loadPreferringCache<Model>(
        _ name: String,
        cacheLooksComplete: Bool,
        progress: @escaping @Sendable (Double) -> Void,
        load: (_ offline: Bool, _ progress: @escaping @Sendable (Double) -> Void) async throws -> Model
    ) async throws -> Model {
        if cacheLooksComplete {
            do {
                let model = try await load(true) { _ in }
                progress(1)
                modelLogger.info("Loaded \(name, privacy: .public) from disk")
                return model
            } catch let error as CancellationError {
                throw error
            } catch {
                try Task.checkCancellation()
                modelLogger.notice(
                    "\(name, privacy: .public) on disk unusable, downloading: \(String(describing: error), privacy: .public)"
                )
            }
        }
        modelLogger.info("Downloading \(name, privacy: .public)")
        let model = try await load(false, progress)
        progress(1)
        return model
    }
}
