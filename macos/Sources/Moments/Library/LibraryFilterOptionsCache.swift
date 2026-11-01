import Foundation
import SwiftData

/// The Library's place and trip filter options. The grid and the filter
/// chips need the same options from the same photos, so they share one
/// build per change instead of building them twice.
struct LibraryFilterOptionSet: Equatable {
    var places: [LibraryPlaceOption] = []
    var trips: [String] = []
    var tripNames: [String: String] = [:]
}

@MainActor
enum LibraryFilterOptionsCache {
    /// How many option sets were built; tests read it to prove a cache hit
    /// did not build again.
    static var buildCount = 0
    /// How many times the photos were read into sources; a place-only save
    /// must not read them again.
    static var sourceBuildCount = 0

    private static var lastKey: Int?
    private static var lastOptions: LibraryFilterOptionSet?

    private static var lastSourceKey: Int?
    private static var lastSources: Sources?

    /// What the photos are listed under, counted: the trips' names and, per
    /// override name and per place, how many photos are listed that way. A
    /// place rename only changes the names read from the places, so the
    /// options can be rebuilt from this without touching the photos.
    private struct Sources {
        var tripNames: [String: String] = [:]
        var overrideCounts: [String: Int] = [:]
        var placeCounts: [PersistentIdentifier: (place: Place, count: Int)] = [:]
    }

    /// Forgets the last build and the sources, so a test starts from an
    /// empty cache.
    static func resetForTests() {
        lastKey = nil
        lastOptions = nil
        lastSourceKey = nil
        lastSources = nil
        buildCount = 0
        sourceBuildCount = 0
    }

    /// The key both callers use: the store's revision plus each trip's id and names.
    static func key(revision: Int, trips: [Trip]) -> Int {
        var hasher = Hasher()
        hasher.combine(revision)
        for trip in trips {
            hasher.combine(trip.id)
            hasher.combine(trip.name)
            hasher.combine(trip.overrideName)
        }
        return hasher.finalize()
    }

    /// The key for the photos' sources: the same trip inputs as `key`, under
    /// a fixed marker so the two keys never collide.
    static func sourceKey(photoFaceRevision: Int, trips: [Trip]) -> Int {
        var hasher = Hasher()
        hasher.combine("sources")
        hasher.combine(photoFaceRevision)
        for trip in trips {
            hasher.combine(trip.id)
            hasher.combine(trip.name)
            hasher.combine(trip.overrideName)
        }
        return hasher.finalize()
    }

    /// The cached options when `key` matches the last build; otherwise builds,
    /// keeps and returns them.
    static func options(for items: [MediaItem], key: Int) -> LibraryFilterOptionSet {
        options(for: items, key: key, sourceKey: key)
    }

    /// As `options(for:key:)`, except that a build under a new `key` reuses
    /// the sources when `sourceKey` says only place names can have changed;
    /// then the photos are not read again.
    static func options(for items: [MediaItem], key: Int, sourceKey: Int) -> LibraryFilterOptionSet {
        if let lastOptions, lastKey == key { return lastOptions }
        var sources: Sources
        if let lastSources, lastSourceKey == sourceKey {
            sources = lastSources
        } else {
            sources = Sources()
            buildSources(into: &sources, from: items)
            lastSourceKey = sourceKey
            lastSources = sources
        }
        let options = options(from: sources)
        lastKey = key
        lastOptions = options
        return options
    }

    /// The options for `sources`: the trips come from the photos, so a trip
    /// nobody's photo mentions is not listed.
    private static func options(from sources: Sources) -> LibraryFilterOptionSet {
        buildCount += 1
        return LibraryFilterOptionSet(
            // One row per name: unnamed spots are listed under the area or
            // city that names them, places with the same name are one row,
            // and the filter matches all of them.
            places: PlaceNames.options(
                overrideCounts: sources.overrideCounts,
                placeCounts: sources.placeCounts
            ),
            trips: sources.tripNames.keys.sorted(),
            tripNames: sources.tripNames
        )
    }

    /// One pass over the photos, once per change. Each photo is counted under
    /// its trimmed per-photo name, else under its place (the place's own name
    /// is resolved later, once per place).
    private static func buildSources(into sources: inout Sources, from items: [MediaItem]) {
        sourceBuildCount += 1
        for item in items {
            if let tripID = item.tripID {
                if sources.tripNames[tripID] == nil {
                    sources.tripNames[tripID] = item.trip?.effectiveName ?? tripID
                }
            }
            if let override = item.placeOverrideName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !override.isEmpty {
                sources.overrideCounts[override, default: 0] += 1
                continue
            }
            guard let place = item.place else { continue }
            let id = place.persistentModelID
            if let entry = sources.placeCounts[id] {
                sources.placeCounts[id] = (place: entry.place, count: entry.count + 1)
            } else {
                sources.placeCounts[id] = (place: place, count: 1)
            }
        }
    }
}
