import Foundation

/// Where Mixdown keeps the models it downloads, speech and language models alike, so they're all
/// in one place.
public enum ModelDirectory {
    /// `Application Support/Mixdown/Models`, inside the container when sandboxed. `nil` if there's
    /// no Application Support directory, which callers report with their own error.
    public static var url: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Mixdown/Models", isDirectory: true)
    }
}
