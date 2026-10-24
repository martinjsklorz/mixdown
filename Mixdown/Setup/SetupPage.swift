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

/// One of a few ways to set something up, as a row with a symbol, a title and what it means,
/// checked while it's the one chosen. Rows next to each other work like radio buttons.
struct SetupChoice: View {
    let title: String
    let systemImage: String
    let detail: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
