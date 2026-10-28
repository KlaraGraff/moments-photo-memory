import Foundation
import AppKit
import Observation
import SwiftData
import SwiftUI

private struct StoredPhotosImportScope: Codable {
    enum Kind: String, Codable {
        case all
        case albums
        case dateRange
    }

    let kind: Kind
    let albumIdentifiers: [String]?
    let startDate: Date?
    let endDate: Date?

    init?(selection: PhotosImportSelection) {
        switch selection {
        case .all:
            kind = .all
            albumIdentifiers = nil
            startDate = nil
            endDate = nil
        case .albums(let identifiers):
            kind = .albums
            albumIdentifiers = identifiers
            startDate = nil
            endDate = nil
        case .dateRange(let start, let end):
            kind = .dateRange
            albumIdentifiers = nil
            startDate = start
            endDate = end
        case .identifiers:
            return nil
        }
    }

    var selection: PhotosImportSelection? {
        switch kind {
        case .all:
            return .all
        case .albums:
            return .albums(albumIdentifiers ?? [])
        case .dateRange:
            guard let startDate, let endDate else { return nil }
            return .dateRange(start: startDate, end: endDate)
        }
    }
}

@MainActor
@Observable
public final class PhotosImportController {
    public enum State: Equatable {
        case idle
        case previewing
        case importing
        case finished
        case cancelled
        case failed(String)
    }

    public private(set) var state: State = .idle
    public private(set) var authorizationStatus: PhotosAuthorizationStatus = .notDetermined
    public private(set) var albums: [PhotosAlbumDescriptor] = []
    public private(set) var pendingNewAssetIdentifiers: [String] = []
    public private(set) var pendingDeletedAssetCount = 0
    public private(set) var preview: PhotosImportPreview?
    public private(set) var progress = ImportProgress(phase: .scanning, completed: 0, total: 0, message: "")
    public private(set) var summary: ImportSummary?

    private let importer: PhotosImporter
    private let userDefaults: UserDefaults
    private var task: Task<Void, Never>?
    private var albumTask: Task<Void, Never>?
    private var changeTask: Task<Void, Never>?
    private var pendingScopeCheckIdentifiers = Set<String>()
    private var deletedDuringScopeCheck = Set<String>()
    private var container: ModelContainer?
    private var lastImportSelection: PhotosImportSelection?
    // Read in the nonisolated deinit to stop observing; only mutated on the main actor.
    nonisolated(unsafe) private var changeObservation: (any PhotosChangeObservation)?

    public init(importer: PhotosImporter, userDefaults: UserDefaults = .standard) {
        self.importer = importer
        self.userDefaults = userDefaults
    }

    public var isRunning: Bool { state == .previewing || state == .importing }

    public func configure(container: ModelContainer) {
        self.container = container
        if let data = userDefaults.data(forKey: Self.lastImportScopeDefaultsKey),
           let stored = try? JSONDecoder().decode(StoredPhotosImportScope.self, from: data) {
            lastImportSelection = stored.selection
        }
    }

