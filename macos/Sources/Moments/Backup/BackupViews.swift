import AppKit
import MomentsCore
import SwiftUI

/// Settings' "Backup" section, ready to drop into any `Form`: the automatic
/// backup's state and "Restore from Backup…".
struct BackupSettingsSection: View {
    var body: some View {
        Section {
            BackupSettingsRow()
        } header: {
            Text(String(localized: "Backup"))
        } footer: {
            Text(String(localized: "Moments backs up the library every day and keeps the last 14 days. Original photos are not in the backup."))
                .font(.caption)
                .foregroundStyle(Paper.muted)
        }
    }
}

/// "Automatic backup: last today 09:12" and the one button there is.
/// Backups need no setting: they always run.
struct BackupSettingsRow: View {
    @Environment(BackupController.self) private var backups
    @State private var showingRestore = false

    var body: some View {
        LabeledContent(String(localized: "Automatic backup")) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                status
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("settings.backup-status")
                Button(String(localized: "Restore from Backup…")) { showingRestore = true }
                    .disabled(backups.location == nil)
                    .accessibilityIdentifier("settings.backup-restore")
            }
        }
        .onAppear { backups.refresh() }
        .sheet(isPresented: $showingRestore) {
            RestoreBackupSheet()
                .environment(backups)
        }
    }

    @ViewBuilder
    private var status: some View {
        if backups.isRunning {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(String(localized: "Backing up…")).foregroundStyle(Paper.muted)
            }
        } else if let failure = backups.failure {
            Text(String(format: String(localized: "Couldn't back up: %@"), failure))
                .foregroundStyle(Paper.accent)
                .help(lastText)
        } else {
            Text(lastText).foregroundStyle(Paper.muted)
        }
    }

    private var lastText: String {
        guard let newest = backups.newest else { return String(localized: "No backup yet") }
        return String(format: String(localized: "Last: %@"), BackupDateText.string(newest.manifest.createdAt))
    }
}

/// Dates as "Today 09:12", "Yesterday 08:47" or "24 Nov 2026 21:03".
enum BackupDateText {
    static func string(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: date)
    }
}

/// The list of backups, newest first, each with Restore; plus restoring
/// from a backup copied from another Mac.
struct RestoreBackupSheet: View {
    @Environment(BackupController.self) private var backups
    @Environment(\.dismiss) private var dismiss
    @State private var confirming: Candidate?
    @State private var problem: String?

    /// A backup about to be restored, from the list or from another folder.
    struct Candidate: Identifiable {
        var folder: URL
        var manifest: BackupManifest
        var id: String { folder.path }
    }

    var body: some View {
        PaperSheet(String(localized: "Restore from Backup")) {
            VStack(alignment: .leading, spacing: 12) {
                if backups.entries.isEmpty {
                    Text(String(localized: "No backups on this Mac yet. To move to a new Mac, choose a backup copied from the old one."))
                        .font(.callout)
                        .foregroundStyle(Paper.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(backups.entries, id: \.folderName) { entry in
                                row(entry)
                                if entry.folderName != backups.entries.last?.folderName { Divider() }
                            }
                        }
                    }
                    .paperWell(padding: 0)
                    .frame(maxHeight: 260)
                }
                Text(String(localized: "Backups hold memories, trips, places, people and your choices, not the original photos. Before a restore, the current library is saved too."))
                    .font(.caption)
                    .foregroundStyle(Paper.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            Button(String(localized: "Restore from Another Location…")) { chooseFolder() }
                .accessibilityIdentifier("backup.restore-other")
            Button(String(localized: "Show in Finder")) { showInFinder() }
                .disabled(backups.location == nil)
            Button(String(localized: "Done")) { dismiss() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("backup.done")
        }
        .frame(width: 520)
        .accessibilityIdentifier("backup.restore-sheet")
        .alert(
            confirming.map { String(format: String(localized: "Restore the backup from %@?"), BackupDateText.string($0.manifest.createdAt)) } ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            presenting: confirming
        ) { candidate in
            Button(String(localized: "Restore and Reopen")) { restore(candidate) }
                .accessibilityIdentifier("backup.confirm-restore")
            Button(String(localized: "Cancel"), role: .cancel) { confirming = nil }
        } message: { _ in
            Text(String(localized: "Memories and changes made after it go back to how they were then. The current library is saved first, so you can restore it again. Moments will reopen."))
        }
        .alert(
            String(localized: "The backup can't be restored"),
            isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })
        ) {
            Button(String(localized: "OK"), role: .cancel) { problem = nil }
        } message: {
            Text(problem ?? "")
        }
    }

