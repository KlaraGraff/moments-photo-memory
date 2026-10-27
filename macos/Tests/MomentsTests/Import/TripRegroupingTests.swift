import Foundation
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

    func testRunsOncePerMac() throws {
        let suite = "TripRegroupingTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let context = try makeContext()
        seedOldImport(in: context)
        try context.save()
        let container = try XCTUnwrap(self.container)

        XCTAssertNotNil(try TripRegrouping.runOnce(container: container, defaults: defaults))
        XCTAssertNil(try TripRegrouping.runOnce(container: container, defaults: defaults))
    }
}
