import Foundation
import MomentsCore
import Observation
import SwiftData

/// Bursts of near-identical photos, shown as one stack everywhere. Screens
/// call `update(items:decisions:)` with what they already queried; the
/// stacks are rebuilt only when photos, decisions or analysis changed.
///
/// What someone changes about a stack (cover, unstack, a photo taken out) is
/// stored as a `UserGroup` of kind `.stack` holding a `StackDecision`, so it
/// is kept, synced like other groups, and either partner can change it.
@MainActor
@Observable
final class PhotoStackModel {
    private(set) var index: PhotoStackIndex = .empty
    /// Moves whenever `index` changes; screens regroup on it.
    private(set) var generation = 0
    /// The last change, offered as Undo in the viewer.
    private(set) var lastChange: Change?

    @ObservationIgnored private let analysis: PhotoStackAnalysisStore
    @ObservationIgnored private let detector: PhotoStackDetector
    /// What the last detection ran on; the analysis is added when it runs.
    @ObservationIgnored private var photos: [StackPhoto] = []
    @ObservationIgnored private var decisions: [StackDecision] = []
    @ObservationIgnored private var photosKey: Int?
    @ObservationIgnored private var decisionsKey: Int?
    @ObservationIgnored private var detectedRevision: Int?
    @ObservationIgnored private var detection: Task<Void, Never>?
    @ObservationIgnored private var refreshToken = 0
    /// Move whenever newer photos or decisions arrive, so a slower
    /// background refresh never puts older ones back.
    @ObservationIgnored private var photosVersion = 0
    @ObservationIgnored private var decisionsVersion = 0

    struct Change: Equatable {
        enum Kind: Equatable { case cover, unstack, remove }
        let id = UUID()
        let kind: Kind
        let stackID: String
        /// The decision before the change; `nil` when there was none.
        let previous: Data?
        /// What the window's Undo is registered against, so the viewer's own
        /// Undo can take back exactly this change from it.
        let undoTarget = UndoTarget()

        static func == (lhs: Change, rhs: Change) -> Bool { lhs.id == rhs.id }
    }

    final class UndoTarget {}

    init(analysis: PhotoStackAnalysisStore = .shared, detector: PhotoStackDetector = PhotoStackDetector()) {
        self.analysis = analysis
        self.detector = detector
    }

    /// The analysis revision, for the app to fold new results in.
    var analysisRevision: Int { analysis.revision }

    func stack(containing itemID: String) -> PhotoStack? {
        index.stack(containing: itemID)
    }

    /// Screens pass what they already queried. Nothing runs when photos,
    /// decisions and analysis are unchanged. The first detection runs at once,
    /// so the first grid is already folded; later ones run in the background
    /// and screens regroup when `generation` moves.
    @discardableResult
    func update(items: [MediaItem], decisions records: [UserGroup], waits: Bool = false) -> PhotoStackIndex {
        let photosKey = Self.key(of: items)
        let decisionsKey = Self.key(of: records)
        guard photosKey != self.photosKey || decisionsKey != self.decisionsKey || analysis.revision != detectedRevision else {
            return index
        }
        let isFirst = detectedRevision == nil
        if photosKey != self.photosKey {
            photos = Self.photos(of: items)
            self.photosKey = photosKey
            photosVersion += 1
        }
        if decisionsKey != self.decisionsKey {
            decisions = records.compactMap(Self.decision(of:))
            self.decisionsKey = decisionsKey
            decisionsVersion += 1
        }
        detect(waits: waits || isFirst)
        return index
    }

    /// New analysis results: detects again with the photos already known.
    func analysisChanged() {
        guard detectedRevision != nil, analysis.revision != detectedRevision else { return }
        detect(waits: false)
    }

