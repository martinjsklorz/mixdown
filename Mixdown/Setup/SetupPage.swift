import SwiftUI

/// A page of the assistant: a symbol, a title and what the page is about, then its controls.
struct SetupPage<Content: View>: View {
    let title: String
    let systemImage: String
    let detail: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 40))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .frame(height: 48)
                Text(title)
                    .font(.title.weight(.semibold))
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 48)
            .padding(.top, 28)
            .padding(.bottom, 8)

            content
        }
    }
}

/// A row saying something is done, such as a permission being granted.
struct DoneLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Label(title, systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
    }
}
