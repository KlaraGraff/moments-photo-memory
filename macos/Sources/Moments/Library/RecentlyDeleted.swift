import Foundation
import SwiftData

/// Taking photos out of Moments, the way Photos does it: they go to Recently
/// Deleted first, wait there for 30 days and are then purged. Only the
/// Moments record goes (its notes, faces and group places with it); the
/// original file on disk and the Apple Photos asset are never touched.
///
/// Each person deletes only the photos they added (`ownerAccountID`); a
/// partner's photos are left as they are.
@MainActor
enum RecentlyDeleted {
    static let retentionDays = 30
    static let retention: TimeInterval = TimeInterval(retentionDays) * 86_400

    /// Whether `accountID` added this photo and so may delete it.
    static func canDelete(_ item: MediaItem, accountID: String = MomentsAccount.localID) -> Bool {
        (item.ownerAccountID ?? MomentsAccount.localID) == accountID
    }

    /// Moves the photos `accountID` may delete to Recently Deleted and
    /// returns their ids. Others' photos and ones already there are skipped.
    @discardableResult
    static func moveToTrash(_ items: [MediaItem], accountID: String = MomentsAccount.localID, now: Date = .now, context: ModelContext) -> [String] {
        let moving = items.filter { $0.deletedAt == nil && canDelete($0, accountID: accountID) }
        for item in moving {
            item.deletedAt = now
            item.deletedBy = accountID
            item.updatedAt = now
            item.updatedBy = accountID
        }
        if !moving.isEmpty { try? context.save() }
        return moving.map(\.id)
    }

    /// Puts photos back from Recently Deleted, in their trips, groups and
    /// chapters as before. Returns the ids that came back.
    @discardableResult
    static func recover(_ items: [MediaItem], accountID: String = MomentsAccount.localID, now: Date = .now, context: ModelContext) -> [String] {
        let back = items.filter { $0.deletedAt != nil && canDelete($0, accountID: accountID) }
        for item in back {
            item.deletedAt = nil
            item.deletedBy = nil
            item.updatedAt = now
            item.updatedBy = accountID
        }
        if !back.isEmpty { try? context.save() }
        return back.map(\.id)
    }

    /// Whole days before a photo in Recently Deleted is purged, as Photos
    /// counts them: a photo deleted today has 30 days left.
    static func daysLeft(_ item: MediaItem, now: Date = .now) -> Int {
        guard let deletedAt = item.deletedAt else { return retentionDays }
        let remaining = deletedAt.addingTimeInterval(retention).timeIntervalSince(now)
        return max(0, Int((remaining / 86_400).rounded(.up)))
    }

    static func isExpired(_ item: MediaItem, now: Date = .now) -> Bool {
        guard let deletedAt = item.deletedAt else { return false }
        return now.timeIntervalSince(deletedAt) >= retention
    }

    static func trashedItems(context: ModelContext) -> [MediaItem] {
        (try? context.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.deletedAt != nil }))) ?? []
    }

    /// Purges the photos whose 30 days are up. Returns how many went.
    @discardableResult
    static func purgeExpired(now: Date = .now, context: ModelContext) -> Int {
        let expired = trashedItems(context: context).filter { isExpired($0, now: now) }
        // Whoever deleted it, the 30 days are the same for both of us.
        return purge(expired, context: context)
    }

    /// Removes photos in Recently Deleted from Moments for good, with what
    /// hangs off them: memories, notes, tags, favorites, faces and their
    /// places in groups and chapters. Photos still in the library and a
    /// partner's photos are never purged here. Cannot be undone.
    @discardableResult
    static func deletePermanently(_ items: [MediaItem], accountID: String = MomentsAccount.localID, context: ModelContext) -> Int {
        purge(items.filter { canDelete($0, accountID: accountID) }, context: context)
    }

    private static func purge(_ candidates: [MediaItem], context: ModelContext) -> Int {
        let items = candidates.filter { $0.deletedAt != nil }
        guard !items.isEmpty else { return 0 }
        let ids = items.map(\.id)
        let idSet = Set(ids)
        // String-keyed records first, fetched before anything is deleted.
        let notes = (try? context.fetch(FetchDescriptor<PhotoNote>(predicate: #Predicate { ids.contains($0.mediaID) }))) ?? []
        let memberships = (try? context.fetch(FetchDescriptor<UserGroupItem>(predicate: #Predicate { ids.contains($0.mediaID) }))) ?? []
        let faces = (try? context.fetch(FetchDescriptor<FaceObservation>(predicate: #Predicate { ids.contains($0.mediaID) }))) ?? []
        let scans = (try? context.fetch(FetchDescriptor<FaceScanRecord>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
        for record in notes { context.delete(record) }
        for record in memberships { context.delete(record) }
        for record in faces { context.delete(record) }
        for record in scans { context.delete(record) }
        for item in items {
            for join in item.mediaTags { context.delete(join) }
            for favorite in item.favorites { context.delete(favorite) }
            // This photo's own place fixes; place-wide renames have no photo and stay.
            for override in item.placeOverrides { context.delete(override) }
            // Memories and their revisions go with the photo (cascade).
            context.delete(item)
        }
        try? context.save()
        ThumbnailCache.shared.removeFiles(for: idSet)
        return items.count
    }
}