    /// Reads everything again in the background, for changes made while no
    /// screen that passes its photos is showing (an import over the Map, say).
    func refresh(container: ModelContainer) {
        refreshToken += 1
        let token = refreshToken
        let photosVersion = self.photosVersion
        let decisionsVersion = self.decisionsVersion
        Task { [weak self] in
            let snapshot = await Task.detached(priority: .utility) { () -> Snapshot in
                let context = ModelContext(container)
                let items = (try? context.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.deletedAt == nil }))) ?? []
                let stackKind = UserGroup.Kind.stack.rawValue
                let records = (try? context.fetch(FetchDescriptor<UserGroup>(predicate: #Predicate { $0.kindRaw == stackKind }))) ?? []
                return Snapshot(
                    photos: Self.photos(of: items),
                    photosKey: Self.key(of: items),
                    decisions: records.compactMap(Self.decision(of:)),
                    decisionsKey: Self.key(of: records)
                )
            }.value
            guard let self, token == self.refreshToken else { return }
            var changed = self.analysis.revision != self.detectedRevision
            // Only parts nobody replaced while the store was read.
            if photosVersion == self.photosVersion, snapshot.photosKey != self.photosKey {
                self.photos = snapshot.photos
                self.photosKey = snapshot.photosKey
                self.photosVersion += 1
                changed = true
            }
            if decisionsVersion == self.decisionsVersion, snapshot.decisionsKey != self.decisionsKey {
                self.decisions = snapshot.decisions
                self.decisionsKey = snapshot.decisionsKey
                self.decisionsVersion += 1
                changed = true
            }
            if changed { self.detect(waits: false) }
        }
    }

    private struct Snapshot: Sendable {
        let photos: [StackPhoto]
        let photosKey: Int
        let decisions: [StackDecision]
        let decisionsKey: Int
    }

    private func detect(waits: Bool) {
        let photos = self.photos
        let decisions = self.decisions
        let detector = self.detector
        let analysis = self.analysis
        detectedRevision = analysis.revision
        detection?.cancel()
        detection = nil
        // While the saved analysis is still being read, wait for it, so
        // stacks don't fold once by hash and again by feature print.
        if waits, analysis.isLoaded {
            apply(Self.detect(photos, analysis: analysis.entries, decisions: decisions, detector: detector))
            return
        }
        detection = Task { [weak self] in
            await analysis.loaded()
            guard !Task.isCancelled else { return }
            self?.detectedRevision = analysis.revision
            let entries = analysis.entries
            let next = await Task.detached(priority: .userInitiated) {
                Self.detect(photos, analysis: entries, decisions: decisions, detector: detector)
            }.value
            guard !Task.isCancelled else { return }
            self?.apply(next)
        }
    }

    private func apply(_ next: PhotoStackIndex) {
        guard next != index else { return }
        index = next
        generation += 1
    }

    nonisolated private static func detect(
        _ photos: [StackPhoto],
        analysis: [String: PhotoStackAnalysis],
        decisions: [StackDecision],
        detector: PhotoStackDetector
    ) -> PhotoStackIndex {
        let measured = photos.map { photo -> StackPhoto in
            guard let entry = analysis[photo.id] else { return photo }
            return StackPhoto(
                id: photo.id,
                captureDate: photo.captureDate,
                perceptualHash: photo.perceptualHash,
                featurePrint: entry.featurePrint,
                quality: entry.quality
            )
        }
        return detector.detect(measured, decisions: decisions)
    }

    /// Photos that can stack: no videos, no screenshots.
    nonisolated private static func photos(of items: [MediaItem]) -> [StackPhoto] {
        items.compactMap { item -> StackPhoto? in
            guard item.kind != .video, !item.isScreenshot else { return nil }
            return StackPhoto(
                id: item.id,
                captureDate: item.effectiveCaptureDate,
                perceptualHash: StackPhoto.hash(fromHex: item.perceptualHash)
            )
        }
    }

    /// Screens pass the same photos in different orders, so per-photo
    /// hashes are added up and the order does not matter.
    nonisolated private static func key(of items: [MediaItem]) -> Int {
        var key = items.count
        for item in items {
            var hasher = Hasher()
            hasher.combine(item.id)
            hasher.combine(item.effectiveCaptureDate)
            hasher.combine(item.perceptualHash)
            hasher.combine(item.kindRaw)
            hasher.combine(item.isScreenshot)
            key &+= hasher.finalize()
        }
        return key
    }

    nonisolated private static func key(of records: [UserGroup]) -> Int {
        var key = 0
        for record in records where record.kind == .stack {
            var hasher = Hasher()
            hasher.combine(record.id)
            hasher.combine(record.rulesData)
            key &+= hasher.finalize()
        }
        return key
    }

    /// Folds the stacks in an ordered list of photo ids.
    func collapse(_ orderedIDs: [String]) -> [StackedEntry] {
        index.collapse(orderedIDs)
    }

    /// How many photos `ids` are with each burst counted once.
    func foldedCount(_ ids: [String]) -> Int {
        index.isEmpty ? ids.count : index.collapse(ids).count
    }

    // MARK: - Changes

