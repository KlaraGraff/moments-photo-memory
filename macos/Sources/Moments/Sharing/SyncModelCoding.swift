import Foundation
import MomentsCore
import SwiftData

// SwiftData models <-> MomentsCore `SyncRecord`s.
//
// Encoding writes only the fields `SyncSchema` lists; everything else on a
// model (bookmarks, Apple Photos identifiers, AI working state, faces) never
// leaves this Mac. Applying a record from the server writes only those same
// fields, so local-only fields survive, and it links relationships in either
// arrival order: a child whose parent is not here yet keeps the parent's ID
// and is linked when the parent arrives.

enum SyncModelCoding {
    /// The `MediaItem.sourceRaw` of a photo that came from the other person's
    /// Mac: it has no original here, only the shared preview.
    static let sharedSourceRaw = "shared"

    // MARK: Encoding

    static func record(_ item: MediaItem) -> SyncRecord {
        var record = SyncRecord(type: .mediaItem, id: item.id)
        record.set("captureDate", item.captureDate)
        record.set("latitude", item.latitude)
        record.set("longitude", item.longitude)
        record.set("kindRaw", item.kindRaw)
        record.set("width", item.width)
        record.set("height", item.height)
        record.set("isScreenshot", item.isScreenshot)
        record.set("title", item.title)
        record.setReference("tripID", item.trip?.id ?? item.tripID)
        record.setReference("placeID", item.place?.id)
        record.set("originalContentHash", item.originalContentHash)
        record.set("perceptualHash", item.perceptualHash)
        record.set("localTimeZoneOffsetMinutes", item.localTimeZoneOffsetMinutes)
        record.set("localDayKey", item.localDayKey)
        record.set("timeZoneIdentifier", item.timeZoneIdentifier)
        record.set("timeConfidenceRaw", item.timeConfidenceRaw)
        record.set("userCorrectedCaptureDateUTC", item.userCorrectedCaptureDateUTC)
        record.set("duration", item.duration)
        record.set("deletedAt", item.deletedAt)
        record.set("deletedBy", item.deletedBy)
        record.set("ownerAccountID", item.ownerAccountID)
        record.set("updatedAt", item.updatedAt)
        record.set("updatedBy", item.updatedBy)
        return record
    }

    static func record(_ trip: Trip) -> SyncRecord {
        var record = SyncRecord(type: .trip, id: trip.id)
        record.set("name", trip.name)
        record.set("startDate", trip.startDate)
        record.set("endDate", trip.endDate)
        record.set("overrideName", trip.overrideName)
        record.set("mergeOverrideID", trip.mergeOverrideID)
        record.set("splitOverrideDayKeys", trip.splitOverrideDayKeys)
        record.set("suggestionStatusRaw", trip.suggestionStatusRaw)
        record.set("confirmedAt", trip.confirmedAt)
        record.set("updatedAt", trip.updatedAt)
        record.set("updatedBy", trip.updatedBy)
        return record
    }

    static func record(_ place: Place) -> SyncRecord {
        var record = SyncRecord(type: .place, id: place.id)
        record.set("name", place.name)
        record.set("kindRaw", place.kindRaw)
        record.set("latitude", place.latitude)
        record.set("longitude", place.longitude)
        record.set("mapLink", place.mapLink)
        record.setReference("parentID", place.parent?.id)
        record.set("updatedAt", place.updatedAt)
        record.set("updatedBy", place.updatedBy)
        return record
    }

    static func record(_ memory: Memory) -> SyncRecord {
        var record = SyncRecord(type: .memory, id: memory.id)
        record.setReference("mediaID", memory.mediaItem?.id ?? memory.mediaID)
        record.set("text", memory.text)
        record.set("authorAccountID", memory.authorAccountID)
        record.set("createdAt", memory.createdAt)
        record.set("revision", memory.revision)
        record.set("updatedAt", memory.updatedAt)
        record.set("updatedBy", memory.updatedBy)
        return record
    }

