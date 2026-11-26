import SwiftUI

/// Settings is one page: sharing with your partner, and backups. Everything
/// else the app decides on its own (the language follows the Mac, photos are
/// organized after every import), so there is nothing else to set.
struct SettingsView: View {
    /// Without a store there is nothing to share or back up yet.
    var hasStore = true

    var body: some View {
        Form {
            SharingSettingsSection()
            if hasStore { BackupSettingsSection() }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Paper.canvas)
        .tint(Paper.accent)
        .frame(width: SettingsLayout.width, height: SettingsLayout.height)
        .accessibilityIdentifier("settings.page")
    }
}

/// Settings is its own window, as on every Mac, at one fixed size.
enum SettingsLayout {
    static let width: CGFloat = 600
    static let height: CGFloat = 470
}

/// Kept for links written before Settings became one page; picking a tab
/// does nothing now.
enum SettingsTab: String {
    case general
    case imports
    case aiModel
    case sharing

    static func select(_ tab: SettingsTab) {}
}

/// Sharing with a partner is not built yet; this says what it will hold.
struct SharingSettingsSection: View {
    var body: some View {
        Section(String(localized: "Sharing")) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Sharing is coming"))
                    .foregroundStyle(Paper.ink)
                Text(String(localized: "Share your library with your partner, see who is connected and choose which changes notify you."))
                    .font(.caption)
                    .foregroundStyle(Paper.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings.sharing")
        }
    }
}
