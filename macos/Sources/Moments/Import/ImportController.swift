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

    /// One folder import, or a few run one after another.
    enum Job: Equatable {
        case folder(URL)
        /// Photos dropped on the window, all from one folder.
        case files(in: URL, [URL])
        /// An imported folder that moved, at its new place.
        case relocate(sourceID: String, URL)
    }

    private(set) var state: State = .idle
    private(set) var progress = ImportProgress(phase: .scanning, completed: 0, total: 0, message: "")
    private(set) var lastFolderURL: URL?
    /// Folder imports that ran to the end since launch.
    private(set) var finishedImportCount = 0
    /// Imported folders Moments can't find any more, without those whose
    /// note was closed.
    private(set) var missingFolders: [FolderLocations.Missing] = []
    private var lastJobs: [Job] = []
    private var task: Task<Void, Never>?
    private var modelContainer: ModelContainer?
    private let userDefaults: UserDefaults
    private let makeImporter: () -> FolderImporter

    init(userDefaults: UserDefaults = .standard, makeImporter: @escaping () -> FolderImporter = { FolderImporter() }) {
        self.userDefaults = userDefaults
        self.makeImporter = makeImporter
    }

    var isRunning: Bool { state == .importing }
    var canRetry: Bool { !lastJobs.isEmpty && !isRunning }

    /// `startsBackgroundWork` false is for tests: no trip regrouping, place
    /// lookups or folder check of their own.
    func configure(container: ModelContainer, startsBackgroundWork: Bool = true) {
        modelContainer = container
        guard startsBackgroundWork else { return }
        regroupOldTrips(in: container)
        PlaceNameBackfillScheduler.shared.start(container: container)
        if Self.checksFolderLocationsAtLaunch {
            Task { await checkFolderLocations() }
        }
    }

    /// UI tests and unit tests bring their own folders.
    private static var checksFolderLocationsAtLaunch: Bool {
        if ProcessInfo.processInfo.arguments.contains("-MomentsUITesting") { return false }
        #if DEBUG
        if UnitTestHostDelegate.isUnitTestHost { return false }
        #endif
        return true
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
        start([.folder(folder)])
    }

    /// Files and folders dropped on the window: each folder is imported,
    /// and loose photos and videos with the folder they are in.
    func importDropped(_ urls: [URL]) {
        let items = urls.map { url in
            DroppedImport.Item(url: url, isDirectory: (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true)
        }
        let jobs: [Job] = DroppedImport.jobs(items).map { job in
            switch job {
            case .folder(let url): return .folder(url)
            case .files(let folder, let files): return .files(in: folder, files)
            }
        }
        guard !jobs.isEmpty else {
            guard !isRunning else { return }
            // Nothing to run again.
            lastJobs = []
            progress = ImportProgress(phase: .scanning, completed: 0, total: 0, message: "")
            state = .failed(FolderImportError.noSupportedFiles.localizedDescription)
            return
        }
        start(jobs)
    }

    func start(_ jobs: [Job]) {
        guard let modelContainer, !jobs.isEmpty else { return }
        task?.cancel()
        PlaceNameBackfillScheduler.shared.beginImport()
        lastJobs = jobs
        lastFolderURL = jobs.last.map(Self.folder(of:))
        state = .importing
        progress = ImportProgress(phase: .scanning, completed: 0, total: 0, message: String(localized: "Scanning folder"))
        let importer = makeImporter()
        task = Task { [weak self] in
            defer { PlaceNameBackfillScheduler.shared.endImport() }
            do {
                var imported = 0
                let report: @Sendable (ImportProgress) -> Void = { progress in
                    Task { @MainActor [weak self] in
                        self?.progress = progress
                    }
                }
                for job in jobs {
                    try Task.checkCancellation()
                    let summary: ImportSummary
                    switch job {
                    case .folder(let folder):
                        summary = try await importer.importFolder(folder, container: modelContainer, progress: report)
                    case .files(let folder, let files):
                        summary = try await importer.importFiles(files, in: folder, container: modelContainer, progress: report)
                    case .relocate(let sourceID, let folder):
                        summary = try await importer.importFolder(folder, relocatingSourceID: sourceID, container: modelContainer, progress: report)
                    }
                    imported += summary.importedCount
                }
                guard !Task.isCancelled else { return }
                self?.progress = ImportProgress(phase: .finished, completed: imported, total: imported, message: String(localized: "Import complete"))
                // No results sheet to work through: the photos are in the
                // Library, sorted into trips, and people are found on their own.
                self?.state = .finished
                self?.finishedImportCount += 1
                if let context = self?.modelContainer?.mainContext { EventSuggestions.suggest(in: context) }
                NotificationCenter.default.post(name: .momentsPeopleScanRequested, object: nil)
                // A relocated folder is found again.
                if jobs.contains(where: { if case .relocate = $0 { return true }; return false }) {
                    await self?.checkFolderLocations()
                }
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

    /// Runs the last import again: after a cancel, the files already read
    /// are not read again; after a failure, it is the Try again.
    func resume() {
        guard !lastJobs.isEmpty, !isRunning else { return }
        start(lastJobs)
    }

    /// Looks for imported folders that can't be found any more, off the
    /// main thread. Folders moved on the same disk are followed quietly.
    func checkFolderLocations() async {
        guard let modelContainer else { return }
        let container = modelContainer
        let missing = await Task.detached(priority: .utility) {
            FolderLocations.check(in: container)
        }.value
        let dismissed = Set(userDefaults.stringArray(forKey: Self.dismissedMissingFoldersKey) ?? [])
        // A folder that is back, or gone for good, needn't stay closed.
        let stillMissing = Set(missing.map(\.id))
        let keptDismissed = dismissed.intersection(stillMissing)
        if keptDismissed != dismissed { userDefaults.set(keptDismissed.sorted(), forKey: Self.dismissedMissingFoldersKey) }
        missingFolders = FolderLocationCheck.toShow(missing: missing.map { (id: $0.id, name: $0.name) }, dismissed: keptDismissed)
            .map { FolderLocations.Missing(id: $0.id, name: $0.name) }
    }

    /// Asks where a missing folder is now and imports it from there: its
    /// photos open from the new place, and new files in it are added.
    func locate(_ folder: FolderLocations.Missing) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Where is the folder “\(folder.name)” now?")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        relocate(folder, to: url)
    }

    func relocate(_ folder: FolderLocations.Missing, to url: URL) {
        missingFolders.removeAll { $0.id == folder.id }
        start([.relocate(sourceID: folder.id, url)])
    }

    func dismissMissingFolder(_ folder: FolderLocations.Missing) {
        missingFolders.removeAll { $0.id == folder.id }
        var dismissed = Set(userDefaults.stringArray(forKey: Self.dismissedMissingFoldersKey) ?? [])
        dismissed.insert(folder.id)
        userDefaults.set(dismissed.sorted(), forKey: Self.dismissedMissingFoldersKey)
    }

    private static let dismissedMissingFoldersKey = "Moments.folderImport.dismissedMissingFolders"

    private static func folder(of job: Job) -> URL {
        switch job {
        case .folder(let url), .files(let url, _), .relocate(_, let url): return url
        }
    }
}

struct ImportStatusView: View {
    @Environment(ImportController.self) private var controller

    var body: some View {
        if controller.isRunning || controller.state == .cancelled || controller.state.isFailure {
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
                        .help(message)
                    if controller.canRetry {
                        Button("Try again") { controller.resume() }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("import.retry")
                    }
                }
            }
            .font(.caption)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("import.progress")
        }
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
