import AppKit
import Foundation
import Observation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class ImportController {
    enum State: Equatable {
        case idle
        case importing
        case cancelled
        case finished
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var progress = ImportProgress(phase: .scanning, completed: 0, total: 0, message: "")
    private(set) var lastFolderURL: URL?
    /// Folder imports that ran to the end since launch.
    private(set) var finishedImportCount = 0
    private var task: Task<Void, Never>?
    private var modelContainer: ModelContainer?

    var isRunning: Bool { state == .importing }

    func configure(container: ModelContainer) {
        modelContainer = container
        regroupOldTrips(in: container)
        PlaceNameBackfillScheduler.shared.start(container: container)
    }

    /// Once, before any import or backfill can start (see `TripRegrouping`).
    /// UI tests keep their seeded trips; unit tests call it directly.
    private func regroupOldTrips(in container: ModelContainer) {
        guard !ProcessInfo.processInfo.arguments.contains("-MomentsUITesting") else { return }
        #if DEBUG
        if UnitTestHostDelegate.isUnitTestHost { return }
        #endif
        // Daily life left its trips, so its big days can become events.
        if (try? TripRegrouping.runOnce(context: container.mainContext)) != nil {
            EventSuggestions.suggest(in: container.mainContext)
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Import Folder…")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        start(folder: folder)
    }

    func start(folder: URL) {
        guard let modelContainer else { return }
        task?.cancel()
        PlaceNameBackfillScheduler.shared.beginImport()
        lastFolderURL = folder
        state = .importing
        progress = ImportProgress(phase: .scanning, completed: 0, total: 0, message: String(localized: "Scanning folder"))
        let importer = FolderImporter()
        task = Task { [weak self] in
            defer { PlaceNameBackfillScheduler.shared.endImport() }
            do {
                let summary = try await importer.importFolder(folder, container: modelContainer) { progress in
                    Task { @MainActor [weak self] in
                        self?.progress = progress
                    }
                }
                guard !Task.isCancelled else { return }
                self?.progress = ImportProgress(phase: .finished, completed: summary.importedCount, total: summary.importedCount, message: String(localized: "Import complete"))
                // No results sheet to work through: the photos are in the
                // Library, sorted into trips, and people are found on their own.
                self?.state = .finished
                self?.finishedImportCount += 1
                if let context = self?.modelContainer?.mainContext { EventSuggestions.suggest(in: context) }
                NotificationCenter.default.post(name: .momentsPeopleScanRequested, object: nil)
            } catch is CancellationError {
                self?.progress = ImportProgress(phase: .cancelled, completed: self?.progress.completed ?? 0, total: self?.progress.total ?? 0, message: String(localized: "Import cancelled"))
                self?.state = .cancelled
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    func resume() {
        guard let lastFolderURL else { return }
        start(folder: lastFolderURL)
    }

}

struct ImportStatusView: View {
    @Environment(ImportController.self) private var controller
    @Environment(PhotosImportController.self) private var photos

    private var showsFolderImport: Bool {
        controller.isRunning || controller.state == .cancelled || controller.state.isFailure
    }

    var body: some View {
        if showsFolderImport || PhotosImportStatusRows.hasContent(photos) {
            VStack(alignment: .leading, spacing: 4) {
                if showsFolderImport { folderImportRow }
                PhotosImportStatusRows()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var folderImportRow: some View {
        HStack(spacing: 10) {
            if let fraction = controller.progress.fraction {
                ProgressView(value: fraction)
                    .frame(width: 120)
                    .accessibilityIdentifier("import.progress.indicator")
            } else {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityIdentifier("import.progress.indicator")
            }
            Text(controller.progress.message)
                .lineLimit(1)
            Text("\(controller.progress.completed)/\(controller.progress.total)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Paper.muted)
            if controller.isRunning {
                Button("Cancel") { controller.cancel() }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("import.cancel")
            } else if controller.state == .cancelled {
                Button("Resume") { controller.resume() }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("import.resume")
            } else if case .failed(let message) = controller.state {
                Text(message)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
        .font(.caption)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("import.progress")
    }
}

#if DEBUG
/// UI tests only: how many folder imports have finished since launch, so a
/// test knows when the one it started is done.
struct ImportFinishedProbe: View {
    @Environment(ImportController.self) private var controller

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: "finished=\(controller.finishedImportCount)"))
            .accessibilityIdentifier("import.finished")
    }
}
#endif

private extension ImportController.State {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
