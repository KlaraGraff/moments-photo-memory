import Foundation
import SwiftData
import XCTest
@testable import Moments

/// Proves the shared filter options are built once per key and still match
/// what the Library's filter chips built on their own before the cache.
@MainActor
final class LibraryFilterOptionsCacheTests: XCTestCase {
    private var container: ModelContainer?

    override func setUp() {
        super.setUp()
        LibraryFilterOptionsCache.resetForTests()
    }

    override func tearDown() {
        LibraryFilterOptionsCache.resetForTests()
        container = nil
        super.tearDown()
    }

    private func makeContext() throws -> ModelContext {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        self.container = container
        return container.mainContext
    }

    /// `LibraryFilterChips.buildOptions()` before the cache, as a reference.
    private func referenceOptions(for items: [MediaItem]) -> LibraryFilterOptionSet {
        var tripNames: [String: String] = [:]
        for item in items {
            if let tripID = item.tripID, tripNames[tripID] == nil {
                tripNames[tripID] = item.trip?.effectiveName ?? tripID
            }
        }
        return LibraryFilterOptionSet(
            places: PlaceNames.options(for: items),
            trips: tripNames.keys.sorted(),
            tripNames: tripNames
        )
    }

    /// 200 synthetic photos in 5 trips, over a handful of places, with some
    /// per-photo place names and one trip whose photos disagree about the name.
    private func makeFixture(in context: ModelContext) throws -> [MediaItem] {
        var trips: [Trip] = []
        for index in 0..<5 {
            let trip = Trip(id: "trip-\(index)", name: "Trip \(index)")
            context.insert(trip)
            trips.append(trip)
        }
        let city = Place(id: "city-fixture", name: "Fixture City", kind: .city)
        context.insert(city)
        var spots: [Place] = []
        for index in 0..<6 {
            let spot = Place(id: "spot-fixture-\(index)", name: "Spot \(index)", parent: city)
            context.insert(spot)
            spots.append(spot)
        }

        var items: [MediaItem] = []
        items.reserveCapacity(200)
        for index in 0..<200 {
            let trip: Trip = trips[index % trips.count]
            let place: Place? = index % 17 == 0 ? nil : spots[index % spots.count]
            let item = MediaItem(id: "item-\(index)", place: place, trip: trip)
            context.insert(item)
            if index % 23 == 0 {
                context.insert(PlaceOverride(mediaID: item.id, nameOverride: "Own \(index)", mediaItem: item))
            }
            items.append(item)
        }
        try context.save()
        return items
    }

    func testSameKeyReturnsTheCachedResultWithoutBuildingAgain() throws {
        let context = try makeContext()
        let items = try makeFixture(in: context)
        let trips = try context.fetch(FetchDescriptor<Trip>(sortBy: [SortDescriptor(\.id)]))
        let key: Int = LibraryFilterOptionsCache.key(revision: 1, trips: trips)

        let first: LibraryFilterOptionSet = LibraryFilterOptionsCache.options(for: items, key: key)
        let buildsAfterFirst: Int = LibraryFilterOptionsCache.buildCount
        let second: LibraryFilterOptionSet = LibraryFilterOptionsCache.options(for: items, key: key)

        XCTAssertEqual(first, second)
        XCTAssertEqual(LibraryFilterOptionsCache.buildCount, buildsAfterFirst, "A cache hit must not build again")
        XCTAssertFalse(first.places.isEmpty)
        XCTAssertEqual(first.trips.count, 5)
    }

    func testADifferentRevisionRebuilds() throws {
        let context = try makeContext()
        let items = try makeFixture(in: context)
        let trips = try context.fetch(FetchDescriptor<Trip>(sortBy: [SortDescriptor(\.id)]))
        let firstKey: Int = LibraryFilterOptionsCache.key(revision: 1, trips: trips)
        let secondKey: Int = LibraryFilterOptionsCache.key(revision: 2, trips: trips)
        XCTAssertNotEqual(firstKey, secondKey)

        _ = LibraryFilterOptionsCache.options(for: items, key: firstKey)
        let buildsAfterFirst: Int = LibraryFilterOptionsCache.buildCount
        _ = LibraryFilterOptionsCache.options(for: items, key: secondKey)

        XCTAssertEqual(LibraryFilterOptionsCache.buildCount, buildsAfterFirst + 1, "A new key must build once")
    }

