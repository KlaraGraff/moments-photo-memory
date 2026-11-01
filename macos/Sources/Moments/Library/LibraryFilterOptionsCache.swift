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

    private static var lastKey: Int?
    private static var lastOptions: LibraryFilterOptionSet?

    /// Forgets the last build, so a test starts from an empty cache.
    static func resetForTests() {
        lastKey = nil
        lastOptions = nil
        buildCount = 0
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

    /// The cached options when `key` matches the last build; otherwise builds,
    /// keeps and returns them.
    static func options(for items: [MediaItem], key: Int) -> LibraryFilterOptionSet {
        if let lastOptions, lastKey == key { return lastOptions }
        let options = build(from: items)
        lastKey = key
        lastOptions = options
        return options
    }

    /// One pass over the photos, once per change. The trips come from the
    /// photos, so a trip nobody's photo mentions is not listed.
    private static func build(from items: [MediaItem]) -> LibraryFilterOptionSet {
        buildCount += 1
        var tripNames: [String: String] = [:]
        for item in items {
            guard let tripID = item.tripID else { continue }
            if tripNames[tripID] == nil {
                tripNames[tripID] = item.trip?.effectiveName ?? tripID
            }
        }
        return LibraryFilterOptionSet(
            // One row per name: unnamed spots are listed under the area or
            // city that names them, places with the same name are one row,
            // and the filter matches all of them.
            places: PlaceNames.options(for: items),
            trips: tripNames.keys.sorted(),
            tripNames: tripNames
        )
    }
}
