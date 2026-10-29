import SwiftUI

/// The language to transcribe in, or Automatic. Disabled for models that detect it themselves.
/// Shared by Settings and the setup assistant.
struct LanguagePicker: View {
    @Environment(AppEnvironment.self) private var environment

    /// ISO 639-1 codes offered besides "Automatic". The models support many more.
    private static let languages = ["en", "de", "fr", "es", "it", "pt", "nl", "pl", "ja", "zh"]

    var body: some View {
        Picker(
            "Language",
            selection: Bindable(environment.preferences).language
        ) {
            Text("Automatic").tag(String?.none)
            Divider()
            ForEach(Self.languages, id: \.self) { code in
                Text(Self.displayName(for: code)).tag(Optional(code))
            }
        }
        .disabled(!environment.model.supportsLanguageSelection)
    }

    /// "German" for `de`, in the user's language.
    static func displayName(for code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }
}