    static func record(_ revision: MemoryRevision) -> SyncRecord {
        var record = SyncRecord(type: .memoryRevision, id: revision.id)
        record.setReference("memoryID", revision.memory?.id ?? revision.memoryID)
        record.set("text", revision.text)
        record.set("editedBy", revision.editedBy)
        record.set("editedAt", revision.editedAt)
        record.set("baseRevision", revision.baseRevision)
        record.set("reason", revision.reason)
        return record
    }

    static func record(_ tag: Tag) -> SyncRecord {
        var record = SyncRecord(type: .tag, id: tag.id)
        record.set("normalizedName", tag.normalizedName)
        record.set("displayName", tag.displayName)
        record.set("updatedAt", tag.updatedAt)
        record.set("updatedBy", tag.updatedBy)
        return record
    }

    static func record(_ join: MediaTag) -> SyncRecord {
        var record = SyncRecord(type: .mediaTag, id: join.id)
        record.setReference("mediaID", join.mediaItem?.id ?? join.mediaID)
        record.setReference("tagID", join.tag?.id ?? join.tagID)
        record.set("updatedAt", join.updatedAt)
        record.set("updatedBy", join.updatedBy)
        return record
    }

    static func record(_ favorite: Favorite) -> SyncRecord {
        var record = SyncRecord(type: .favorite, id: favorite.id)
        record.setReference("mediaID", favorite.mediaItem?.id ?? favorite.mediaID)
        record.set("accountID", favorite.accountID)
        record.set("isFavorite", favorite.isFavorite)
        record.set("changedAt", favorite.changedAt)
        return record
    }

    static func record(_ override: PlaceOverride) -> SyncRecord {
        var record = SyncRecord(type: .placeOverride, id: override.id)
        record.setReference("placeID", override.place?.id ?? override.placeID)
        record.setReference("mediaID", override.mediaItem?.id ?? override.mediaID)
        record.set("accountID", override.accountID)
        record.set("nameOverride", override.nameOverride)
        record.set("mapLinkOverride", override.mapLinkOverride)
        record.set("latitude", override.latitude)
        record.set("longitude", override.longitude)
        record.set("updatedAt", override.updatedAt)
        record.set("updatedBy", override.updatedBy)
        return record
    }

    static func record(_ group: UserGroup) -> SyncRecord {
        var record = SyncRecord(type: .userGroup, id: group.id)
        record.set("name", group.name)
        record.set("kindRaw", group.kindRaw)
        record.set("rulesData", group.rulesData)
        record.set("ownerAccountID", group.ownerAccountID)
        record.set("createdAt", group.createdAt)
        record.set("updatedAt", group.updatedAt)
        return record
    }

    static func record(_ item: UserGroupItem) -> SyncRecord {
        var record = SyncRecord(type: .userGroupItem, id: item.id)
        record.setReference("groupID", item.groupID)
        record.setReference("mediaID", item.mediaID)
        record.set("addedBy", item.addedBy)
        record.set("excluded", item.excluded)
        record.set("addedAt", item.addedAt)
        return record
    }

    static func record(_ note: PhotoNote) -> SyncRecord {
        var record = SyncRecord(type: .photoNote, id: note.id)
        record.setReference("mediaID", note.mediaID)
        record.set("authorAccountID", note.authorAccountID)
        record.set("text", note.text)
        record.set("createdAt", note.createdAt)
        record.set("updatedAt", note.updatedAt)
        return record
    }

    static func record(_ note: PlaceNote) -> SyncRecord {
        var record = SyncRecord(type: .placeNote, id: note.id)
        record.set("placeKey", note.placeKey)
        record.set("placeName", note.placeName)
        record.set("text", note.text)
        record.set("authorAccountID", note.authorAccountID)
        record.setReference("sourceNoteID", note.sourceNoteID)
        record.set("updatedAt", note.updatedAt)
        return record
    }

