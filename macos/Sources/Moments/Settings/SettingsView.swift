import SwiftUI

/// Settings is one page: sharing with your partner, and backups. Everything
/// else the app decides on its own (the language follows the Mac, photos are
/// organized after every import), so there is nothing else to set.
struct SettingsView: View {
    /// Without a store there is nothing to share or back up yet.
    var hasStore = true

    var body: some View {
        Form {
            SharingSettingsSections(hasStore: hasStore)
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

    static func select(_ tab: SettingsTab) {}
}
