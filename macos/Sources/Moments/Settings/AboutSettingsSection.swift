import AppKit
import MomentsCore
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The last section of Settings: which Moments this is, where its library
/// is, and a diagnostics file to send when something goes wrong.
struct AboutSettingsSection: View {
    var hasStore: Bool
    @Environment(BackupController.self) private var backups
    @State private var exportProblem = false

    var body: some View {
        Section {
            LabeledContent("Moments") {
                Text(String(format: String(localized: "Version %@ (%@)"), AppVersion.marketing, AppVersion.build))
                    .foregroundStyle(Paper.muted)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("settings.about-version")
            }
            LabeledContent(String(localized: "Library location")) {
                Button(String(localized: "Show in Finder")) {
                    if let url = backups.location?.storeURL {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                .disabled(backups.location == nil)
                .accessibilityIdentifier("settings.about-show-library")
            }
            LabeledContent(String(localized: "Diagnostics")) {
                HStack(spacing: 8) {
                    if exportProblem {
                        Text(String(localized: "Couldn't save the file."))
                            .font(.callout)
                            .foregroundStyle(Paper.accent)
                    }
                    if hasStore {
                        LibraryDiagnosticsExportButton(exportProblem: $exportProblem)
                    } else {
                        DiagnosticsExportButton(exportProblem: $exportProblem, context: nil)
                    }
                }
            }
        } header: {
            Text(String(localized: "About"))
        } footer: {
            Text(String(localized: "The diagnostics file holds the version, how many photos and memories there are, and recent error codes. No photos, memories, names, places or file paths."))
                .font(.caption)
                .foregroundStyle(Paper.muted)
        }
    }
}

/// The library's context, for its counts, exists only with a store.
private struct LibraryDiagnosticsExportButton: View {
    @Binding var exportProblem: Bool
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        DiagnosticsExportButton(exportProblem: $exportProblem, context: modelContext)
    }
}

private struct DiagnosticsExportButton: View {
    @Binding var exportProblem: Bool
    let context: ModelContext?

    var body: some View {
        Button(String(localized: "Export Diagnostics…")) {
            let report = DiagnosticsExport.report(context: context)
            exportProblem = !DiagnosticsExport.save(report)
        }
        .accessibilityIdentifier("settings.about-export-diagnostics")
    }
}

enum AppVersion {
    static var marketing: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    static var build: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
    }
}

/// Builds the diagnostics file and asks where to put it.
enum DiagnosticsExport {
    /// Only numbers from the library: how many of each kind of record.
    @MainActor
    static func report(context: ModelContext?, journal: DiagnosticsJournal = MomentsLog.journal, now: Date = .now) -> DiagnosticsReport {
        var counts: [(name: StaticString, value: Int)] = []
        if let context {
            counts = [
                ("photos", count(MediaItem.self, in: context)),
                ("memories", count(Memory.self, in: context)),
                ("comments", count(Comment.self, in: context)),
                ("chapters", count(Trip.self, in: context)),
                ("places", count(Place.self, in: context)),
                ("people", count(Person.self, in: context)),
            ]
        }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        return DiagnosticsReport(
            appVersion: AppVersion.marketing,
            buildNumber: AppVersion.build,
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: architecture,
            createdAt: now,
            counts: counts,
            events: journal.recent
        )
    }

    /// Asks for a place and writes the file there. False only when writing
    /// failed; cancelling the panel is not a problem.
    @MainActor
    static func save(_ report: DiagnosticsReport) -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = String(localized: "Moments Diagnostics") + ".txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return true }
        do {
            try Data(report.text.utf8).write(to: url, options: .atomic)
            MomentsLog.notice(.app, "diagnostics-exported", count: report.events.count)
            return true
        } catch {
            MomentsLog.error(.app, "diagnostics-export-failed", error: error)
            return false
        }
    }

    @MainActor
    private static func count<Model: PersistentModel>(_ type: Model.Type, in context: ModelContext) -> Int {
        (try? context.fetchCount(FetchDescriptor<Model>())) ?? 0
    }
}
