import Foundation
import MomentsCore
import SwiftData
import XCTest
@testable import Moments

@MainActor
final class TripRegroupingTests: XCTestCase {
    private var container: ModelContainer?
    private let origin = Date(timeIntervalSince1970: 1_767_225_600)

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    override func tearDown() {
        container = nil
        super.tearDown()
    }

    private func makeContext() throws -> ModelContext {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        self.container = container
        return container.mainContext
    }

    @discardableResult
    private func photo(_ id: String, day: Int, hour: Double = 12, latitude: Double, longitude: Double, trip: Trip?, in context: ModelContext) -> MediaItem {
        let item = MediaItem(
            id: id,
            captureDate: origin.addingTimeInterval(Double(day) * 86_400 + hour * 3_600),
            latitude: latitude,
            longitude: longitude,
            title: id,
            tripID: trip?.id,
            trip: trip
        )
        context.insert(item)
        return item
    }

    /// Two months at home (synthetic coordinates) with a four-day trip in the
    /// middle, all in one suggested trip as the old import made it.
    private func seedOldImport(in context: ModelContext) -> Trip {
        let old = Trip(id: "old", name: "Trip January 2026", suggestionStatusRaw: "suggestion")
        context.insert(old)
        for day in 0..<60 where !(30..<34).contains(day) {
            photo("home-\(day)", day: day, latitude: 10.0, longitude: 20.0, trip: old, in: context)
        }
        for day in 30..<34 {
            for index in 0..<6 {
                photo("away-\(day)-\(index)", day: day, hour: 9 + Double(index), latitude: 15.0, longitude: 25.0, trip: old, in: context)
            }
        }
        return old
    }

    func testDailyLifeLeavesTheTripAndTheTripStays() throws {
        let context = try makeContext()
        seedOldImport(in: context)
        try context.save()

        let outcome = try TripRegrouping.regroup(context: context, locked: [], calendar: utc)

        let items = try context.fetch(FetchDescriptor<MediaItem>())
        let trips = try context.fetch(FetchDescriptor<Trip>())
        XCTAssertEqual(outcome.trips, 1)
        XCTAssertEqual(trips.count, 1)
        XCTAssertEqual(trips.first?.id, "old", "the old trip keeps most of the photos, so it carries on")
        XCTAssertTrue(items.filter { $0.id.hasPrefix("home") }.allSatisfy { $0.trip == nil && $0.tripID == nil })
        XCTAssertTrue(items.filter { $0.id.hasPrefix("away") }.allSatisfy { $0.tripID == "old" })
        XCTAssertEqual(trips.first?.startDate, origin.addingTimeInterval(30 * 86_400 + 9 * 3_600))
    }

    func testTripsShapedByHandAndLockedPhotosStay() throws {
        let context = try makeContext()
        seedOldImport(in: context)
        let renamed = Trip(id: "renamed", name: "Trip", overrideName: "Our weekend", suggestionStatusRaw: "suggestion")
        context.insert(renamed)
        photo("named-home", day: 70, latitude: 10.0, longitude: 20.0, trip: renamed, in: context)
        let locked = photo("locked-home", day: 71, latitude: 10.0, longitude: 20.0, trip: nil, in: context)
        let lockTrip = Trip(id: "lock-trip", name: "Trip", suggestionStatusRaw: "suggestion")
        context.insert(lockTrip)
        locked.trip = lockTrip
        locked.tripID = lockTrip.id
        try context.save()

        _ = try TripRegrouping.regroup(context: context, locked: ["locked-home"], calendar: utc)

        let items = try context.fetch(FetchDescriptor<MediaItem>())
        XCTAssertEqual(items.first { $0.id == "named-home" }?.tripID, "renamed")
        XCTAssertEqual(items.first { $0.id == "locked-home" }?.tripID, "lock-trip")
        XCTAssertEqual(Set(try context.fetch(FetchDescriptor<Trip>()).map(\.id)), ["old", "renamed", "lock-trip"])
    }

