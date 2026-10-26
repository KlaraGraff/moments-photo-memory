import SwiftData
import SwiftUI

/// The folders and Apple Photos that photos were imported from, each with a
/// Remove button that takes its photos out of Moments (to Recently Deleted).
struct ImportSourcesSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PhotosImportController.self) private var photosImport
    @Query private var sources: [ImportSource]
    /// Changes when photos come and go, so the counts follow.
    @Query(filter: #Predicate<MediaItem> { $0.deletedAt == nil }) private var liveItems: [MediaItem]
    @State private var summaries: [ImportSources.Summary] = []
    @State private var pendingRemoval: ImportSources.Summary?
    @State private var lastRemoved: (name: String, count: Int)?

    private var refreshKey: Int {
        var hasher = Hasher()
        for source in sources { hasher.combine(source.id) }
        for item in liveItems {
            hasher.combine(item.id)
            hasher.combine(item.importSourceIDsRaw)
        }
        return hasher.finalize()
    }

    var body: some View {
        Form {
            Section {
                if summaries.isEmpty {
                    Text(String(localized: "Nothing imported yet."))
                        .foregroundStyle(Paper.muted)
                } else {
                    ForEach(summaries) { summary in
                        row(summary)
                    }
                }
            } header: {
                Text(String(localized: "Imported from"))
            } footer: {
                Text(String(localized: "Removing a source moves its photos to Recently Deleted, where they wait 30 days. The folder, its files and Apple Photos are not touched."))
            }
            if let lastRemoved {
                Text(String(localized: "“\(lastRemoved.name)”: \(lastRemoved.count) moved to Recently Deleted"))
                    .font(.callout)
                    .foregroundStyle(Paper.muted)
                    .accessibilityIdentifier("settings.imports.removed")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Paper.canvas)
        .tint(Paper.accent)
        .frame(width: SettingsLayout.width, height: SettingsLayout.height)
        .task(id: refreshKey) {
            // Photos imported before sources were recorded get theirs once.
            ImportSources.backfill(context: modelContext)
            summaries = ImportSources.summaries(context: modelContext)
        }
        .alert(
            pendingRemoval.map { String(localized: "Remove “\($0.name)” from Moments?") } ?? "",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { summary in
            Button(String(localized: "Remove"), role: .destructive) {
                remove(summary)
            }
            .accessibilityIdentifier("settings.imports.remove.confirm")
            Button(String(localized: "Cancel"), role: .cancel) { pendingRemoval = nil }
        } message: { summary in
            Text(Self.removalMessage(summary))
        }
    }

    private func row(_ summary: ImportSources.Summary) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: summary.kind == .photos ? "photo.on.rectangle" : "folder")
                .foregroundStyle(Paper.accent)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.kind == .photos ? String(localized: "Apple Photos") : summary.name)
                    .lineLimit(1)
                if let location = summary.location {
                    Text(location)
                        .font(.caption)
                        .foregroundStyle(Paper.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            Text(String(localized: "\(summary.itemCount) photos"))
                .font(.callout.monospacedDigit())
                .foregroundStyle(Paper.muted)
            Button(String(localized: "Remove…")) { pendingRemoval = summary }
                .accessibilityIdentifier("settings.imports.remove.\(summary.kind == .photos ? "photos" : summary.name)")
        }
        .accessibilityElement(children: .contain)
    }

    private func remove(_ summary: ImportSources.Summary) {
        pendingRemoval = nil
        let id = summary.id
        guard let source = (try? modelContext.fetch(FetchDescriptor<ImportSource>(predicate: #Predicate { $0.id == id })))?.first else { return }
        let moved = ImportSources.remove(source, context: modelContext)
        if summary.kind == .photos { photosImport.forgetImportScope() }
        lastRemoved = (summary.kind == .photos ? String(localized: "Apple Photos") : summary.name, moved)
        summaries = ImportSources.summaries(context: modelContext)
    }

    static func removalMessage(_ summary: ImportSources.Summary) -> String {
        let moving = String(localized: "\(summary.itemCount) photos move to Recently Deleted for 30 days; you can recover them there.")
        switch summary.kind {
        case .photos:
            return moving + " " + String(localized: "Apple Photos is not touched, and its new photos are no longer offered for import.")
        case .folder:
            return moving + " " + String(localized: "Photos also in another imported folder stay. The folder and its files are not touched.")
        }
    }
}
