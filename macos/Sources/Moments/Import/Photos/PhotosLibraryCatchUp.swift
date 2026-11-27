import Foundation
import MomentsCore
import SwiftData

/// The store side of keeping Apple Photos references current: reading the
/// library's Apple Photos items and writing what changed. Each call opens its
/// own context, so it runs off the main thread with 50,000 photos.
enum PhotosLibraryStore {
    /// This Mac's person's Apple Photos items, Recently Deleted included. A
    /// partner's photos point into their Mac's Photos library, not this one.
    static func entries(in container: ModelContainer, accountID: String = MomentsAccount.localID) -> [PhotosLibraryReconciliation.Entry] {
        let context = ModelContext(container)
        let photos = MediaSource.photos.rawValue
        var descriptor = FetchDescriptor<MediaItem>(predicate: #Predicate { $0.sourceRaw == photos })
        descriptor.propertiesToFetch = [\.id, \.photosLocalIdentifier, \.photosCloudIdentifier, \.photosAssetMissing, \.ownerAccountID]
        let items = (try? context.fetch(descriptor)) ?? []
        return items.compactMap { item in
            guard (item.ownerAccountID ?? MomentsAccount.localID) == accountID,
                  let local = item.photosLocalIdentifier else { return nil }
            return PhotosLibraryReconciliation.Entry(
                id: item.id,
                localIdentifier: local,
                cloudIdentifier: item.photosCloudIdentifier,
                isMarkedMissing: item.photosAssetMissing == true
            )
        }
    }

    /// Points relinked items at this Mac's photo and sets or clears the
    /// "no longer in Apple Photos" mark. Returns whether anything changed.
    @discardableResult
    static func apply(_ plan: PhotosLibraryReconciliation.Plan, in container: ModelContainer, now: Date = .now) throws -> Bool {
        guard !plan.isEmpty else { return false }
        let missing = Set(plan.newlyMissing)
        let found = Set(plan.foundAgain)
        let context = ModelContext(container)
        let photos = MediaSource.photos.rawValue
        let items = try context.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.sourceRaw == photos }))
        var changed = false
        for item in items {
            if let local = plan.relinked[item.id] {
                item.photosLocalIdentifier = local
                item.photosAssetMissing = false
            } else if missing.contains(item.id) {
                item.photosAssetMissing = true
            } else if found.contains(item.id) {
                item.photosAssetMissing = false
            } else {
                continue
            }
            item.updatedAt = now
            changed = true
        }
        if changed { try context.save() }
        return changed
    }

    /// Marks the items of deleted Apple Photos assets; returns how many.
    @discardableResult
    static func markMissing(localIdentifiers: [String], in container: ModelContainer, now: Date = .now) throws -> Int {
        guard !localIdentifiers.isEmpty else { return 0 }
        let ids = Set(localIdentifiers)
        let context = ModelContext(container)
        let photos = MediaSource.photos.rawValue
        var descriptor = FetchDescriptor<MediaItem>(predicate: #Predicate { $0.sourceRaw == photos })
        descriptor.propertiesToFetch = [\.id, \.photosLocalIdentifier, \.photosAssetMissing]
        var count = 0
        for item in try context.fetch(descriptor) where item.photosLocalIdentifier.map(ids.contains) == true {
            guard item.photosAssetMissing != true else { continue }
            item.photosAssetMissing = true
            item.updatedAt = now
            count += 1
        }
        if count > 0 { try context.save() }
        return count
    }

    /// Photos still in the library whose Apple Photos asset is gone.
    static func missingCount(in context: ModelContext) -> Int {
        let photos = MediaSource.photos.rawValue
        let missing: Bool? = true
        let descriptor = FetchDescriptor<MediaItem>(predicate: #Predicate {
            $0.sourceRaw == photos && $0.photosAssetMissing == missing && $0.deletedAt == nil
        })
        return (try? context.fetchCount(descriptor)) ?? 0
    }
}
