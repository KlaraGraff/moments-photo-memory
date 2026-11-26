import Foundation
import MomentsCore
import SwiftData

/// Writes records that arrived from the server into SwiftData.
///
/// Only the fields `SyncSchema` lists are written. A record whose parent has
/// not arrived yet keeps the parent's ID; when the parent arrives, its
/// waiting children are linked.
struct SyncModelApplier {
    let context: ModelContext
    let accounts: SyncAccountMap
    /// Place links whose target has not arrived yet (SwiftData keeps these
    /// two only as relationships, so the ID is remembered here).
    let orphans: SyncOrphanLinks

    func apply(_ record: SyncRecord) throws {
        switch record.type {
        case .place: try applyPlace(record)
        case .tag: try applyTag(record)
        case .trip: try applyTrip(record)
        case .mediaItem: try applyMedia(record)
        case .memory: try applyMemory(record)
        case .memoryRevision: try applyRevision(record)
        case .mediaTag: try applyMediaTag(record)
        case .favorite: try applyFavorite(record)
        case .placeOverride: try applyPlaceOverride(record)
        case .userGroup: try applyGroup(record)
        case .userGroupItem: try applyGroupItem(record)
        case .photoNote: try applyPhotoNote(record)
        case .placeNote: try applyPlaceNote(record)
        case .collectionMemory: try applyCollectionMemory(record)
        case .previewAsset: break
        }
    }

