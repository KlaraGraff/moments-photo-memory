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

struct ImportReviewView: View {
    @Environment(ImportController.self) private var controller
    @Environment(\.modelContext) private var modelContext
    let summary: ImportSummary
    @State private var renameValues: [String: String] = [:]
    @State private var memoryValues: [String: String] = [:]
    @State private var correctedDates: [String: Date] = [:]
    @State private var placeValues: [String: String] = [:]

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

            if !summary.flags.isEmpty {
                Text("Needs your confirmation")
                    .font(.headline)
                    .accessibilityIdentifier("import.confirmationList")
                List(summary.flags) { flag in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(flag.fileName)
                                .font(.body.weight(.medium))
                            Spacer()
                            Button("Accept") { apply(flag, decision: .accepted) }
                                .buttonStyle(.borderless)
                                .accessibilityIdentifier("import.confirmation.accept.\(flag.id)")
                            Button("Ignore") { apply(flag, decision: .ignored) }
                                .buttonStyle(.borderless)
                                .accessibilityIdentifier("import.confirmation.ignore.\(flag.id)")
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
                            "Add a memory",
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
                .frame(minHeight: 120, maxHeight: 240)
            } else {
                Label("No items need confirmation", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
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
        item.importDecision = decision
        item.updatedAt = .now
        item.updatedBy = MomentsAccount.localID
        if decision == .accepted, let suggestedPlaceName = flag.suggestedPlaceName {
            if let existing = item.localPlaceOverride {
                existing.nameOverride = suggestedPlaceName
                existing.updatedAt = .now
                existing.updatedBy = MomentsAccount.localID
            } else {
                modelContext.insert(PlaceOverride(
                    mediaID: item.id,
                    nameOverride: suggestedPlaceName,
                    mediaItem: item
                ))
            }
            item.reviewOverridePlaceID = suggestedPlaceName
        }
        saveMemory(for: flag, item: item)
        try? modelContext.save()
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
        item.userCorrectedCaptureDateUTC = date
        item.reviewOverrideDateUTC = date
        item.captureDate = date
        item.timeConfidenceRaw = ImportTimeConfidence.userCorrected.rawValue
        item.importDecision = .changed
        item.updatedAt = .now
        item.updatedBy = MomentsAccount.localID
        try? modelContext.save()
    }

    private func changePlace(for flag: ImportReviewFlag) {
        guard let item = (try? modelContext.fetch(FetchDescriptor<MediaItem>()))?.first(where: { $0.id == flag.id }),
              let value = placeValues[flag.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return }
        if let existing = item.localPlaceOverride {
            existing.nameOverride = value
            existing.updatedAt = .now
            existing.updatedBy = MomentsAccount.localID
        } else {
            modelContext.insert(PlaceOverride(mediaID: item.id, nameOverride: value, mediaItem: item))
        }
        item.reviewOverridePlaceID = value
        item.importDecision = .changed
        item.updatedAt = .now
        item.updatedBy = MomentsAccount.localID
        try? modelContext.save()
    }
}