    func testRenamingATripChangesTheKey() throws {
        let context = try makeContext()
        _ = try makeFixture(in: context)
        let trips = try context.fetch(FetchDescriptor<Trip>(sortBy: [SortDescriptor(\.id)]))
        let before: Int = LibraryFilterOptionsCache.key(revision: 7, trips: trips)

        guard let first = trips.first else {
            return XCTFail("The fixture must create trips")
        }
        first.overrideName = "Renamed trip"
        let after: Int = LibraryFilterOptionsCache.key(revision: 7, trips: trips)
        XCTAssertNotEqual(before, after, "A trip rename does not change store.revision, so the key must")

        first.overrideName = nil
        first.name = "Renamed on disk"
        let renamed: Int = LibraryFilterOptionsCache.key(revision: 7, trips: trips)
        XCTAssertNotEqual(before, renamed)
    }

    func testOptionsEqualTodaysChipOptions() throws {
        let context = try makeContext()
        let items = try makeFixture(in: context)
        let trips = try context.fetch(FetchDescriptor<Trip>(sortBy: [SortDescriptor(\.id)]))
        let key: Int = LibraryFilterOptionsCache.key(revision: 11, trips: trips)

        let cached: LibraryFilterOptionSet = LibraryFilterOptionsCache.options(for: items, key: key)
        let reference: LibraryFilterOptionSet = referenceOptions(for: items)

        XCTAssertEqual(cached, reference)
        let cachedIDs: [String] = cached.places.map { $0.id }
        let referenceIDs: [String] = reference.places.map { $0.id }
        XCTAssertEqual(cachedIDs, referenceIDs)
    }

    /// Two spellings of one name with the same count pick the same spelling
    /// in either order: the tie is broken by the spelling itself.
    func testEqualSpellingsPickTheSameNameInEitherOrder() throws {
        let context = try makeContext()
        let city = Place(id: "city-spellings", name: "Spelling City", kind: .city)
        context.insert(city)
        let first = MediaItem(id: "spelling-a", place: city)
        let second = MediaItem(id: "spelling-b", place: city)
        context.insert(first)
        context.insert(second)
        context.insert(PlaceOverride(mediaID: first.id, nameOverride: "Harbour", mediaItem: first))
        context.insert(PlaceOverride(mediaID: second.id, nameOverride: "harbour", mediaItem: second))
        try context.save()
        let trips = try context.fetch(FetchDescriptor<Trip>(sortBy: [SortDescriptor(\.id)]))

        let forward: LibraryFilterOptionSet = LibraryFilterOptionsCache.options(
            for: [first, second],
            key: LibraryFilterOptionsCache.key(revision: 31, trips: trips)
        )
        let backward: LibraryFilterOptionSet = LibraryFilterOptionsCache.options(
            for: [second, first],
            key: LibraryFilterOptionsCache.key(revision: 32, trips: trips)
        )
        XCTAssertEqual(forward.places.count, 1)
        let forwardNames: [String] = forward.places.map { $0.name }
        let backwardNames: [String] = backward.places.map { $0.name }
        XCTAssertEqual(forwardNames, backwardNames)
    }

    /// Photos of one trip that disagree about its name: one kept its id but
    /// lost the trip relationship, so it falls back to the id. Whichever photo
    /// comes first wins, so the result does depend on the order. That is why
    /// both callers hand the cache `store.items`, the same list in the same
    /// order; this test pins the disagreement that makes that necessary.
    func testATripWhosePhotosDisagreeAboutTheNameDependsOnTheOrder() throws {
        let context = try makeContext()
        let trip = Trip(id: "trip-disagreeing", name: "Named trip")
        context.insert(trip)
        let withTrip = MediaItem(id: "with-trip", tripID: trip.id, trip: trip)
        let withoutTrip = MediaItem(id: "without-trip", tripID: trip.id)
        context.insert(withTrip)
        context.insert(withoutTrip)
        try context.save()
        let trips = try context.fetch(FetchDescriptor<Trip>(sortBy: [SortDescriptor(\.id)]))

        let forward: LibraryFilterOptionSet = LibraryFilterOptionsCache.options(
            for: [withoutTrip, withTrip],
            key: LibraryFilterOptionsCache.key(revision: 41, trips: trips)
        )
        let backward: LibraryFilterOptionSet = LibraryFilterOptionsCache.options(
            for: [withTrip, withoutTrip],
            key: LibraryFilterOptionsCache.key(revision: 42, trips: trips)
        )
        XCTAssertEqual(forward.trips, ["trip-disagreeing"])
        XCTAssertEqual(backward.trips, ["trip-disagreeing"])
        XCTAssertNotEqual(
            forward.tripNames["trip-disagreeing"],
            backward.tripNames["trip-disagreeing"],
            "The order decides which photo's answer names the trip"
        )
    }