    private func row(_ entry: BackupEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(BackupDateText.string(entry.manifest.createdAt))
            if let label = kindLabel(entry.manifest.kind) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(Paper.muted)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Paper.well, in: RoundedRectangle(cornerRadius: 4))
            }
            Spacer(minLength: 8)
            Text(counts(entry.manifest))
                .font(.callout)
                .foregroundStyle(Paper.muted)
                .lineLimit(1)
            Button(String(localized: "Restore…")) {
                guard let location = backups.location else { return }
                let folder = location.backupsFolder.appending(path: entry.folderName, directoryHint: .isDirectory)
                confirming = Candidate(folder: folder, manifest: entry.manifest)
            }
            .accessibilityIdentifier("backup.restore-row")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("backup.row")
    }

    private func kindLabel(_ kind: BackupKind) -> String? {
        switch kind {
        case .daily: return nil
        case .beforeUpgrade: return String(localized: "Before update")
        case .beforeRestore: return String(localized: "Before restore")
        }
    }

    private func counts(_ manifest: BackupManifest) -> String {
        var parts: [String] = []
        if let photos = manifest.photoCount { parts.append(String(localized: "\(photos) photos")) }
        if let memories = manifest.memoryCount { parts.append(String(localized: "\(memories) memories")) }
        return parts.joined(separator: " · ")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = String(localized: "Choose a Moments backup folder")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let manifest = try LibraryBackup.validate(url)
            confirming = Candidate(folder: url, manifest: manifest)
        } catch {
            problem = error.localizedDescription
        }
    }

    private func restore(_ candidate: Candidate) {
        confirming = nil
        do {
            try backups.restore(candidate.folder)
        } catch {
            problem = error.localizedDescription
        }
    }

    private func showInFinder() {
        guard let location = backups.location else { return }
        let folder = location.backupsFolder
        if FileManager.default.fileExists(atPath: folder.path) {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } else {
            NSWorkspace.shared.open(location.folder)
        }
    }
}

/// Shown once at the first launch after a restore: what was restored, or
/// why the library was left as it was.
struct BackupRestoreAlert: ViewModifier {
    @AppStorage(BackupRestoreNotice.defaultsKey) private var stored = Data()

    private var notice: BackupRestoreNotice? {
        stored.isEmpty ? nil : try? JSONDecoder().decode(BackupRestoreNotice.self, from: stored)
    }

    func body(content: Content) -> some View {
        content.alert(
            title,
            isPresented: Binding(get: { notice != nil }, set: { if !$0 { stored = Data() } })
        ) {
            Button(String(localized: "OK"), role: .cancel) { stored = Data() }
        } message: {
            Text(message)
        }
    }

    private var title: String {
        guard let notice else { return "" }
        if notice.failure != nil { return String(localized: "The backup couldn't be restored") }
        guard let date = notice.restoredBackupDate else { return String(localized: "Backup restored") }
        return String(format: String(localized: "Restored the backup from %@"), BackupDateText.string(date))
    }

    private var message: String {
        guard let notice else { return "" }
        if let failure = notice.failure {
            return String(format: String(localized: "Your library was left as it was. %@"), failure)
        }
        return String(localized: "The library from before the restore was saved too; it is marked “Before restore” under Restore from Backup. Your original photos were not changed.")
    }
}
