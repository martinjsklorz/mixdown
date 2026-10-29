import AppKit
import MixdownNotes

/// Lists matching help topics in the Help menu's search field, below the menu items it finds
/// itself. Mixdown has no Apple Help Book for the field to search instead.
final class HelpSearch: NSObject, NSUserInterfaceItemSearching {
    /// Opens the Help window at a topic, or searching for a string.
    private let showHelp: @MainActor @Sendable (HelpTopic?, String?) -> Void

    init(showHelp: @escaping @MainActor @Sendable (HelpTopic?, String?) -> Void) {
        self.showHelp = showHelp
    }

    func searchForItems(
        withSearch searchString: String,
        resultLimit: Int,
        matchedItemHandler handleMatchedItems: @escaping ([Any]) -> Void
    ) {
        // An empty search would list every topic.
        let topics = searchString.allSatisfy(\.isWhitespace) ? [] : HelpTopic.search(searchString)
        handleMatchedItems(Array(topics.prefix(resultLimit)))
    }

    func localizedTitles(forItem item: Any) -> [String] {
        guard let topic = item as? HelpTopic else { return [] }
        return [topic.title]
    }

    func performAction(forItem item: Any) {
        guard let topic = item as? HelpTopic else { return }
        Task { @MainActor [showHelp] in showHelp(topic, nil) }
    }

    /// "Show All Help Topics" at the bottom of the results.
    func showAllHelpTopics(forSearch searchString: String) {
        Task { @MainActor [showHelp] in showHelp(nil, searchString) }
    }
}
