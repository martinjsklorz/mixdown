import MixdownNotes
import SwiftUI

/// Mixdown Help: the topics in a searchable sidebar, the chosen one rendered like a note.
struct HelpView: View {
    static let windowID = "help"

    @Environment(MainNavigation.self) private var navigation

    var body: some View {
        @Bindable var navigation = navigation
        let topics = HelpTopic.search(navigation.helpSearchText)

        NavigationSplitView {
            List(
                topics,
                selection: Binding(
                    get: { navigation.helpTopic },
                    set: { topic in if let topic { navigation.helpTopic = topic } }
                )
            ) { topic in
                Label(topic.title, systemImage: topic.systemImage)
            }
            .overlay {
                if topics.isEmpty {
                    ContentUnavailableView.search(text: navigation.helpSearchText)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            HelpTopicView(topic: navigation.helpTopic)
        }
        .searchable(text: $navigation.helpSearchText, placement: .sidebar, prompt: "Search Help")
        .navigationTitle("Mixdown Help")
        // Links between topics stay in this window.
        .environment(
            \.openURL,
            OpenURLAction { url in
                guard let topic = HelpTopic(url: url) else { return .systemAction }
                // Links are opened on the main thread.
                MainActor.assumeIsolated { navigation.helpTopic = topic }
                return .handled
            }
        )
    }
}

private struct HelpTopicView: View {
    let topic: HelpTopic

    var body: some View {
        let blocks = topic.blocks

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(topic.title)
                    .font(.largeTitle.bold())
                    .padding(.bottom, 20)

                ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                    MarkdownBlockView(block: block)
                        .padding(
                            .top,
                            index == 0 ? 0 : MarkdownBlockView.spacing(between: blocks[index - 1], and: block)
                        )
                }
            }
            // A comfortable line length when the window is wide.
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Start each topic at the top.
        .id(topic)
    }
}
