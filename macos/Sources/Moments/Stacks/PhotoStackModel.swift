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
    /// The last change, offered as Undo in the viewer.
    private(set) var lastChange: Change?

    @ObservationIgnored private let analysis: PhotoStackAnalysisStore
    @ObservationIgnored private let detector: PhotoStackDetector
    @ObservationIgnored private var lastKey: Int?

    struct Change: Equatable {
        enum Kind: Equatable { case cover, unstack, remove }
        let id = UUID()
        let kind: Kind
        let stackID: String
        /// The decision before the change; `nil` when there was none.
        let previous: Data?
    }

    init(analysis: PhotoStackAnalysisStore = .shared, detector: PhotoStackDetector = PhotoStackDetector()) {
        self.analysis = analysis
        self.detector = detector
    }

    /// The analysis revision, for screens that regroup when it changes.
    var analysisRevision: Int { analysis.revision }

    func stack(containing itemID: String) -> PhotoStack? {
        index.stack(containing: itemID)
    }

    @discardableResult
    func update(items: [MediaItem], decisions: [UserGroup]) -> PhotoStackIndex {
        var hasher = Hasher()
        hasher.combine(analysis.revision)
        for item in items {
            hasher.combine(item.id)
            hasher.combine(item.effectiveCaptureDate)
            hasher.combine(item.perceptualHash)
            hasher.combine(item.kindRaw)
            hasher.combine(item.isScreenshot)
        }
        for decision in decisions where decision.kind == .stack {
            hasher.combine(decision.id)
            hasher.combine(decision.rulesData)
        }
        let key = hasher.finalize()
        guard key != lastKey else { return index }
        lastKey = key

        let entries = analysis.entries
        let photos = items.compactMap { item -> StackPhoto? in
            guard item.kind != .video, !item.isScreenshot else { return nil }
            let measured = entries[item.id]
            return StackPhoto(
                id: item.id,
                captureDate: item.effectiveCaptureDate,
                perceptualHash: StackPhoto.hash(fromHex: item.perceptualHash),
                featurePrint: measured?.featurePrint,
                quality: measured?.quality
            )
        }
        let next = detector.detect(photos, decisions: decisions.compactMap(Self.decision(of:)))
        if next != index { index = next }
        return next
    }

    /// Rebuilds from the store, for a change made while no screen that
    /// regroups is showing (the viewer over Timeline, say).
    func refresh(context: ModelContext) {
        let items = (try? context.fetch(FetchDescriptor<MediaItem>())) ?? []
        let stackKind = UserGroup.Kind.stack.rawValue
        let records = (try? context.fetch(FetchDescriptor<UserGroup>(predicate: #Predicate { $0.kindRaw == stackKind }))) ?? []
        update(items: items, decisions: records)
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
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.undo(change, context: context) }
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
        refresh(context: context)
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
        refresh(context: context)
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

    static func decision(of group: UserGroup) -> StackDecision? {
        guard group.kind == .stack else { return nil }
        return try? JSONDecoder().decode(StackDecision.self, from: group.rulesData)
    }
}
