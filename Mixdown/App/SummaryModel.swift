import MixdownCore
import MixdownFoundationModels
import MixdownMLXLLM

/// A language model to summarize with: Apple's, or an open model run with MLX.
enum SummaryModel: Hashable, Identifiable {
    /// The model behind Apple Intelligence. Part of macOS; needs Apple Intelligence turned on.
    case appleIntelligence
    case mlx(MLXLanguageModel)

    static var `default`: SummaryModel { .appleIntelligence }

    /// Every model, in the order Settings lists them.
    static var all: [SummaryModel] { [.appleIntelligence] + MLXLanguageModel.allCases.map(Self.mlx) }

    /// Persisted in user defaults; never change it.
    var rawValue: String {
        switch self {
        case .appleIntelligence: "apple-intelligence"
        case .mlx(let model): "mlx-\(model.rawValue)"
        }
    }

    init?(rawValue: String) {
        if rawValue == Self.appleIntelligence.rawValue {
            self = .appleIntelligence
        } else if rawValue.hasPrefix("mlx-"), let model = MLXLanguageModel(rawValue: String(rawValue.dropFirst(4))) {
            self = .mlx(model)
        } else {
            return nil
        }
    }

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleIntelligence: "Apple Intelligence"
        case .mlx(let model): model.displayName
        }
    }

    /// "Balanced · Qwen3 4B Instruct": what the model is for, then which it is.
    var label: String {
        switch self {
        case .appleIntelligence: displayName
        case .mlx(let model): "\(model.purpose) · \(model.displayName)"
        }
    }

    /// Whether macOS provides the model rather than Mixdown downloading it.
    var isManagedBySystem: Bool { self == .appleIntelligence }

    func makeSummarizer() -> any Summarizer {
        switch self {
        case .appleIntelligence: AppleIntelligenceSummarizer()
        case .mlx(let model): MLXSummarizer(model: model)
        }
    }
}
