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
    var reviewSummary: ImportSummary?
    private var task: Task<Void, Never>?
    private var modelContainer: ModelContainer?

    var isRunning: Bool { state == .importing }

    func configure(container: ModelContainer) {
        modelContainer = container
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
        lastFolderURL = folder
        reviewSummary = nil
        state = .importing
        progress = ImportProgress(phase: .scanning, completed: 0, total: 0, message: String(localized: "Scanning folder"))
        let importer = FolderImporter()
        task = Task { [weak self] in
            do {
                let summary = try await importer.importFolder(folder, container: modelContainer) { progress in
                    Task { @MainActor [weak self] in
                        self?.progress = progress
                    }
                }
                guard !Task.isCancelled else { return }
                self?.progress = ImportProgress(phase: .finished, completed: summary.importedCount, total: summary.importedCount, message: String(localized: "Import complete"))
                self?.reviewSummary = summary
                self?.state = .finished
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

    func dismissReview() {
        reviewSummary = nil
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
                    .foregroundStyle(.secondary)
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
}

private extension ImportController.State {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

private struct ImportReviewUndoSnapshot: Equatable {
    let placeOverride: ImportPlaceOverrideSnapshot?
    let reviewOverridePlaceID: String?
    let captureDate: Date?
    let userCorrectedCaptureDateUTC: Date?
    let reviewOverrideDateUTC: Date?
    let timeConfidenceRaw: String?
}

struct ImportReviewView: View {
    @Environment(ImportController.self) private var controller
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let summary: ImportSummary
    @State private var renameValues: [String: String] = [:]
    @State private var memoryValues: [String: String] = [:]
    @State private var correctedDates: [String: Date] = [:]
    @State private var placeValues: [String: String] = [:]
    @State private var reviewDecisionOverrides: [String: ImportReviewDecision] = [:]
    @State private var undoSnapshots: [String: ImportReviewUndoSnapshot] = [:]
    @State private var isHandledExpanded = false

    private var reviewPartition: ImportReviewPartition {
        partitionImportReviewFlags(summary.flags, decisionOverrides: reviewDecisionOverrides)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Review import")
                        .font(.title2.weight(.semibold))
                    Text("\(summary.importedCount) \(String(localized: "imported")) · \(summary.skippedCount) \(String(localized: "already present"))")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { controller.dismissReview() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("import.review.done")
            }

            if !reviewPartition.pending.isEmpty {
                HStack(spacing: 6) {
                    Text("Needs your confirmation")
                        .font(.headline)
                        .accessibilityIdentifier("import.confirmationList")
                    Text("(\(reviewPartition.pending.count))")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                List(reviewPartition.pending) { flag in
                    pendingRow(for: flag)
                }
                .frame(minHeight: 120, maxHeight: 240)
            } else {
                Text("Everything is confirmed")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }

            if !reviewPartition.handled.isEmpty {
                DisclosureGroup(isExpanded: $isHandledExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(reviewPartition.handled) { flag in
                            handledRow(for: flag)
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    HStack(spacing: 6) {
                        Text("Handled")
                            .font(.headline)
                        Text("(\(reviewPartition.handled.count))")
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("import.review.handled")
                .accessibilityLabel("\(String(localized: "Handled")), \(reviewPartition.handled.count)")
                .transaction { transaction in
                    if reduceMotion {
                        transaction.animation = nil
                    }
                }
            }

            Text("Trips found")
                .font(.headline)
            List(summary.trips) { trip in
                HStack {
                    TextField(
                        "Trip name",
                        text: Binding(
                            get: { renameValues[trip.id] ?? trip.name },
                            set: { renameValues[trip.id] = $0 }
                        )
                    )
                    .accessibilityIdentifier("import.trip.name.\(trip.id)")
                    Text("\(trip.itemCount) \(String(localized: "items"))")
                        .foregroundStyle(.secondary)
                    Button("Save") { saveRename(for: trip) }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("import.trip.rename.\(trip.id)")
                    Button("Split at first day") { split(at: trip) }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("import.trip.split.\(trip.id)")
                    Button("Confirm") { confirm(trip) }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("import.trip.confirm.\(trip.id)")
                }
            }
            .frame(minHeight: 100, maxHeight: 220)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("import.tripSuggestions")

            if summary.trips.count > 1 {
                Button("Merge later trips into the first") { mergeTrips() }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("import.trip.merge")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("import.review")
        .padding(24)
        .frame(width: 650, height: 560)
    }

    @ViewBuilder
    private func pendingRow(for flag: ImportReviewFlag) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(flag.fileName)
                    .font(.body.weight(.medium))
                Spacer()
                Button("Accept") { apply(flag, decision: .accepted) }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("import.confirmation.accept.\(flag.id)")
                    .accessibilityLabel(String(localized: "Accept"))
                Button("Ignore") { apply(flag, decision: .ignored) }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("import.confirmation.ignore.\(flag.id)")
                    .accessibilityLabel(String(localized: "Ignore"))
            }
            Text(flag.reasons.map(\.label).joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.orange)
            if let detail = flag.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let suggestedPlaceName = flag.suggestedPlaceName {
                Text(String(localized: "Suggested place:") + " " + suggestedPlaceName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(
                    "Place override",
                    text: Binding(
                        get: { placeValues[flag.id] ?? suggestedPlaceName },
                        set: { placeValues[flag.id] = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit { changePlace(for: flag) }
                .accessibilityIdentifier("import.confirmation.place.\(flag.id)")
            }
            TextField(
                "",
                text: Binding(
                    get: { memoryValues[flag.id] ?? "" },
                    set: { newValue in
                        memoryValues[flag.id] = newValue
                        if let item = (try? modelContext.fetch(FetchDescriptor<MediaItem>()))?.first(where: { $0.id == flag.id }) {
                            item.reviewMemoryDraft = newValue
                        }
                    }
                )
            )
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel(String(localized: "Memory"))
            .onSubmit { saveMemory(for: flag) }
            .accessibilityIdentifier("import.confirmation.memory.\(flag.id)")
            if flag.reasons.contains(.needsDate) {
                HStack {
                    DatePicker(
                        "Correct date",
                        selection: Binding(
                            get: { correctedDates[flag.id] ?? .now },
                            set: { correctedDates[flag.id] = $0 }
                        ),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .accessibilityIdentifier("import.confirmation.date.\(flag.id)")
                    Button("Use date") { correctDate(for: flag) }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("import.confirmation.useDate.\(flag.id)")
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func handledRow(for flag: ImportReviewFlag) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(flag.fileName)
                    .font(.body.weight(.medium))
                Text(decisionLabel(for: flag))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Undo") { undo(flag) }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("import.review.undo.\(flag.id)")
                .accessibilityLabel(String(localized: "Undo"))
        }
        .opacity(0.62)
    }

    private func decisionLabel(for flag: ImportReviewFlag) -> String {
        switch reviewDecisionOverrides[flag.id] ?? flag.decision {
        case .ignored:
            return String(localized: "Ignored")
        case .accepted:
            return String(localized: "Accepted")
        case .changed:
            return String(localized: "Changed")
        case .pending:
            return String(localized: "Needs your confirmation")
        }
    }

    private func updateReviewDecision(_ flag: ImportReviewFlag, to decision: ImportReviewDecision) {
        if reduceMotion {
            reviewDecisionOverrides[flag.id] = decision
        } else {
            withAnimation(.easeOut(duration: 0.18)) {
                reviewDecisionOverrides[flag.id] = decision
            }
        }
    }

    private func saveRename(for trip: ImportTripSummary) {
        guard let model = (try? modelContext.fetch(FetchDescriptor<Trip>()))?.first(where: { $0.id == trip.id }) else { return }
        let value = renameValues[trip.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
        model.overrideName = value?.isEmpty == false ? value : nil
        model.suggestionStatusRaw = "confirmed"
        model.confirmedAt = .now
        model.updatedAt = .now
        model.updatedBy = MomentsAccount.localID
        try? modelContext.save()
    }

    private func mergeTrips() {
        guard let first = summary.trips.first,
              let models = try? modelContext.fetch(FetchDescriptor<Trip>()),
              let target = models.first(where: { $0.id == first.id }) else { return }
        for trip in summary.trips.dropFirst() {
            models.first(where: { $0.id == trip.id })?.mergeOverrideID = target.id
        }
        target.updatedAt = .now
        target.updatedBy = MomentsAccount.localID
        target.suggestionStatusRaw = "confirmed"
        target.confirmedAt = .now
        try? modelContext.save()
    }

    private func split(at trip: ImportTripSummary) {
        guard let model = (try? modelContext.fetch(FetchDescriptor<Trip>()))?.first(where: { $0.id == trip.id }),
              let firstDay = model.orderedItems.compactMap(\.localDayKey).first else { return }
        model.splitOverrideDayKeys = firstDay
        model.suggestionStatusRaw = "confirmed"
        model.confirmedAt = .now
        model.updatedAt = .now
        model.updatedBy = MomentsAccount.localID
        try? modelContext.save()
    }

    private func confirm(_ trip: ImportTripSummary) {
        guard let model = (try? modelContext.fetch(FetchDescriptor<Trip>()))?.first(where: { $0.id == trip.id }) else { return }
        model.suggestionStatusRaw = "confirmed"
        model.confirmedAt = .now
        model.updatedAt = .now
        model.updatedBy = MomentsAccount.localID
        try? modelContext.save()
    }

    private func apply(_ flag: ImportReviewFlag, decision: ImportReviewDecision) {
        guard let item = (try? modelContext.fetch(FetchDescriptor<MediaItem>()))?.first(where: { $0.id == flag.id }) else { return }
        rememberUndo(for: item)
        item.importDecision = decision
        item.updatedAt = .now
        item.updatedBy = MomentsAccount.localID
        if decision == .accepted {
            let action = ImportReviewDecisionLogic.placeAction(
                suggestedPlaceName: flag.suggestedPlaceName,
                typedPlaceName: placeValues[flag.id],
                existingOverrideName: item.localPlaceOverride?.nameOverride,
                existingReviewOverridePlaceID: item.reviewOverridePlaceID
            )
            if case .set(let name) = action {
                setPlaceOverride(name, for: item)
            }
        }
        saveMemory(for: flag, item: item)
        try? modelContext.save()
        updateReviewDecision(flag, to: decision)
    }

    private func undo(_ flag: ImportReviewFlag) {
        guard let item = (try? modelContext.fetch(FetchDescriptor<MediaItem>()))?.first(where: { $0.id == flag.id }) else { return }
        if let snapshot = undoSnapshots[flag.id] {
            restore(snapshot, on: item)
        }
        item.importDecision = .pending
        item.updatedAt = .now
        item.updatedBy = MomentsAccount.localID
        try? modelContext.save()
        undoSnapshots.removeValue(forKey: flag.id)
        updateReviewDecision(flag, to: .pending)
    }

    private func saveMemory(for flag: ImportReviewFlag) {
        guard let item = (try? modelContext.fetch(FetchDescriptor<MediaItem>()))?.first(where: { $0.id == flag.id }) else { return }
        saveMemory(for: flag, item: item)
        try? modelContext.save()
    }

    private func saveMemory(for flag: ImportReviewFlag, item: MediaItem) {
        let text = memoryValues[flag.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return }
        modelContext.insert(Memory(text: text, mediaItem: item))
        item.reviewMemoryDraft = nil
        memoryValues[flag.id] = ""
    }

    private func correctDate(for flag: ImportReviewFlag) {
        guard let date = correctedDates[flag.id],
              let item = (try? modelContext.fetch(FetchDescriptor<MediaItem>()))?.first(where: { $0.id == flag.id }) else { return }
        rememberUndo(for: item)
        item.userCorrectedCaptureDateUTC = date
        item.reviewOverrideDateUTC = date
        item.captureDate = date
        item.timeConfidenceRaw = ImportTimeConfidence.userCorrected.rawValue
        item.importDecision = .changed
        item.updatedAt = .now
        item.updatedBy = MomentsAccount.localID
        try? modelContext.save()
        updateReviewDecision(flag, to: .changed)
    }

    private func changePlace(for flag: ImportReviewFlag) {
        guard let item = (try? modelContext.fetch(FetchDescriptor<MediaItem>()))?.first(where: { $0.id == flag.id }),
              let value = placeValues[flag.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return }
        rememberUndo(for: item)
        setPlaceOverride(value, for: item)
        item.importDecision = .changed
        item.updatedAt = .now
        item.updatedBy = MomentsAccount.localID
        try? modelContext.save()
        updateReviewDecision(flag, to: .changed)
    }

    private func rememberUndo(for item: MediaItem) {
        guard undoSnapshots[item.id] == nil else { return }
        let override = item.localPlaceOverride.map {
            ImportPlaceOverrideSnapshot(
                id: $0.id,
                placeID: $0.placeID,
                mediaID: $0.mediaID,
                accountID: $0.accountID,
                nameOverride: $0.nameOverride,
                mapLinkOverride: $0.mapLinkOverride,
                latitude: $0.latitude,
                longitude: $0.longitude,
                updatedAt: $0.updatedAt,
                updatedBy: $0.updatedBy
            )
        }
        undoSnapshots[item.id] = ImportReviewUndoSnapshot(
            placeOverride: override,
            reviewOverridePlaceID: item.reviewOverridePlaceID,
            captureDate: item.captureDate,
            userCorrectedCaptureDateUTC: item.userCorrectedCaptureDateUTC,
            reviewOverrideDateUTC: item.reviewOverrideDateUTC,
            timeConfidenceRaw: item.timeConfidenceRaw
        )
    }

    private func setPlaceOverride(_ value: String, for item: MediaItem) {
        if let existing = item.localPlaceOverride {
            existing.nameOverride = value
            existing.updatedAt = .now
            existing.updatedBy = MomentsAccount.localID
        } else {
            modelContext.insert(PlaceOverride(mediaID: item.id, nameOverride: value, mediaItem: item))
        }
        item.reviewOverridePlaceID = value
    }

    private func restore(_ snapshot: ImportReviewUndoSnapshot, on item: MediaItem) {
        item.reviewOverridePlaceID = snapshot.reviewOverridePlaceID
        item.captureDate = snapshot.captureDate
        item.userCorrectedCaptureDateUTC = snapshot.userCorrectedCaptureDateUTC
        item.reviewOverrideDateUTC = snapshot.reviewOverrideDateUTC
        item.timeConfidenceRaw = snapshot.timeConfidenceRaw

        let current = item.localPlaceOverride
        switch (snapshot.placeOverride, current) {
        case (nil, let current?):
            modelContext.delete(current)
        case (let saved?, nil):
            modelContext.insert(PlaceOverride(
                id: saved.id,
                placeID: saved.placeID,
                mediaID: saved.mediaID ?? item.id,
                accountID: saved.accountID,
                nameOverride: saved.nameOverride,
                mapLinkOverride: saved.mapLinkOverride,
                latitude: saved.latitude,
                longitude: saved.longitude,
                updatedAt: saved.updatedAt,
                updatedBy: saved.updatedBy,
                mediaItem: item
            ))
        case (let saved?, let current?):
            if current.id == saved.id {
                current.placeID = saved.placeID
                current.mediaID = saved.mediaID
                current.accountID = saved.accountID
                current.nameOverride = saved.nameOverride
                current.mapLinkOverride = saved.mapLinkOverride
                current.latitude = saved.latitude
                current.longitude = saved.longitude
                current.updatedAt = saved.updatedAt
                current.updatedBy = saved.updatedBy
            } else {
                modelContext.delete(current)
                modelContext.insert(PlaceOverride(
                    id: saved.id,
                    placeID: saved.placeID,
                    mediaID: saved.mediaID ?? item.id,
                    accountID: saved.accountID,
                    nameOverride: saved.nameOverride,
                    mapLinkOverride: saved.mapLinkOverride,
                    latitude: saved.latitude,
                    longitude: saved.longitude,
                    updatedAt: saved.updatedAt,
                    updatedBy: saved.updatedBy,
                    mediaItem: item
                ))
            }
        case (nil, nil):
            break
        }
    }
}
