import Foundation

/// What the owner shares with the partner.
///
/// The owner picks trips (the owner's choice, 2026-11-26): only those trips,
/// their photos' previews and everything written about them go into the
/// shared zone. `wholeLibrary` stays available for tests and a later option.
public enum SharingScope: Equatable, Sendable, Codable {
    case wholeLibrary
    case selectedTrips(Set<String>)

    public func adding(tripID: String) -> SharingScope {
        switch self {
        case .wholeLibrary: return self
        case .selectedTrips(let ids): return .selectedTrips(ids.union([tripID]))
        }
    }

    public func removing(tripID: String) -> SharingScope {
        switch self {
        case .wholeLibrary: return self
        case .selectedTrips(let ids): return .selectedTrips(ids.subtracting([tripID]))
        }
    }

    public func contains(tripID: String) -> Bool {
        switch self {
        case .wholeLibrary: return true
        case .selectedTrips(let ids): return ids.contains(tripID)
        }
    }
}

/// Which records belong in the shared zone for a scope.
///
/// Photos belong when their trip is shared. Everything hanging off a photo
/// (memories, notes, favorites, tags on it, its preview) follows the photo.
/// Places, tags and chapters are pulled in when a shared record points at
/// them, and only then, so a place the partner never sees a photo of is
/// never shared.
public enum SharingScopeResolver {
    public static func includedKeys(scope: SharingScope, records: [SyncRecord]) -> Set<SyncRecordKey> {
        if case .wholeLibrary = scope {
            return Set(records.map(\.key))
        }
        guard case .selectedTrips(let tripIDs) = scope else { return [] }

        var byType: [SyncRecordType: [SyncRecord]] = [:]
        for record in records { byType[record.type, default: []].append(record) }
        func all(_ type: SyncRecordType) -> [SyncRecord] { byType[type] ?? [] }
        func ref(_ record: SyncRecord, _ field: String) -> String? { record.fields[field]?.stringValue }
        func isIn(_ id: String?, _ set: Set<String>) -> Bool {
            guard let id else { return false }
            return set.contains(id)
        }

        var included = Set<SyncRecordKey>()
        let trips = Set(all(.trip).map(\.id).filter { tripIDs.contains($0) })
        for id in trips { included.insert(SyncRecordKey(.trip, id)) }

        var media = Set<String>()
        var dayKeys = Set<String>()
        var places = Set<String>()
        for item in all(.mediaItem) {
            guard let tripID = ref(item, "tripID"), trips.contains(tripID) else { continue }
            media.insert(item.id)
            if let day = ref(item, "localDayKey") { dayKeys.insert(day) }
            if let placeID = ref(item, "placeID") { places.insert(placeID) }
        }
        for id in media { included.insert(SyncRecordKey(.mediaItem, id)) }

        // Places and their parents (a spot's area and city).
        let placeRecords = Dictionary(all(.place).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var frontier = Array(places)
        places = []
        while let id = frontier.popLast() {
            guard let place = placeRecords[id], !places.contains(id) else { continue }
            places.insert(id)
            if let parent = ref(place, "parentID") { frontier.append(parent) }
        }
        for id in places { included.insert(SyncRecordKey(.place, id)) }

        let mediaAnchored: [SyncRecordType] = [.previewAsset, .memory, .mediaTag, .favorite, .userGroupItem, .photoNote]
        for type in mediaAnchored {
            for record in all(type) where isIn(ref(record, "mediaID"), media) {
                included.insert(record.key)
            }
        }
        for record in all(.placeOverride) {
            let mediaID = ref(record, "mediaID")
            let belongs = mediaID != nil ? isIn(mediaID, media) : isIn(ref(record, "placeID"), places)
            if belongs { included.insert(record.key) }
        }

        var tags = Set<String>()
        var groups = Set<String>()
        var notes = Set<String>()
        var memories = Set<String>()
        for key in included {
            switch key.type {
            case .memory: memories.insert(key.id)
            case .photoNote: notes.insert(key.id)
            default: break
            }
        }
        for record in all(.mediaTag) where included.contains(record.key) {
            if let tag = ref(record, "tagID") { tags.insert(tag) }
        }
        for record in all(.userGroupItem) where included.contains(record.key) {
            if let group = ref(record, "groupID") { groups.insert(group) }
        }
        for record in all(.tag) where tags.contains(record.id) { included.insert(record.key) }
        for record in all(.userGroup) where groups.contains(record.id) { included.insert(record.key) }

        var placeKeys = Set<String>()
        for id in places {
            if let place = placeRecords[id], let name = ref(place, "name") { placeKeys.insert(placeNoteKey(name)) }
        }
        var writtenAbout = memories.union(notes)
        for record in all(.placeNote) {
            let bySource = isIn(ref(record, "sourceNoteID"), notes)
            let byPlace = isIn(ref(record, "placeKey"), placeKeys)
            if bySource || byPlace {
                included.insert(record.key)
                writtenAbout.insert(record.id)
            }
        }
        for record in all(.collectionMemory) {
            let key = ref(record, "scopeKey") ?? ""
            let belongs: Bool
            switch ref(record, "scopeRaw") {
            case "trip": belongs = trips.contains(key)
            case "day": belongs = dayKeys.contains(key)
            default: belongs = isIn(ref(record, "sourceNoteID"), notes)
            }
            if belongs {
                included.insert(record.key)
                writtenAbout.insert(record.id)
            }
        }
        // Kept revisions follow whatever they were kept for.
        for record in all(.memoryRevision) where isIn(ref(record, "memoryID"), writtenAbout) {
            included.insert(record.key)
        }
        return included
    }

    /// The same normalization as `PlaceNote.key(for:)` in the app.
    public static func placeNoteKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// What to change in the shared zone when the scope or the library moved
    /// from `old` to `new`: records that left are deleted from the zone (never
    /// from this device), records that joined are uploaded.
    public static func difference(old: Set<SyncRecordKey>, new: Set<SyncRecordKey>) -> (upload: [SyncRecordKey], removeFromZone: [SyncRecordKey]) {
        (new.subtracting(old).sorted(), old.subtracting(new).sorted())
    }
}
