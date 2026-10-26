import SwiftUI

/// Settings › General › Language: the app's language, following the system
/// unless the person picks one.
struct LanguageSettingsSection: View {
    @State private var language = AppLanguage.chosen()

    var body: some View {
        Section {
            Picker(String(localized: "Language"), selection: $language) {
                ForEach(AppLanguage.allCases) { option in
                    Text(verbatim: option.nativeName).tag(option)
                }
            }
            .accessibilityIdentifier("settings.language")

            if language != AppLanguage.atLaunch {
                HStack(alignment: .firstTextBaseline) {
                    Text(String(localized: "Moments shows the new language after it restarts."))
                        .font(.caption)
                        .foregroundStyle(Paper.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(String(localized: "Restart Now")) { AppLanguage.relaunch() }
                        .accessibilityIdentifier("settings.language.restart")
                }
            }
        } footer: {
            Text(String(localized: "“Same as System” follows the order in System Settings › General › Language & Region."))
        }
        .onChange(of: language) { _, newValue in
            AppLanguage.choose(newValue)
        }
    }
}