    func testPhotosTakenOutOfTripsAndEditedTripsStay() throws {
        let context = try makeContext()
        seedOldImport(in: context)
        // A trip deleted by hand leaves its photos in no trip, unlocked.
        for day in 70..<73 {
            for index in 0..<6 {
                photo("deleted-trip-\(day)-\(index)", day: day, hour: 9 + Double(index), latitude: 15.0, longitude: 25.0, trip: nil, in: context)
            }
        }
        let widened = Trip(id: "widened", name: "Trip", updatedBy: MomentsAccount.localID, suggestionStatusRaw: "suggestion")
        context.insert(widened)
        photo("widened-home", day: 75, latitude: 10.0, longitude: 20.0, trip: widened, in: context)
        try context.save()

        _ = try TripRegrouping.regroup(context: context, locked: [], calendar: utc)

        let items = try context.fetch(FetchDescriptor<MediaItem>())
        XCTAssertTrue(items.filter { $0.id.hasPrefix("deleted-trip") }.allSatisfy { $0.tripID == nil })
        XCTAssertEqual(items.first { $0.id == "widened-home" }?.tripID, "widened")
    }

    func testATripLeftWithOnlyDeletedPhotosGoesAway() throws {
        let context = try makeContext()
        seedOldImport(in: context)
        let stray = Trip(id: "stray", name: "Trip", suggestionStatusRaw: "suggestion")
        context.insert(stray)
        photo("stray-home", day: 61, latitude: 10.0, longitude: 20.0, trip: stray, in: context)
        photo("stray-deleted", day: 61, hour: 13, latitude: 10.0, longitude: 20.0, trip: stray, in: context).deletedAt = .now
        try context.save()

        _ = try TripRegrouping.regroup(context: context, locked: [], calendar: utc)

        XCTAssertFalse(try context.fetch(FetchDescriptor<Trip>()).contains { $0.id == "stray" })
        XCTAssertNil(try context.fetch(FetchDescriptor<MediaItem>()).first { $0.id == "stray-deleted" }?.tripID)
    }

    func testRunsOncePerRulesVersion() throws {
        let suite = "TripRegroupingTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let context = try makeContext()
        seedOldImport(in: context)
        try context.save()

        XCTAssertNotNil(try TripRegrouping.runOnce(context: context, defaults: defaults))
        XCTAssertNil(try TripRegrouping.runOnce(context: context, defaults: defaults))
    }

    func testRunsAgainWhenTheRulesChange() throws {
        let suite = "TripRegroupingTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let context = try makeContext()
        seedOldImport(in: context)
        try context.save()
        // A library grouped by the rules before the last rule change.
        defaults.set(2, forKey: TripRegrouping.versionKey)

        XCTAssertNotNil(try TripRegrouping.runOnce(context: context, defaults: defaults))
        XCTAssertEqual(defaults.integer(forKey: TripRegrouping.versionKey), TripSegmenter.rulesVersion)
        XCTAssertNil(try TripRegrouping.runOnce(context: context, defaults: defaults))
    }

    func testEmptyTripsGoAwayWhateverTheirStatus() throws {
        let context = try makeContext()
        seedOldImport(in: context)
        let suggested = Trip(id: "empty-suggested", name: "", suggestionStatusRaw: "suggestion")
        context.insert(suggested)
        let blank = Trip(id: "empty-blank", name: "", suggestionStatusRaw: "")
        context.insert(blank)
        let named = Trip(id: "empty-named", name: "", overrideName: "Kept", suggestionStatusRaw: "")
        context.insert(named)
        try context.save()

        let outcome = try TripRegrouping.regroup(context: context, locked: [], calendar: utc)

        let trips: [Trip] = try context.fetch(FetchDescriptor<Trip>())
        let ids: Set<String> = Set(trips.map { (trip: Trip) -> String in trip.id })
        XCTAssertFalse(ids.contains("empty-suggested"), "a suggested trip with no photos goes away")
        XCTAssertFalse(ids.contains("empty-blank"), "a trip with no photos goes away even when its status is empty")
        XCTAssertTrue(ids.contains("empty-named"), "a trip named by hand stays")
        XCTAssertEqual(outcome.removed, 2)
    }

