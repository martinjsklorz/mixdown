import SwiftUI

/// A caption under a control or a section of a form, red for problems. Shared by Settings and the
/// setup assistant.
struct Caption: View {
    let text: String
    var isWarning = false

    init(_ text: String, isWarning: Bool = false) {
        self.text = text
        self.isWarning = isWarning
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(isWarning ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
    }
}
