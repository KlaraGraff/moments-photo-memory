import AppKit
import Foundation

/// The language Moments shows, picked in Settings › General.
///
/// macOS reads a per-app `AppleLanguages` list from the app's own defaults
/// domain at launch (the same setting as System Settings › Language & Region
/// › Applications), so a change takes effect after a restart.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case chineseSimplified = "zh-Hans"
    case german = "de"

    static let defaultsKey = "AppleLanguages"

    var id: String { rawValue }

    /// Each language in its own words, so it can be found whatever the app
    /// currently shows.
    var nativeName: String {
        switch self {
        case .system: String(localized: "Same as System")
        case .english: "English"
        case .chineseSimplified: "简体中文"
        case .german: "Deutsch"
        }
    }

    /// The person's choice for Moments. Read from the app's own domain, so the
    /// system-wide language list doesn't count as a choice.
    static func chosen(in defaults: UserDefaults = .standard, domain: String? = Bundle.main.bundleIdentifier) -> AppLanguage {
        guard let domain,
              let languages = defaults.persistentDomain(forName: domain)?[defaultsKey] as? [String],
              let first = languages.first else {
            return .system
        }
        return AppLanguage(rawValue: first) ?? .system
    }

    static func choose(_ language: AppLanguage, in defaults: UserDefaults = .standard) {
        if language == .system {
            defaults.removeObject(forKey: defaultsKey)
        } else {
            defaults.set([language.rawValue], forKey: defaultsKey)
        }
    }

    /// The choice the running app started with; the screen asks for a restart
    /// only when the choice differs from it.
    @MainActor static let atLaunch = chosen()

    /// Starts a fresh Moments once this one has quit, then quits.
    @MainActor static func relaunch() {
        let script = Process()
        script.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for this process to exit so two copies never hold the store.
        script.arguments = [
            "-c",
            "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
            "relaunch",
            String(ProcessInfo.processInfo.processIdentifier),
            Bundle.main.bundleURL.path
        ]
        do {
            try script.run()
            NSApp.terminate(nil)
        } catch {
            // Can't relaunch; the new language still applies on the next start.
        }
    }
}
