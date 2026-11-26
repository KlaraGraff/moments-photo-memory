import SwiftUI

/// Settings is one page: sharing with your partner, what the two of you
/// are called, AI organizing, and backups. Everything else the app decides
/// on its own (the language follows the Mac, photos are organized after
/// every import), so there is nothing else to set.
struct SettingsView: View {
    /// Without a store there is nothing to share or back up yet.
    var hasStore = true

    var body: some View {
        Form {
            SharingSettingsSections(hasStore: hasStore)
            AuthorNamesSection()
            AISettingsSections()
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
    /// Tall enough for the whole page with sharing unavailable and AI on
    /// with a custom model's fields, its longest form. A longer page scrolls.
    static let height: CGFloat = 750
}

/// What the two of you are called next to what you write.
struct AuthorNamesSection: View {
    @AppStorage(AuthorNames.myNameKey) private var myName = ""
    @AppStorage(AuthorNames.partnerNameKey) private var partnerName = ""

    var body: some View {
        Section {
            LabeledContent(String(localized: "Your name")) {
                TextField(String(localized: "Me"), text: $myName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .accessibilityIdentifier("settings.my-name")
            }
            LabeledContent(String(localized: "Your partner's name")) {
                TextField(String(localized: "Partner"), text: $partnerName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .accessibilityIdentifier("settings.partner-name")
            }
        } header: {
            Text(String(localized: "Names"))
        } footer: {
            Text(String(localized: "Shown next to what each of you writes. Kept on this Mac."))
                .font(.caption)
                .foregroundStyle(Paper.muted)
        }
    }
}