    /// The counted build and the item walk must list the same places: the
    /// counted one only reads the places' names, once per place.
    func testCountedPlaceOptionsEqualTheItemWalk() throws {
        let context = try makeContext()
        let items: [MediaItem] = try makeFixture(in: context)
        var overrideCounts: [String: Int] = [:]
        var placeCounts: [PersistentIdentifier: (place: Place, count: Int)] = [:]
        for item in items {
            let override: String? = item.placeOverrideName?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let override, !override.isEmpty {
                overrideCounts[override, default: 0] += 1
                continue
            }
            guard let place: Place = item.place else { continue }
            let id: PersistentIdentifier = place.persistentModelID
            let count: Int = (placeCounts[id]?.count ?? 0) + 1
            placeCounts[id] = (place: place, count: count)
        }

        let counted: [LibraryPlaceOption] = PlaceNames.options(
            overrideCounts: overrideCounts,
            placeCounts: placeCounts
        )
        let walked: [LibraryPlaceOption] = PlaceNames.options(for: items)

        XCTAssertEqual(counted, walked)
        let countedIDs: [String] = counted.map { $0.id }
        let walkedIDs: [String] = walked.map { $0.id }
        XCTAssertEqual(countedIDs, walkedIDs)
        XCTAssertFalse(walked.isEmpty)
    }

    /// A place rename moves `store.revision` but no photo changed: the new
    /// name is listed and the photos are not read again.
    func testPlaceRenameRebuildsOptionsWithoutReadingPhotos() throws {
        let context = try makeContext()
        let items: [MediaItem] = try makeFixture(in: context)

        let before: LibraryFilterOptionSet = LibraryFilterOptionsCache.options(for: items, key: 1, sourceKey: 10)
        let sourcesAfterFirstBuild: Int = LibraryFilterOptionsCache.sourceBuildCount
        let buildsAfterFirstBuild: Int = LibraryFilterOptionsCache.buildCount
        XCTAssertEqual(sourcesAfterFirstBuild, 1)

        // The items' own place objects: the cached sources hold the same ones.
        guard let renamedItem: MediaItem = items.first(where: { (item: MediaItem) -> Bool in
            item.place?.id == "spot-fixture-0"
        }), let spot: Place = renamedItem.place else {
            return XCTFail("The fixture must create spot-fixture-0")
        }
        spot.name = "Synthetic Renamed Spot"
        try context.save()

        let after: LibraryFilterOptionSet = LibraryFilterOptionsCache.options(for: items, key: 2, sourceKey: 10)
        let reference: LibraryFilterOptionSet = referenceOptions(for: items)

        XCTAssertEqual(LibraryFilterOptionsCache.sourceBuildCount, sourcesAfterFirstBuild, "A place-only save must not read the photos again")
        XCTAssertEqual(LibraryFilterOptionsCache.buildCount, buildsAfterFirstBuild + 1, "A new key must build the options once")
        XCTAssertEqual(after, reference)
        XCTAssertNotEqual(before, after, "The renamed place must be listed under its new name")
        let names: [String] = after.places.map { $0.name }
        XCTAssertTrue(names.contains("Synthetic Renamed Spot"))
    }

    /// A photo change (a new source key) must read the photos again.
    func testNewSourceKeyReadsThePhotosAgain() throws {
        let context = try makeContext()
        let items: [MediaItem] = try makeFixture(in: context)

        _ = LibraryFilterOptionsCache.options(for: items, key: 1, sourceKey: 10)
        XCTAssertEqual(LibraryFilterOptionsCache.sourceBuildCount, 1)
        _ = LibraryFilterOptionsCache.options(for: items, key: 2, sourceKey: 11)

        XCTAssertEqual(LibraryFilterOptionsCache.sourceBuildCount, 2)
        XCTAssertEqual(LibraryFilterOptionsCache.buildCount, 2)
    }
}
