import Foundation
import Observation

/// Downloads and deletes a model Mixdown keeps on disk, such as the summary model or the one that
/// tells speakers apart, for Settings to show. Downloads keep going while Settings is closed.
@MainActor @Observable
final class ModelDownload {
    /// Whether the model is on disk. Kept here so views update when a download finishes.
    private(set) var isDownloaded: Bool
    /// How much has downloaded, 0...1, while it downloads; `nil` otherwise.
    private(set) var progress: Double?
    /// Why the model couldn't be downloaded or deleted, until the next try.
    private(set) var error: String?
    private(set) var isDeleting = false

    /// How errors name the model, e.g. "the speaker model".
    private let name: String
    @ObservationIgnored private let checkDownloaded: @MainActor () -> Bool
    @ObservationIgnored private let fetch: @Sendable (@escaping @Sendable (Double) -> Void) async throws -> Void
    @ObservationIgnored private let remove: @Sendable () async throws -> Void
    @ObservationIgnored private var download: Task<Void, Never>?

    init(
        name: String,
        isDownloaded: @escaping @MainActor () -> Bool,
        download: @escaping @Sendable (_ progress: @escaping @Sendable (Double) -> Void) async throws -> Void,
        delete: @escaping @Sendable () async throws -> Void
    ) {
        self.name = name
        self.checkDownloaded = isDownloaded
        self.fetch = download
        self.remove = delete
        self.isDownloaded = isDownloaded()
    }

    /// Downloads the model, showing progress in `progress`. Ignored while it's downloading.
    func start() {
        guard download == nil else { return }
        error = nil
        progress = 0
        let reportProgress: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in
                guard let self, let progress = self.progress else { return }
                // Hops to the main actor can arrive out of order.
                self.progress = max(progress, fraction)
            }
        }
        download = Task { [weak self, fetch] in
            var failure: String?
            do {
                try await fetch(reportProgress)
            } catch {
                failure = "Couldn't download \(self?.name ?? "the model"): \(error.localizedDescription)"
            }
            // Cancelled: `cancel()` reset the state.
            guard !Task.isCancelled, let self else { return }
            self.download = nil
            self.progress = nil
            self.error = failure
            self.isDownloaded = self.checkDownloaded()
        }
    }

    /// Checks the disk again, for when the model may have been downloaded or removed elsewhere: by
    /// a recording that needed it, say, or in Finder. Left alone while it downloads.
    func refresh() {
        guard download == nil, !isDeleting else { return }
        isDownloaded = checkDownloaded()
    }

    /// Stops downloading. What's on disk is kept, so a new download resumes.
    func cancel() {
        download?.cancel()
        download = nil
        progress = nil
    }

    /// Removes the model's files.
    func delete() async {
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await remove()
        } catch {
            self.error = "Couldn't delete \(name): \(error.localizedDescription)"
        }
        isDownloaded = checkDownloaded()
    }
}