    private func registerChangeObservationIfNeeded() {
        guard changeObservation == nil, let container else { return }
        changeObservation = importer.source.observeChanges { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let container = self.container
                let deletedIdentifiers = Set(event.deletedLocalIdentifiers)
                pendingNewAssetIdentifiers.removeAll { deletedIdentifiers.contains($0) }
                pendingScopeCheckIdentifiers.subtract(deletedIdentifiers)
                deletedDuringScopeCheck.formUnion(deletedIdentifiers)
                queueInsertedIdentifiers(event.insertedLocalIdentifiers)
                pendingDeletedAssetCount += event.deletedLocalIdentifiers.count
                if let container, !event.deletedLocalIdentifiers.isEmpty {
                    _ = try? self.importer.markMissing(localIdentifiers: event.deletedLocalIdentifiers, in: container)
                }
            }
        }
    }

    deinit {
        changeObservation?.invalidate()
    }

    public func requestAccess() async {
        let status = await importer.requestAccess()
        guard !Task.isCancelled else { return }
        authorizationStatus = status
        if status.canRead { registerChangeObservationIfNeeded() }
    }

    public func loadAlbums() {
        albumTask?.cancel()
        albumTask = Task { [weak self] in
            guard let self else { return }
            do { albums = try await importer.source.fetchAlbums() }
            catch { albums = [] }
        }
    }

    public func preview(selection: PhotosImportSelection) {
        task?.cancel()
        state = .previewing
        preview = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await importer.preview(selection: selection)
                guard !Task.isCancelled else { return }
                authorizationStatus = await importer.requestAccess()
                if authorizationStatus.canRead { registerChangeObservationIfNeeded() }
                preview = value
                state = .idle
            } catch is CancellationError {
                state = .cancelled
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    public func start(selection: PhotosImportSelection) {
        start(selection: selection, changeScope: selection)
    }

    private func start(
        selection: PhotosImportSelection,
        changeScope: PhotosImportSelection?,
        clearingPendingIdentifiers: Set<String>? = nil
    ) {
        guard let container else { return }
        task?.cancel()
        PlaceNameBackfillScheduler.shared.beginImport()
        lastImportSelection = changeScope
        persistLastImportSelection(changeScope)
        state = .importing
        summary = nil
        task = Task { [weak self] in
            defer { PlaceNameBackfillScheduler.shared.endImport() }
            guard let self else { return }
            do {
                authorizationStatus = await importer.requestAccess()
                guard authorizationStatus.canRead else { throw PhotosImportError.permissionDenied(authorizationStatus) }
                registerChangeObservationIfNeeded()
                let value = try await importer.importPhotos(selection: selection, container: container) { [weak self] progress in
                    Task { @MainActor [weak self] in self?.progress = progress }
                }
                guard !Task.isCancelled else { return }
                if let clearingPendingIdentifiers {
                    pendingNewAssetIdentifiers.removeAll { clearingPendingIdentifiers.contains($0) }
                }
                summary = value
                state = .finished
                if ImportSettings.autoOrganize {
                    EventSuggestions.suggest(in: container.mainContext)
                    NotificationCenter.default.post(name: .momentsPeopleScanRequested, object: nil)
                }
            } catch is CancellationError {
                progress = ImportProgress(phase: .cancelled, completed: progress.completed, total: progress.total, message: String(localized: "Apple Photos import cancelled"))
                state = .cancelled
            } catch {
                if case PhotosImportError.noAssets = error, let clearingPendingIdentifiers {
                    pendingNewAssetIdentifiers.removeAll { clearingPendingIdentifiers.contains($0) }
                    summary = ImportSummary(importedCount: 0, skippedCount: 0, tripCount: 0, placeCount: 0, collectionCount: 0, routeCount: 0, trips: [], flags: [], conflicts: [])
                    state = .finished
                } else {
                    state = .failed(error.localizedDescription)
                }
            }
        }
    }

    public func importPendingChanges() {
        let ids = pendingNewAssetIdentifiers
        guard !ids.isEmpty else { return }
        start(selection: .identifiers(ids), changeScope: lastImportSelection ?? .identifiers(ids), clearingPendingIdentifiers: Set(ids))
    }

    private func insertedIdentifiers(in identifiers: [String]) async -> [String] {
        guard !identifiers.isEmpty, let selection = lastImportSelection else { return [] }
        switch selection {
        case .all:
            return identifiers
        case .identifiers(let selected):
            let selectedIdentifiers = Set(selected)
            return identifiers.filter(selectedIdentifiers.contains)
        case .albums(_), .dateRange(_, _):
            return (try? await importer.source.filterLocalIdentifiers(identifiers, in: selection)) ?? []
        }
    }

    public func cancel() {
        task?.cancel()
    }

    /// Apple Photos was removed as a source: stop offering its new photos
    /// until someone imports from it again.
    public func forgetImportScope() {
        lastImportSelection = nil
        userDefaults.removeObject(forKey: Self.lastImportScopeDefaultsKey)
        changeTask?.cancel()
        pendingScopeCheckIdentifiers.removeAll()
        pendingNewAssetIdentifiers = []
        pendingDeletedAssetCount = 0
    }

    private static let lastImportScopeDefaultsKey = "Moments.photosImport.lastScope"

    private func persistLastImportSelection(_ selection: PhotosImportSelection?) {
        guard let selection,
              let stored = StoredPhotosImportScope(selection: selection),
              let data = try? JSONEncoder().encode(stored) else { return }
        userDefaults.set(data, forKey: Self.lastImportScopeDefaultsKey)
    }

    private func queueInsertedIdentifiers(_ identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        pendingScopeCheckIdentifiers.formUnion(identifiers)
        changeTask?.cancel()
        changeTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            let candidates = Array(self.pendingScopeCheckIdentifiers).sorted()
            self.pendingScopeCheckIdentifiers.removeAll()
            self.deletedDuringScopeCheck.removeAll()
            // The debounce task owns this batch once it has taken the identifiers.
            // A later change starts its own debounce task while this scope check
            // finishes, so cancellation cannot discard the taken identifiers.
            self.changeTask = nil
            // Assets deleted while the scope check ran must not come back as new.
            let scoped = await self.insertedIdentifiers(in: candidates)
                .filter { !self.deletedDuringScopeCheck.contains($0) }
            self.pendingNewAssetIdentifiers = Array(Set(self.pendingNewAssetIdentifiers + scoped)).sorted()
        }
    }
}

