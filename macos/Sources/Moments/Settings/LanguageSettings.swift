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

// Until the Settings window gains its own General tab (#74), the language
// gets a minimal one here.
struct MomentsSettingsView: View {
    enum Tab: String {
        case general
        case ai
    }

    static let tabKey = "MomentsSettingsTab"

    @AppStorage(MomentsSettingsView.tabKey) private var tab = Tab.general

    var body: some View {
        TabView(selection: $tab) {
            Form { LanguageSettingsSection() }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .background(Paper.canvas)
                .tint(Paper.accent)
                .frame(width: 560)
                .tabItem { Label(String(localized: "General"), systemImage: "gearshape") }
                .tag(Tab.general)
            AISettingsView()
                .tabItem { Label(String(localized: "AI Model"), systemImage: "sparkles") }
                .tag(Tab.ai)
        }
        .preferredColorScheme(.light)
    }
}