    /// The server deleted the record. A photo that leaves the share is
    /// removed from this Mac only if it came from the other Mac; this
    /// person's own photo (and its original) is never deleted by sync.
    func delete(_ key: SyncRecordKey) throws {
        let id = key.id
        switch key.type {
        case .mediaItem:
            guard let item = try find(MediaItem.self, #Predicate { $0.id == id }) else { return }
            if item.sourceRaw == SyncModelCoding.sharedSourceRaw { context.delete(item) }
        case .place: try deleteModel(Place.self, #Predicate { $0.id == id })
        case .tag: try deleteModel(Tag.self, #Predicate { $0.id == id })
        case .trip: try deleteModel(Trip.self, #Predicate { $0.id == id })
        case .memory: try deleteModel(Memory.self, #Predicate { $0.id == id })
        case .memoryRevision: try deleteModel(MemoryRevision.self, #Predicate { $0.id == id })
        case .mediaTag: try deleteModel(MediaTag.self, #Predicate { $0.id == id })
        case .favorite: try deleteModel(Favorite.self, #Predicate { $0.id == id })
        case .placeOverride: try deleteModel(PlaceOverride.self, #Predicate { $0.id == id })
        case .userGroup: try deleteModel(UserGroup.self, #Predicate { $0.id == id })
        case .userGroupItem: try deleteModel(UserGroupItem.self, #Predicate { $0.id == id })
        case .photoNote: try deleteModel(PhotoNote.self, #Predicate { $0.id == id })
        case .placeNote: try deleteModel(PlaceNote.self, #Predicate { $0.id == id })
        case .collectionMemory: try deleteModel(CollectionMemory.self, #Predicate { $0.id == id })
        case .previewAsset: break
        }
    }

    // MARK: Per type

    private func applyPlace(_ r: SyncRecord) throws {
        let id = r.id
        let place = try find(Place.self, #Predicate { $0.id == id }) ?? insert(Place(id: id, name: ""))
        place.name = r.string("name") ?? ""
        place.kindRaw = r.string("kindRaw") ?? PlaceKind.spot.rawValue
        place.latitude = r.double("latitude")
        place.longitude = r.double("longitude")
        place.mapLink = r.string("mapLink")
        place.updatedAt = r.date("updatedAt") ?? .now
        place.updatedBy = r.string("updatedBy")
        orphans.resolve(.placeParent, of: id, to: nil)
        if let parentID = r.string("parentID") {
            if place.parent?.id != parentID {
                place.parent = try find(Place.self, #Predicate { $0.id == parentID })
                if place.parent == nil { orphans.resolve(.placeParent, of: id, to: parentID) }
            }
        } else {
            place.parent = nil
        }
        // Children and photos that arrived first.
        for childID in orphans.waiting(.placeParent, on: id) {
            if let child = try find(Place.self, #Predicate { $0.id == childID }) { child.parent = place }
            orphans.resolve(.placeParent, of: childID, to: nil)
        }
        for mediaID in orphans.waiting(.mediaPlace, on: id) {
            if let item = try find(MediaItem.self, #Predicate { $0.id == mediaID }) { item.place = place }
            orphans.resolve(.mediaPlace, of: mediaID, to: nil)
        }
    }

    private func applyTag(_ r: SyncRecord) throws {
        let id = r.id
        let tag = try find(Tag.self, #Predicate { $0.id == id }) ?? insert(Tag(id: id, displayName: ""))
        tag.displayName = r.string("displayName") ?? ""
        tag.normalizedName = r.string("normalizedName") ?? Tag.normalize(tag.displayName)
        tag.updatedAt = r.date("updatedAt") ?? .now
        tag.updatedBy = r.string("updatedBy")
        for join in try context.fetch(FetchDescriptor<MediaTag>(predicate: #Predicate { $0.tagID == id })) where join.tag == nil {
            join.tag = tag
        }
    }

    private func applyTrip(_ r: SyncRecord) throws {
        let id = r.id
        let trip = try find(Trip.self, #Predicate { $0.id == id }) ?? insert(Trip(id: id, name: ""))
        trip.name = r.string("name") ?? ""
        trip.startDate = r.date("startDate")
        trip.endDate = r.date("endDate")
        trip.overrideName = r.string("overrideName")
        trip.mergeOverrideID = r.string("mergeOverrideID")
        trip.splitOverrideDayKeys = r.string("splitOverrideDayKeys")
        trip.suggestionStatusRaw = r.string("suggestionStatusRaw")
        trip.confirmedAt = r.date("confirmedAt")
        trip.updatedAt = r.date("updatedAt") ?? .now
        trip.updatedBy = r.string("updatedBy")
        let tripID: String? = id
        for item in try context.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.tripID == tripID })) where item.trip == nil {
            item.trip = trip
        }
    }

    private func applyMedia(_ r: SyncRecord) throws {
        let id = r.id
        let item: MediaItem
        if let existing = try find(MediaItem.self, #Predicate { $0.id == id }) {
            item = existing
        } else {
            item = insert(MediaItem(id: id, source: .file))
            item.sourceRaw = SyncModelCoding.sharedSourceRaw
        }
        item.captureDate = r.date("captureDate")
        item.latitude = r.double("latitude")
        item.longitude = r.double("longitude")
        item.kindRaw = r.string("kindRaw") ?? MediaKind.photo.rawValue
        item.width = r.int("width") ?? 0
        item.height = r.int("height") ?? 0
        item.isScreenshot = r.bool("isScreenshot") ?? false
        item.originalContentHash = r.string("originalContentHash") ?? item.originalContentHash
        item.perceptualHash = r.string("perceptualHash")
        item.localTimeZoneOffsetMinutes = r.int("localTimeZoneOffsetMinutes")
        item.localDayKey = r.string("localDayKey")
        item.timeZoneIdentifier = r.string("timeZoneIdentifier")
        item.timeConfidenceRaw = r.string("timeConfidenceRaw")
        item.userCorrectedCaptureDateUTC = r.date("userCorrectedCaptureDateUTC")
        item.duration = r.double("duration")
        item.deletedAt = r.date("deletedAt")
        item.deletedBy = r.string("deletedBy")
        item.ownerAccountID = local(r.string("ownerAccountID"))
        item.updatedAt = r.date("updatedAt") ?? .now
        item.updatedBy = r.string("updatedBy")

        let tripID = r.string("tripID")
        item.tripID = tripID
        if let tripID {
            if item.trip?.id != tripID { item.trip = try find(Trip.self, #Predicate { $0.id == tripID }) }
        } else {
            item.trip = nil
        }
        orphans.resolve(.mediaPlace, of: id, to: nil)
        if let placeID = r.string("placeID") {
            if item.place?.id != placeID {
                item.place = try find(Place.self, #Predicate { $0.id == placeID })
                if item.place == nil { orphans.resolve(.mediaPlace, of: id, to: placeID) }
            }
        } else {
            item.place = nil
        }
        try linkChildren(ofMedia: item)
    }

    /// Memories, tags, favorites and personal place names that arrived
    /// before their photo.
    private func linkChildren(ofMedia item: MediaItem) throws {
        let mediaID: String? = item.id
        for memory in try context.fetch(FetchDescriptor<Memory>(predicate: #Predicate { $0.mediaID == mediaID })) where memory.mediaItem == nil {
            memory.mediaItem = item
        }
        for join in try context.fetch(FetchDescriptor<MediaTag>(predicate: #Predicate { $0.mediaID == mediaID })) where join.mediaItem == nil {
            join.mediaItem = item
        }
        for favorite in try context.fetch(FetchDescriptor<Favorite>(predicate: #Predicate { $0.mediaID == mediaID })) where favorite.mediaItem == nil {
            favorite.mediaItem = item
        }
        for override in try context.fetch(FetchDescriptor<PlaceOverride>(predicate: #Predicate { $0.mediaID == mediaID })) where override.mediaItem == nil {
            override.mediaItem = item
        }
    }

    private func applyMemory(_ r: SyncRecord) throws {
        let id = r.id
        let memory = try find(Memory.self, #Predicate { $0.id == id }) ?? insert(Memory(id: id, text: ""))
        memory.text = r.string("text") ?? ""
        memory.authorAccountID = local(r.string("authorAccountID"))
        memory.author = accounts.role(of: memory.authorAccountID) == .me ? .me : .partner
        memory.createdAt = r.date("createdAt") ?? memory.createdAt
        memory.revision = r.int("revision") ?? memory.revision
        memory.updatedAt = r.date("updatedAt") ?? .now
        memory.updatedBy = r.string("updatedBy")
        let mediaID = r.string("mediaID")
        memory.mediaID = mediaID
        if let mediaID, memory.mediaItem?.id != mediaID {
            memory.mediaItem = try find(MediaItem.self, #Predicate { $0.id == mediaID })
        }
        let memoryID: String? = id
        for revision in try context.fetch(FetchDescriptor<MemoryRevision>(predicate: #Predicate { $0.memoryID == memoryID })) where revision.memory == nil {
            revision.memory = memory
        }
    }

    private func applyRevision(_ r: SyncRecord) throws {
        let id = r.id
        let revision = try find(MemoryRevision.self, #Predicate { $0.id == id })
            ?? insert(MemoryRevision(id: id, text: "", baseRevision: 0))
        revision.text = r.string("text") ?? ""
        revision.editedBy = r.string("editedBy")
        revision.editedAt = r.date("editedAt") ?? .now
        revision.baseRevision = r.int("baseRevision") ?? 0
        revision.reason = r.string("reason")
        let memoryID = r.string("memoryID")
        revision.memoryID = memoryID
        if let memoryID, revision.memory?.id != memoryID {
            revision.memory = try find(Memory.self, #Predicate { $0.id == memoryID })
        }
    }

    private func applyMediaTag(_ r: SyncRecord) throws {
        let id = r.id
        let join = try find(MediaTag.self, #Predicate { $0.id == id }) ?? insert(MediaTag(id: id))
        join.updatedAt = r.date("updatedAt") ?? .now
        join.updatedBy = r.string("updatedBy")
        let mediaID = r.string("mediaID")
        let tagID = r.string("tagID")
        join.mediaID = mediaID
        join.tagID = tagID
        if let mediaID, join.mediaItem?.id != mediaID {
            join.mediaItem = try find(MediaItem.self, #Predicate { $0.id == mediaID })
        }
        if let tagID, join.tag?.id != tagID {
            join.tag = try find(Tag.self, #Predicate { $0.id == tagID })
        }
    }

    private func applyFavorite(_ r: SyncRecord) throws {
        let id = r.id
        let accountID = local(r.string("accountID")) ?? SyncAccountMap.localAlias
        let favorite = try find(Favorite.self, #Predicate { $0.id == id })
            ?? insert(Favorite(id: id, mediaID: r.string("mediaID"), accountID: accountID, isFavorite: false))
        favorite.accountID = accountID
        favorite.isFavorite = r.bool("isFavorite") ?? false
        favorite.changedAt = r.date("changedAt") ?? .now
        let mediaID = r.string("mediaID")
        favorite.mediaID = mediaID
        if let mediaID, favorite.mediaItem?.id != mediaID {
            favorite.mediaItem = try find(MediaItem.self, #Predicate { $0.id == mediaID })
        }
    }

    private func applyPlaceOverride(_ r: SyncRecord) throws {
        let id = r.id
        let accountID = local(r.string("accountID")) ?? SyncAccountMap.localAlias
        let override = try find(PlaceOverride.self, #Predicate { $0.id == id })
            ?? insert(PlaceOverride(id: id, accountID: accountID))
        override.accountID = accountID
        override.nameOverride = r.string("nameOverride")
        override.mapLinkOverride = r.string("mapLinkOverride")
        override.latitude = r.double("latitude")
        override.longitude = r.double("longitude")
        override.updatedAt = r.date("updatedAt") ?? .now
        override.updatedBy = r.string("updatedBy")
        let placeID = r.string("placeID")
        let mediaID = r.string("mediaID")
        override.placeID = placeID
        override.mediaID = mediaID
        if let placeID, override.place?.id != placeID {
            override.place = try find(Place.self, #Predicate { $0.id == placeID })
        }
        if let mediaID, override.mediaItem?.id != mediaID {
            override.mediaItem = try find(MediaItem.self, #Predicate { $0.id == mediaID })
        }
    }

    private func applyGroup(_ r: SyncRecord) throws {
        let id = r.id
        let group = try find(UserGroup.self, #Predicate { $0.id == id }) ?? insert(UserGroup(id: id, name: ""))
        group.name = r.string("name") ?? ""
        group.kindRaw = r.string("kindRaw") ?? UserGroup.Kind.manual.rawValue
        group.rulesData = r.data("rulesData") ?? Data()
        group.ownerAccountID = local(r.string("ownerAccountID")) ?? SyncAccountMap.localAlias
        group.createdAt = r.date("createdAt") ?? group.createdAt
        group.updatedAt = r.date("updatedAt") ?? .now
    }

    private func applyGroupItem(_ r: SyncRecord) throws {
        let id = r.id
        let item = try find(UserGroupItem.self, #Predicate { $0.id == id })
            ?? insert(UserGroupItem(id: id, groupID: "", mediaID: ""))
        item.groupID = r.string("groupID") ?? ""
        item.mediaID = r.string("mediaID") ?? ""
        item.addedBy = local(r.string("addedBy")) ?? SyncAccountMap.localAlias
        item.excluded = r.bool("excluded") ?? false
        item.addedAt = r.date("addedAt") ?? .now
    }

    private func applyPhotoNote(_ r: SyncRecord) throws {
        let id = r.id
        let note: PhotoNote
        if let existing = try find(PhotoNote.self, #Predicate { $0.id == id }) {
            note = existing
        } else {
            // A note from the other Mac was organized there; it is never
            // organized again here.
            note = insert(PhotoNote(id: id, mediaID: r.string("mediaID") ?? "", text: "", status: .done))
        }
        note.mediaID = r.string("mediaID") ?? note.mediaID
        note.authorAccountID = local(r.string("authorAccountID")) ?? SyncAccountMap.localAlias
        note.text = r.string("text") ?? ""
        note.createdAt = r.date("createdAt") ?? note.createdAt
        note.updatedAt = r.date("updatedAt") ?? .now
    }

    private func applyPlaceNote(_ r: SyncRecord) throws {
        let id = r.id
        let note = try find(PlaceNote.self, #Predicate { $0.id == id }) ?? insert(PlaceNote(id: id, placeName: "", text: ""))
        note.placeName = r.string("placeName") ?? ""
        note.placeKey = r.string("placeKey") ?? PlaceNote.key(for: note.placeName)
        note.text = r.string("text") ?? ""
        note.authorAccountID = local(r.string("authorAccountID")) ?? SyncAccountMap.localAlias
        note.sourceNoteID = r.string("sourceNoteID")
        note.updatedAt = r.date("updatedAt") ?? .now
    }

    private func applyCollectionMemory(_ r: SyncRecord) throws {
        let id = r.id
        let memory = try find(CollectionMemory.self, #Predicate { $0.id == id })
            ?? insert(CollectionMemory(id: id, scope: .day, scopeKey: "", text: ""))
        memory.scopeRaw = r.string("scopeRaw") ?? NoteMemoryScope.day.rawValue
        memory.scopeKey = r.string("scopeKey") ?? ""
        memory.text = r.string("text") ?? ""
        memory.authorAccountID = local(r.string("authorAccountID")) ?? SyncAccountMap.localAlias
        memory.createdAt = r.date("createdAt") ?? memory.createdAt
        memory.sourceNoteID = r.string("sourceNoteID")
        memory.updatedAt = r.date("updatedAt") ?? .now
    }

    // MARK: Helpers

    /// Records arrive in local spelling already; this only keeps the type.
    private func local(_ accountID: String?) -> String? { accountID }

    private func find<Model: PersistentModel>(_ type: Model.Type, _ predicate: Predicate<Model>) throws -> Model? {
        try SyncModelCoding.find(type, predicate, in: context)
    }

    private func insert<Model: PersistentModel>(_ model: Model) -> Model {
        context.insert(model)
        return model
    }

    private func deleteModel<Model: PersistentModel>(_ type: Model.Type, _ predicate: Predicate<Model>) throws {
        if let model = try find(type, predicate) { context.delete(model) }
    }
}
