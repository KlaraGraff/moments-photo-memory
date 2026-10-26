import AppKit
import SwiftUI

/// Settings in three tabs, like other Mac apps: General, AI Model, Sharing.
struct SettingsView: View {
    @AppStorage(SettingsTab.storageKey) private var tab = SettingsTab.general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsView()
                .tabItem { Label(String(localized: "General"), systemImage: "gearshape") }
                .tag(SettingsTab.general)
            AISettingsView()
                .tabItem { Label(String(localized: "AI Model"), systemImage: "sparkles") }
                .tag(SettingsTab.aiModel)
            SharingSettingsView()
                .tabItem { Label(String(localized: "Sharing"), systemImage: "person.2") }
                .tag(SettingsTab.sharing)
        }
        .tint(Paper.accent)
    }
}

/// The open Settings tab; a link such as "AI model settings" picks its tab
/// before it opens the window.
enum SettingsTab: String {
    case general
    case aiModel
    case sharing

    static let storageKey = "moments.settings.tab"

    static func select(_ tab: SettingsTab) {
        UserDefaults.standard.set(tab.rawValue, forKey: storageKey)
    }
}

/// What happens after an import, where the library lives, and finding people.
struct GeneralSettingsView: View {
    @AppStorage(ImportSettings.autoOrganizeKey) private var autoOrganize = true
    @Environment(PeopleScanController.self) private var scanner

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "Organize automatically after import"), isOn: $autoOrganize)
                    .accessibilityIdentifier("settings.auto-organize")
            } footer: {
                Text(String(localized: "Finds the people in new photos and shows what was sorted into trips and places. Turned off, new photos still land in trips; look for people from People when you like."))
            }

            Section(String(localized: "Library")) {
                folderRow(String(localized: "Library location"), url: ImportSettings.libraryFolder, identifier: "settings.library-folder")
                folderRow(String(localized: "Backups"), url: ImportSettings.backupsFolder, identifier: "settings.backups-folder")
                Text(String(localized: "Your original photos stay where they are; the library keeps notes, people and places. Backups are made when the library can't be opened."))
                    .font(.caption)
                    .foregroundStyle(Paper.muted)
            }

            Section(String(localized: "People")) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(localized: "Scan for people"))
                        Text(String(localized: "Looks for faces in photos that haven't been checked yet. Names you gave stay as they are."))
                            .font(.caption)
                            .foregroundStyle(Paper.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    if scanner.isScanning {
                        ProgressView().controlSize(.small)
                    }
                    Button(String(localized: "Scan now")) { scanner.start() }
                        .disabled(!scanner.isAvailable || scanner.isScanning)
                        .accessibilityIdentifier("settings.scan-people")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Paper.canvas)
        .tint(Paper.accent)
        .frame(width: 560)
    }

    private func folderRow(_ title: String, url: URL?, identifier: String) -> some View {
        LabeledContent(title) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(url.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "—")
                    .font(.callout)
                    .foregroundStyle(Paper.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Button(String(localized: "Show in Finder")) {
                    guard let url else { return }
                    if FileManager.default.fileExists(atPath: url.path) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } else {
                        NSWorkspace.shared.open(url.deletingLastPathComponent())
                    }
                }
                .disabled(url == nil)
            }
        }
        .accessibilityIdentifier(identifier)
    }
}

/// Sharing with a partner is not built yet; this tab says what it will hold.
struct SharingSettingsView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.2")
                .font(.system(size: 30))
                .foregroundStyle(Paper.accent)
            Text(String(localized: "Sharing is coming"))
                .font(.system(.title3, design: .serif).weight(.medium))
                .foregroundStyle(Paper.ink)
            Text(String(localized: "Share your library with your partner, see who is connected and choose which changes notify you."))
                .font(.callout)
                .foregroundStyle(Paper.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(40)
        .frame(width: 560)
        .background(Paper.canvas)
        .accessibilityIdentifier("settings.sharing")
    }
}

enum ImportSettings {
    /// When on (the default), an import is followed by a face scan and the
    /// sheet that shows how the photos were organized.
    static let autoOrganizeKey = "moments.import.autoOrganize"

    static var autoOrganize: Bool {
        UserDefaults.standard.object(forKey: autoOrganizeKey) as? Bool ?? true
    }

    static var libraryFolder: URL? {
        try? MomentsPersistence.defaultStoreURL().deletingLastPathComponent()
    }

    static var backupsFolder: URL? {
        libraryFolder?.appending(path: "Backups", directoryHint: .isDirectory)
    }
}