/// A compact permission and count surface that can be embedded in the library
/// import sheet. It intentionally keeps selection state in the controller.
public struct PhotosImportStatusView: View {
    @Bindable private var controller: PhotosImportController
    let selection: PhotosImportSelection
    let onImport: () -> Void

    public init(controller: PhotosImportController, selection: PhotosImportSelection, onImport: @escaping () -> Void) {
        self.controller = controller
        self.selection = selection
        self.onImport = onImport
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                switch controller.authorizationStatus {
                case .denied, .restricted:
                    Label("Apple Photos access is unavailable", systemImage: "lock.slash")
                        .foregroundStyle(Paper.muted)
                case .limited:
                    VStack(alignment: .leading, spacing: 4) {
                        if let preview = controller.preview {
                            Text(String(localized: "\(preview.count) photos or videos selected"))
                                .monospacedDigit()
                        }
                        Label("Apple Photos access is limited", systemImage: "photo.on.rectangle.angled")
                            .foregroundStyle(Paper.muted)
                    }
                default:
                    if let preview = controller.preview {
                        Text(String(localized: "\(preview.count) photos or videos selected"))
                            .monospacedDigit()
                    } else {
                        Label("Apple Photos", systemImage: "photo.on.rectangle")
                    }
                }
                Spacer(minLength: 8)
                switch controller.authorizationStatus {
                case .denied, .restricted:
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!)
                    }
                default:
                    if controller.preview != nil {
                        Button("Import") { onImport() }
                            .keyboardShortcut(.defaultAction)
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Count selection") { controller.preview(selection: selection) }
                    }
                }
            }
            if controller.state == .importing {
                HStack(spacing: 10) {
                    if let fraction = controller.progress.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Button("Cancel") { controller.cancel() }
                }
            }
        }
        .task {
            if controller.authorizationStatus == .notDetermined { await controller.requestAccess() }
        }
    }
}

public struct PhotosImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var controller: PhotosImportController
    @State private var mode = "all"
    @State private var selectedAlbums = Set<String>()
    @State private var startDate = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
    @State private var endDate = Date.now

    public init(controller: PhotosImportController) {
        self.controller = controller
    }

    private var selection: PhotosImportSelection {
        switch mode {
        case "albums": return .albums(Array(selectedAlbums).sorted())
        case "date": return .dateRange(start: startDate, end: endDate)
        default: return .all
        }
    }

    public var body: some View {
        PaperSheet(String(localized: "Import from Apple Photos")) {
            VStack(alignment: .leading, spacing: 16) {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 14) {
                    GridRow {
                        PaperFormLabel(String(localized: "Selection"))
                        Picker("Selection", selection: $mode) {
                            Text("All photos").tag("all")
                            Text("Albums").tag("albums")
                            Text("Date range").tag("date")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    if mode == "albums" {
                        GridRow(alignment: .top) {
                            PaperFormLabel(String(localized: "Albums"))
                            if controller.albums.isEmpty {
                                Text("No albums are available with the current Photos access.")
                                    .foregroundStyle(Paper.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                List(controller.albums, selection: $selectedAlbums) { album in
                                    Text(album.title).tag(album.localIdentifier)
                                }
                                .scrollContentBackground(.hidden)
                                .paperWell(padding: 2)
                                .frame(minHeight: 130)
                            }
                        }
                    } else if mode == "date" {
                        GridRow {
                            PaperFormLabel(String(localized: "From"))
                            DatePicker("From", selection: $startDate, displayedComponents: [.date])
                                .labelsHidden()
                                .fixedSize()
                        }
                        GridRow {
                            PaperFormLabel(String(localized: "To"))
                            DatePicker("To", selection: $endDate, displayedComponents: [.date])
                                .labelsHidden()
                                .fixedSize()
                        }
                    }
                }
                PhotosImportStatusView(controller: controller, selection: selection) {
                    controller.start(selection: selection)
                }
                .paperWell(padding: 12)
                if !controller.pendingNewAssetIdentifiers.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        Text(String(localized: "\(controller.pendingNewAssetIdentifiers.count) new photos in Apple Photos"))
                            .foregroundStyle(Paper.muted)
                        Spacer(minLength: 8)
                        Button("Import new photos") { controller.importPendingChanges() }
                    }
                }
            }
        } footer: {
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .frame(width: 520)
        .frame(minHeight: 340)
        .task {
            if controller.authorizationStatus == .notDetermined { await controller.requestAccess() }
            controller.loadAlbums()
        }
    }
}

extension Notification.Name {
    static let momentsShowPhotosImport = Notification.Name("Moments.ShowPhotosImport")
}
