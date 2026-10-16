import AppKit

/// Whether Mixdown follows the system's light or dark mode, or always uses one of them.
enum Appearance: String, CaseIterable, Identifiable {
    case auto
    case light
    case dark

    var id: Self { self }

    var title: String {
        switch self {
        case .auto: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// `nil` follows the system.
    private var nsAppearance: NSAppearance? {
        switch self {
        case .auto: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// Applies to every window, sheet and menu of the app, including the open ones.
    @MainActor func apply() {
        NSApp.appearance = nsAppearance
    }
}
