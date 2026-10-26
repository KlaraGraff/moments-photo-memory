import SwiftUI

/// Settings › General: the app's language.
struct GeneralSettingsView: View {
    @State private var language = AppLanguage.chosen()

    var body: some View {
        Form {
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
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Paper.canvas)
        .tint(Paper.accent)
        .frame(width: 560)
        .onChange(of: language) { _, newValue in
            AppLanguage.choose(newValue)
        }
    }
}

/// The Settings window: General and AI Model tabs. Opens on the last tab used.
struct MomentsSettingsView: View {
    enum Tab: String {
        case general
        case ai
    }

    static let tabKey = "MomentsSettingsTab"

    @AppStorage(MomentsSettingsView.tabKey) private var tab = Tab.general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsView()
                .tabItem { Label(String(localized: "General"), systemImage: "gearshape") }
                .tag(Tab.general)
            AISettingsView()
                .tabItem { Label(String(localized: "AI Model"), systemImage: "sparkles") }
                .tag(Tab.ai)
        }
        .preferredColorScheme(.light)
    }
}