    static func record(_ memory: CollectionMemory) -> SyncRecord {
        var record = SyncRecord(type: .collectionMemory, id: memory.id)
        record.set("scopeRaw", memory.scopeRaw)
        record.set("scopeKey", memory.scopeKey)
        record.set("text", memory.text)
        record.set("authorAccountID", memory.authorAccountID)
        record.set("createdAt", memory.createdAt)
        record.setReference("sourceNoteID", memory.sourceNoteID)
        record.set("updatedAt", memory.updatedAt)
        return record
    }

    /// Every syncable record in the store, for ``SyncCoordinator/reconcile(localRecords:)``
    /// and ``SharingScopeResolver``. Previews are listed separately by the
    /// preview cache, not by the store.
    static func allRecords(in context: ModelContext) throws -> [SyncRecord] {
        var records: [SyncRecord] = []
        records += try context.fetch(FetchDescriptor<Place>()).map { record($0) }
        records += try context.fetch(FetchDescriptor<Tag>()).map { record($0) }
        records += try context.fetch(FetchDescriptor<UserGroup>()).map { record($0) }
        records += try context.fetch(FetchDescriptor<Trip>()).map { record($0) }
        records += try context.fetch(FetchDescriptor<MediaItem>()).map { record($0) }
        records += try context.fetch(FetchDescriptor<Memory>()).map { record($0) }
        records += try context.fetch(FetchDescriptor<MemoryRevision>()).map { record($0) }
        records += try context.fetch(FetchDescriptor<MediaTag>()).map { record($0) }
        records += try context.fetch(FetchDescriptor<Favorite>()).map { record($0) }
        records += try context.fetch(FetchDescriptor<PlaceOverride>()).map { record($0) }
        records += try context.fetch(FetchDescriptor<UserGroupItem>()).map { record($0) }
        records += try context.fetch(FetchDescriptor<PhotoNote>()).map { record($0) }
        records += try context.fetch(FetchDescriptor<PlaceNote>()).map { record($0) }
        records += try context.fetch(FetchDescriptor<CollectionMemory>()).map { record($0) }
        return records
    }

    // MARK: Lookup

    static func record(for key: SyncRecordKey, in context: ModelContext) throws -> SyncRecord? {
        let id = key.id
        switch key.type {
        case .place: return try find(Place.self, #Predicate { $0.id == id }, in: context).map { record($0) }
        case .tag: return try find(Tag.self, #Predicate { $0.id == id }, in: context).map { record($0) }
        case .trip: return try find(Trip.self, #Predicate { $0.id == id }, in: context).map { record($0) }
        case .mediaItem: return try find(MediaItem.self, #Predicate { $0.id == id }, in: context).map { record($0) }
        case .memory: return try find(Memory.self, #Predicate { $0.id == id }, in: context).map { record($0) }
        case .memoryRevision: return try find(MemoryRevision.self, #Predicate { $0.id == id }, in: context).map { record($0) }
        case .mediaTag: return try find(MediaTag.self, #Predicate { $0.id == id }, in: context).map { record($0) }
        case .favorite: return try find(Favorite.self, #Predicate { $0.id == id }, in: context).map { record($0) }
        case .placeOverride: return try find(PlaceOverride.self, #Predicate { $0.id == id }, in: context).map { record($0) }
        case .userGroup: return try find(UserGroup.self, #Predicate { $0.id == id }, in: context).map { record($0) }
        case .userGroupItem: return try find(UserGroupItem.self, #Predicate { $0.id == id }, in: context).map { record($0) }
        case .photoNote: return try find(PhotoNote.self, #Predicate { $0.id == id }, in: context).map { record($0) }
        case .placeNote: return try find(PlaceNote.self, #Predicate { $0.id == id }, in: context).map { record($0) }
        case .collectionMemory: return try find(CollectionMemory.self, #Predicate { $0.id == id }, in: context).map { record($0) }
        case .previewAsset: return nil
        }
    }

    static func find<Model: PersistentModel>(_ type: Model.Type, _ predicate: Predicate<Model>, in context: ModelContext) throws -> Model? {
        var descriptor = FetchDescriptor<Model>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
