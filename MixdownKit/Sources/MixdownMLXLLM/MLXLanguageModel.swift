import Foundation

/// The open language models Mixdown can summarize with on MLX, downloaded from Hugging Face.
///
/// Raw values are persisted in user defaults; never change them.
public enum MLXLanguageModel: String, CaseIterable, Sendable, Identifiable {
    /// Qwen3 1.7B, 4-bit. Quick and light; summaries are plainer.
    case qwen3Small = "qwen3-1.7b"
    /// Qwen3 4B Instruct (2507), 4-bit. Answers without thinking first, so it's quick for its size.
    case qwen3Medium = "qwen3-4b-instruct-2507"
    /// Qwen3.5 4B, 4-bit. The newer generation at the same size.
    case qwen35Medium = "qwen3.5-4b"
    /// Qwen3 8B, 4-bit. The most accurate, at twice the memory and time.
    case qwen3Large = "qwen3-8b"

    public static var `default`: MLXLanguageModel { .qwen3Medium }

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .qwen3Small: "Qwen3 1.7B"
        case .qwen3Medium: "Qwen3 4B Instruct"
        case .qwen35Medium: "Qwen3.5 4B"
        case .qwen3Large: "Qwen3 8B"
        }
    }

    /// What the model is chosen for, e.g. "Fast".
    public var purpose: String {
        switch self {
        case .qwen3Small: "Fast"
        case .qwen3Medium: "Balanced"
        case .qwen35Medium: "Newest"
        case .qwen3Large: "Best"
        }
    }

    /// About how much the download is, for the UI.
    public var downloadSize: String {
        switch self {
        case .qwen3Small: "1 GB"
        case .qwen3Medium: "2.3 GB"
        case .qwen35Medium: "3 GB"
        case .qwen3Large: "4.6 GB"
        }
    }

    /// Hugging Face repository with the weights. Changing it triggers a fresh download.
    var repositoryID: String {
        switch self {
        case .qwen3Small: "mlx-community/Qwen3-1.7B-4bit"
        case .qwen3Medium: "mlx-community/Qwen3-4B-Instruct-2507-4bit"
        case .qwen35Medium: "mlx-community/Qwen3.5-4B-4bit"
        case .qwen3Large: "mlx-community/Qwen3-8B-4bit"
        }
    }
}
