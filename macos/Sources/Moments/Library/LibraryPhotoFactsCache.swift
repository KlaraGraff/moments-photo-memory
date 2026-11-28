import Foundation
import SwiftData

/// Each photo's `LibraryPhotoFacts`, kept across regroups so a regroup reads
/// from SwiftData only the photos that changed since the last one.
///
/// A photo is read again when the store lists it as edited (its date, place,
/// trip, kind, favorite or trash state moved), when one of its memories or
/// its place correction changed, or when the Mac's time zone changed (the
/// month and day keys depend on it). Places are a table of their own, read
/// again when the store's places move. Everything else stays as it was read.
@MainActor
final class LibraryPhotoFactsCache {
    static let shared = LibraryPhotoFactsCache()

    private var storeID: ObjectIdentifier?
    private var byID: [String: LibraryPhotoFacts] = [:]
    private var editMark: LibraryStore.PhotoEditMark?
    private var memoryStamps: [String: Int] = [:]
    private var overrideStamps: [String: Int] = [:]
    private var favoriteRevision: Int?
    private var placeRevision: Int?
    private var timeZoneID: String?
    private(set) var places: [String: LibraryPlaceFacts] = [:]
    private let monthFormatter: DateFormatter = LibraryRegroupEngine.makeMonthFormatter()

    /// How many photos were read from SwiftData since the cache was made;
    /// for tests and the page probe.
    private(set) var readCount = 0

    /// Photos read between two yields: a few milliseconds of main-thread time.
    static let sliceSize = 2_000

    /// Forgets everything; the next call reads every photo.
    func reset() {
        storeID = nil
        byID = [:]
        editMark = nil
        memoryStamps = [:]
        overrideStamps = [:]
        favoriteRevision = nil
        placeRevision = nil
        timeZoneID = nil
        places = [:]
    }

    /// The facts of the store's photos and screenshots, in the store's
    /// order. Photos it has to read are read a slice at a time with a yield
    /// in between, so a first visit to a large library never holds the main
    /// thread for long. Each model is looked up in the store when it is read,
    /// so a photo removed during a yield is skipped, never read. Nil when the
    /// task was cancelled before it finished; what it read stays.
    func facts(
        store: LibraryStore,
        memories: [Memory],
        overrides: [PlaceOverride],
        favoritesMatter: Bool
    ) async -> (regular: [LibraryPhotoFacts], screenshots: [LibraryPhotoFacts])? {
        forgetStale(store: store, memories: memories, overrides: overrides, favoritesMatter: favoritesMatter)
        let regularIDs: [String] = store.regularIDs
        let screenshotIDs: [String] = store.screenshotIDs
        guard let regularFacts = await read(regularIDs, store: store),
              let screenshotFacts = await read(screenshotIDs, store: store) else { return nil }
        // Photos that left the library (deleted for good) are dropped now and
        // then, not on every regroup.
        let live: Int = regularIDs.count + screenshotIDs.count
        if byID.count > live + max(1_000, live / 4) {
            var kept: [String: LibraryPhotoFacts] = [:]
            kept.reserveCapacity(live)
            for facts in regularFacts { kept[facts.id] = facts }
            for facts in screenshotFacts { kept[facts.id] = facts }
            byID = kept
        }
        return (regularFacts, screenshotFacts)
    }

    /// Drops the facts that may no longer be true, so `read` reads them again.
    private func forgetStale(store: LibraryStore, memories: [Memory], overrides: [PlaceOverride], favoritesMatter: Bool) {
        let id = ObjectIdentifier(store)
        let zone: String = TimeZone.current.identifier
        if storeID != id || timeZoneID != zone {
            reset()
            storeID = id
            timeZoneID = zone
        }

        // Photos the store says changed since the last call.
        let mark: LibraryStore.PhotoEditMark = store.photoEditMark
        if let editMark {
            if let edited = store.photosEdited(since: editMark) {
                for photoID in edited { byID[photoID] = nil }
            } else {
                byID = [:]
            }
        }
        editMark = mark

        // A memory written, edited or removed: that photo's memory flag.
        let newMemoryStamps: [String: Int] = Self.stamps(memories)
        forgetChanged(old: memoryStamps, new: newMemoryStamps)
        memoryStamps = newMemoryStamps

        // A place corrected on one photo.
        let newOverrideStamps: [String: Int] = Self.stamps(overrides)
        forgetChanged(old: overrideStamps, new: newOverrideStamps)
        overrideStamps = newOverrideStamps

        // A favorite always touches its photo too, which the store lists;
        // when the Favorites filter is on, a favorite saved without its photo
        // must not be missed, so then any change to favorites reads them all.
        if favoritesMatter, favoriteRevision != store.favoriteRevision {
            if favoriteRevision != nil { byID = [:] }
            favoriteRevision = store.favoriteRevision
        } else if favoriteRevision == nil {
            favoriteRevision = store.favoriteRevision
        }

        if placeRevision != store.placeRevision {
            var table: [String: LibraryPlaceFacts] = [:]
            table.reserveCapacity(store.places.count)
            for place in store.places { table[place.id] = LibraryPlaceFacts(place: place) }
            places = table
            placeRevision = store.placeRevision
        }
    }

    private func forgetChanged(old: [String: Int], new: [String: Int]) {
        guard old != new else { return }
        for (photoID, stamp) in new where old[photoID] != stamp { byID[photoID] = nil }
        for photoID in old.keys where new[photoID] == nil { byID[photoID] = nil }
    }

    private func read(_ ids: [String], store: LibraryStore) async -> [LibraryPhotoFacts]? {
        var result: [LibraryPhotoFacts] = []
        result.reserveCapacity(ids.count)
        var readInSlice = 0
        for photoID in ids {
            if let known = byID[photoID] {
                result.append(known)
                continue
            }
            guard let item = store.itemsByID[photoID] else { continue }
            let facts = LibraryPhotoFacts(item: item, monthFormatter: monthFormatter)
            byID[photoID] = facts
            result.append(facts)
            readCount += 1
            readInSlice += 1
            if readInSlice >= Self.sliceSize {
                readInSlice = 0
                await Task.yield()
                if Task.isCancelled { return nil }
            }
        }
        return result
    }

    /// One number per photo for the memories on it, so a change to any of
    /// them is noticed without reading the photo.
    private static func stamps(_ memories: [Memory]) -> [String: Int] {
        var result: [String: Int] = [:]
        for memory in memories {
            guard let mediaID = memory.mediaID else { continue }
            var hasher = Hasher()
            hasher.combine(memory.id)
            hasher.combine(memory.updatedAt)
            hasher.combine(memory.revision)
            result[mediaID, default: 0] &+= hasher.finalize()
        }
        return result
    }

    private static func stamps(_ overrides: [PlaceOverride]) -> [String: Int] {
        var result: [String: Int] = [:]
        for override in overrides {
            guard let mediaID = override.mediaID else { continue }
            var hasher = Hasher()
            hasher.combine(override.id)
            hasher.combine(override.accountID)
            hasher.combine(override.nameOverride)
            hasher.combine(override.updatedAt)
            result[mediaID, default: 0] &+= hasher.finalize()
        }
        return result
    }
}
