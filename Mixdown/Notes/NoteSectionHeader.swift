import SwiftUI

/// A section's title, like "Pinned", "Today" or "September". With `isCollapsed`, clicking it
/// folds the section's notes away or shows them again, and a chevron says which.
struct NoteSectionHeader: View {
    let title: String
    var isCollapsed: Binding<Bool>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading
            Divider()
        }
        .padding(EdgeInsets(top: 20, leading: 10, bottom: 6, trailing: 10))
    }

    @ViewBuilder
    private var heading: some View {
        if let isCollapsed {
            Button {
                isCollapsed.wrappedValue.toggle()
            } label: {
                HStack(spacing: 6) {
                    text
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isCollapsed.wrappedValue ? 0 : 90))
                        .animation(.snappy, value: isCollapsed.wrappedValue)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.unpressed)
            .accessibilityValue(isCollapsed.wrappedValue ? "Collapsed" : "Expanded")
            .accessibilityHint(isCollapsed.wrappedValue ? "Shows the notes" : "Hides the notes")
        } else {
            text
        }
    }

    private var text: some View {
        Text(title)
            .font(.title2.weight(.bold))
            .accessibilityAddTraits(.isHeader)
    }
}
