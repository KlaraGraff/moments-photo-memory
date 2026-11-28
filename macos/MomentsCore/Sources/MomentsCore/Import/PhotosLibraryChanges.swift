import Foundation

/// One step of Apple Photos' change history: the assets added, edited and
/// removed between two change tokens, as local identifiers.
public struct PhotosChangeBatch: Equatable, Sendable {
    public let inserted: [String]
    public let updated: [String]
    public let deleted: [String]

    public init(inserted: [String] = [], updated: [String] = [], deleted: [String] = []) {
        self.inserted = inserted
        self.updated = updated
        self.deleted = deleted
    }
}

/// What Apple Photos' history says happened while Moments was closed, and
/// what is still waiting to be imported. Pure bookkeeping on identifiers, so
/// it is checked on Linux; reading the history itself needs PhotoKit.
public enum PhotosLibraryChanges {
    /// The net effect of several batches in order: an asset added and then
    /// removed again is neither new nor removed.
    public static func net(_ batches: [PhotosChangeBatch]) -> (inserted: [String], deleted: [String]) {
        var inserted = Set<String>()
        var deleted = Set<String>()
        for batch in batches {
            for id in batch.inserted {
                inserted.insert(id)
                deleted.remove(id)
            }
            for id in batch.deleted where inserted.remove(id) == nil {
                deleted.insert(id)
            }
        }
        return (inserted.sorted(), deleted.sorted())
    }

    /// The new assets still to offer for import: the ones already waiting and
    /// the ones just added, without those removed since or already imported.
    public static func pending(
        waiting: [String],
        inserted: [String],
        deleted: [String],
        alreadyImported: Set<String>
    ) -> [String] {
        let removed = Set(deleted)
        let all = Set(waiting).union(inserted)
        return all.filter { !removed.contains($0) && !alreadyImported.contains($0) }.sorted()
    }
}

/// Matches the Apple Photos references kept in the library against the
/// Photos library on this Mac. On another Mac (a library restored from a
/// backup) every local identifier is different, but Photos' cloud identifier
/// is the same, so a photo can be found again through it.
public enum PhotosLibraryReconciliation {
    /// One Apple Photos item in the library.
    public struct Entry: Equatable, Sendable {
        public let id: String
        public let localIdentifier: String
        public let cloudIdentifier: String?
        public let isMarkedMissing: Bool

        public init(id: String, localIdentifier: String, cloudIdentifier: String?, isMarkedMissing: Bool) {
            self.id = id
            self.localIdentifier = localIdentifier
            self.cloudIdentifier = cloudIdentifier
            self.isMarkedMissing = isMarkedMissing
        }
    }

    public struct Plan: Equatable, Sendable {
        /// Item id → the local identifier of the same photo on this Mac.
        public var relinked: [String: String] = [:]
        /// Items whose photo is no longer in Apple Photos here.
        public var newlyMissing: [String] = []
        /// Items marked missing before whose photo is here again.
        public var foundAgain: [String] = []

        public init(relinked: [String: String] = [:], newlyMissing: [String] = [], foundAgain: [String] = []) {
            self.relinked = relinked
            self.newlyMissing = newlyMissing
            self.foundAgain = foundAgain
        }

        public var isEmpty: Bool { relinked.isEmpty && newlyMissing.isEmpty && foundAgain.isEmpty }
    }

    /// The cloud identifiers worth asking Photos about: those of items whose
    /// local identifier is not in this Mac's library.
    public static func cloudIdentifiersToLookUp(_ entries: [Entry], present: Set<String>) -> [String] {
        Array(Set(entries.compactMap { entry -> String? in
            guard !present.contains(entry.localIdentifier) else { return nil }
            return entry.cloudIdentifier.flatMap { $0.isEmpty ? nil : $0 }
        })).sorted()
    }

    /// What to change. `present` holds the local identifiers that exist in
    /// this Mac's library; `localForCloud` maps cloud identifiers to this
    /// Mac's local identifiers. A local identifier another item already uses
    /// is never given to a second item, so two entries cannot end up as one
    /// photo.
    public static func plan(
        _ entries: [Entry],
        present: Set<String>,
        localForCloud: [String: String]
    ) -> Plan {
        var plan = Plan()
        var taken = Set(entries.compactMap { present.contains($0.localIdentifier) ? $0.localIdentifier : nil })
        for entry in entries.sorted(by: { $0.id < $1.id }) {
            if present.contains(entry.localIdentifier) {
                if entry.isMarkedMissing { plan.foundAgain.append(entry.id) }
                continue
            }
            if let cloud = entry.cloudIdentifier,
               let local = localForCloud[cloud],
               !local.isEmpty,
               local != entry.localIdentifier,
               taken.insert(local).inserted {
                plan.relinked[entry.id] = local
            } else if !entry.isMarkedMissing {
                plan.newlyMissing.append(entry.id)
            }
        }
        return plan
    }

    /// Whether a few items are enough to tell that the library came from
    /// another Mac: most of a sample's local identifiers are unknown here.
    /// A handful of photos deleted in Photos does not trigger a full check.
    public static func looksLikeAnotherMac(sampleCount: Int, unknownInSample: Int) -> Bool {
        guard sampleCount > 0 else { return false }
        return unknownInSample * 2 > sampleCount
    }
}