    func setCover(_ itemID: String, of stack: PhotoStack, context: ModelContext, undoManager: UndoManager? = nil) {
        guard stack.memberIDs.contains(itemID) else { return }
        change(.cover, stack: stack, context: context, undoManager: undoManager) { decision in
            decision.coverID = itemID
        }
    }

    /// Shows the stack's photos one by one; Undo stacks them again.
    func unstack(_ stack: PhotoStack, context: ModelContext, undoManager: UndoManager? = nil) {
        change(.unstack, stack: stack, context: context, undoManager: undoManager) { decision in
            decision.isUnstacked = true
        }
    }

    /// Takes one photo out; it shows on its own and is not stacked again.
    func remove(_ itemID: String, from stack: PhotoStack, context: ModelContext, undoManager: UndoManager? = nil) {
        guard stack.memberIDs.contains(itemID) else { return }
        change(.remove, stack: stack, context: context, undoManager: undoManager) { decision in
            decision.memberIDs.removeAll { $0 == itemID }
            if !decision.removedIDs.contains(itemID) { decision.removedIDs.append(itemID) }
            if decision.coverID == itemID { decision.coverID = nil }
        }
    }

    /// Puts the stack back as it was before `change`.
    func undo(_ change: Change, context: ModelContext) {
        restore(stackID: change.stackID, to: change.previous, context: context)
        if lastChange == change { lastChange = nil }
    }

    func dismissLastChange() {
        lastChange = nil
    }

    private func change(
        _ kind: Change.Kind,
        stack: PhotoStack,
        context: ModelContext,
        undoManager: UndoManager?,
        _ edit: (inout StackDecision) -> Void
    ) {
        let record = Self.record(for: stack.id, context: context)
        let previous = record?.rulesData
        var decision = record.flatMap(Self.decision(of:))
            ?? StackDecision(id: stack.id, memberIDs: stack.memberIDs, coverID: stack.isCoverChosen ? stack.coverID : nil)
        edit(&decision)
        write(decision, to: record, context: context)
        let change = Change(kind: kind, stackID: stack.id, previous: previous)
        lastChange = change
        // The handler keeps `change`, and so its target, alive.
        undoManager?.registerUndo(withTarget: change.undoTarget) { [weak self] _ in
            MainActor.assumeIsolated { self?.undo(change, context: context) }
        }
        undoManager?.setActionName(Self.actionName(kind))
    }

    private func restore(stackID: String, to previous: Data?, context: ModelContext) {
        let record = Self.record(for: stackID, context: context)
        if let previous {
            if let record {
                record.rulesData = previous
                record.updatedAt = .now
            } else if let decision = try? JSONDecoder().decode(StackDecision.self, from: previous) {
                write(decision, to: nil, context: context)
                return
            }
        } else if let record {
            context.delete(record)
        }
        try? context.save()
        decisionsChanged(context: context)
    }

    private func write(_ decision: StackDecision, to record: UserGroup?, context: ModelContext) {
        let data = (try? JSONEncoder().encode(decision)) ?? Data()
        if let record {
            record.rulesData = data
            record.updatedAt = .now
        } else {
            let group = UserGroup(id: decision.id, name: "", kind: .stack)
            group.rulesData = data
            context.insert(group)
        }
        try? context.save()
        decisionsChanged(context: context)
    }

    /// After a change: only the decisions are read again, and the stacks
    /// update at once, on the photos already known.
    private func decisionsChanged(context: ModelContext) {
        let stackKind = UserGroup.Kind.stack.rawValue
        let records = (try? context.fetch(FetchDescriptor<UserGroup>(predicate: #Predicate { $0.kindRaw == stackKind }))) ?? []
        decisions = records.compactMap(Self.decision(of:))
        decisionsKey = Self.key(of: records)
        decisionsVersion += 1
        detect(waits: true)
    }

    private static func actionName(_ kind: Change.Kind) -> String {
        switch kind {
        case .cover: return String(localized: "Set Cover")
        case .unstack: return String(localized: "Unstack")
        case .remove: return String(localized: "Remove from Stack")
        }
    }

    static func record(for stackID: String, context: ModelContext) -> UserGroup? {
        let stackKind = UserGroup.Kind.stack.rawValue
        var descriptor = FetchDescriptor<UserGroup>(predicate: #Predicate { $0.id == stackID && $0.kindRaw == stackKind })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    nonisolated static func decision(of group: UserGroup) -> StackDecision? {
        guard group.kind == .stack else { return nil }
        return try? JSONDecoder().decode(StackDecision.self, from: group.rulesData)
    }
}