    func testEmptyTripsGoAwayWhenNothingElseMoves() throws {
        let context = try makeContext()
        let empty = Trip(id: "empty-only", name: "", suggestionStatusRaw: "suggestion")
        context.insert(empty)
        try context.save()

        let outcome = try TripRegrouping.regroup(context: context, locked: [], calendar: utc)

        let trips: [Trip] = try context.fetch(FetchDescriptor<Trip>())
        XCTAssertTrue(trips.isEmpty, "nothing moves, yet the trip with no photos goes away")
        XCTAssertEqual(outcome.removed, 1)
    }

    func testHandMadeEmptyTripStays() throws {
        let context = try makeContext()
        seedOldImport(in: context)
        // What `TripEdits.create` makes without a typed name: a name taken
        // from the places, `updatedBy` set, status nil, no override name and
        // no photos.
        let handmade = Trip(
            id: "hand-made",
            name: "Trip January 2026",
            updatedAt: .now,
            updatedBy: MomentsAccount.localID
        )
        context.insert(handmade)
        try context.save()

        _ = try TripRegrouping.regroup(context: context, locked: [], calendar: utc)

        let trips: [Trip] = try context.fetch(FetchDescriptor<Trip>())
        let ids: Set<String> = Set(trips.map { (trip: Trip) -> String in trip.id })
        XCTAssertTrue(ids.contains("hand-made"), "a trip made by hand stays even when it has no photos")
        XCTAssertTrue(ids.contains("old"), "the old import trip still keeps its photos")
    }

    func testConfirmedTripKeepsItsRecentlyDeletedPhoto() throws {
        let context = try makeContext()
        seedOldImport(in: context)
        let confirmed = Trip(id: "confirmed", name: "Trip", suggestionStatusRaw: "confirmed")
        context.insert(confirmed)
        let deleted = photo("confirmed-deleted", day: 65, latitude: 10.0, longitude: 20.0, trip: confirmed, in: context)
        deleted.deletedAt = .now
        try context.save()

        _ = try TripRegrouping.regroup(context: context, locked: [], calendar: utc)

        let trips: [Trip] = try context.fetch(FetchDescriptor<Trip>())
        let tripIDs: Set<String> = Set(trips.map { (trip: Trip) -> String in trip.id })
        XCTAssertTrue(tripIDs.contains("confirmed"), "a confirmed trip stays even when only Recently Deleted photos are left")
        let items: [MediaItem] = try context.fetch(FetchDescriptor<MediaItem>())
        let recovered: MediaItem? = items.first { (item: MediaItem) -> Bool in item.id == "confirmed-deleted" }
        XCTAssertEqual(recovered?.tripID, "confirmed", "the Recently Deleted photo keeps its trip, so Recover puts it back")
        XCTAssertEqual(recovered?.trip?.id, "confirmed")
    }

    func testEmptyTripWithAMemoryOrCoverStays() throws {
        let context = try makeContext()
        let cover = Trip(id: "cover", name: "", suggestionStatusRaw: "suggestion")
        context.insert(cover)
        let memoryTrip = Trip(id: "memory-trip", name: "", suggestionStatusRaw: "suggestion")
        context.insert(memoryTrip)
        let memory = CollectionMemory(scope: .trip, scopeKey: "memory-trip", text: "Synthetic trip memory")
        context.insert(memory)
        try context.save()

        _ = try TripRegrouping.regroup(context: context, locked: [], covered: ["cover"], calendar: utc)

        let trips: [Trip] = try context.fetch(FetchDescriptor<Trip>())
        let ids: Set<String> = Set(trips.map { (trip: Trip) -> String in trip.id })
        XCTAssertTrue(ids.contains("cover"), "a trip given a cover stays even when it is empty")
        XCTAssertTrue(ids.contains("memory-trip"), "a trip with a memory stays even when it is empty")
    }
}
