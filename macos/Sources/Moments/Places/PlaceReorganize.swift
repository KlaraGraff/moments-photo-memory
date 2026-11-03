import Foundation
import SwiftData

/// The Map page's "look place names up again". A city whose name is empty is
/// pending work for `PlaceNameBackfill`, so dropping the auto-found names is
/// all it takes to have them looked up afresh. A name this person typed is
/// never touched: Rename and Merge write a place-wide `PlaceOverride` (see
/// `Place.correctedName`), while `Place.name` only ever holds what the import
/// or the geocoder wrote.
enum PlaceReorganize {
    /// Empties the auto-found name of every city that has coordinates, so the
    /// backfill names it again. Cities without coordinates are left alone:
    /// there is nothing to look up. Returns how many names were cleared.
    @MainActor
    static func forgetAutoNames(context: ModelContext) throws -> Int {
        let cityKind = PlaceKind.city.rawValue
        // Same shape as the backfill's work list, without the empty-name part:
        // a name that is already empty is nothing to forget.
        let descriptor = FetchDescriptor<Place>(
            predicate: #Predicate {
                $0.kindRaw == cityKind && $0.latitude != nil && $0.longitude != nil
            }
        )
        let cities = try context.fetch(descriptor)
        var cleared = 0
        for city in cities {
            guard !city.name.isEmpty else { continue }
            // A rename of this person's lives in their override. Reading the
            // stored name alone cannot tell their name from an auto one, so
            // the override is what marks it.
            guard city.correctedName == nil else { continue }
            city.name = ""
            cleared += 1
        }
        try context.save()
        return cleared
    }

    /// The Map page's button: names the cities that have no name. With `all`,
    /// every auto-found name is dropped first so it is looked up again; a name
    /// this person typed stays either way. Returns how many cities were named.
    @MainActor
    @discardableResult
    static func run(container: ModelContainer, all: Bool) async throws -> Int {
        if all {
            _ = try forgetAutoNames(context: container.mainContext)
        }
        // The scheduler's own backfill, so this run uses the geocode cache and
        // the pacer shared with imports and the background pass.
        let backfill = PlaceNameBackfillScheduler.shared.makeBackfill()
        return try await backfill.run(container: container)
    }
}
