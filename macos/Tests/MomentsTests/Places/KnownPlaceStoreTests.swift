import Foundation
import MomentsCore
import SwiftData
import XCTest
@testable import Moments

/// The places the person named, kept with the library's decisions, and the
/// trips sorted again when they change. All coordinates are synthetic.
@MainActor
final class KnownPlaceStoreTests: XCTestCase {
    private var container: ModelContainer?
    private var defaults: UserDefaults!
    private var suite = ""
    private let origin = Date(timeIntervalSince1970: 1_767_225_600)

    override func setUpWithError() throws {
        suite = "MomentsTests.KnownPlaces.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        container = nil
        super.tearDown()
    }

    /// Two months at home with four busy days somewhere else, found as one
    /// suggested trip.
    private func seed() throws -> ModelContext {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        self.container = container
        let context = container.mainContext
        let trip = Trip(id: "away", name: "Trip", suggestionStatusRaw: "suggestion")
        context.insert(trip)
        for day in 0..<60 where !(30..<34).contains(day) {
            context.insert(MediaItem(id: "home-\(day)", captureDate: origin.addingTimeInterval(Double(day) * 86_400 + 43_200), latitude: 10.0, longitude: 20.0, title: "home"))
        }
        for day in 30..<34 {
            for index in 0..<6 {
                context.insert(MediaItem(
                    id: "away-\(day)-\(index)",
                    captureDate: origin.addingTimeInterval(Double(day) * 86_400 + Double(9 + index) * 3_600),
                    latitude: 15.0,
                    longitude: 25.0,
                    title: "away",
                    tripID: trip.id,
                    trip: trip
                ))
            }
        }
        try context.save()
        return context
    }

    func testNamingAPlaceSortsUntouchedTripsAgain() throws {
        let context = try seed()
        let before = KnownPlaceStore.change(context: context, defaults: defaults) { book in
            book.add(KnownPlace(name: "Site", role: .work, centre: GeoPoint(latitude: 15.0, longitude: 25.0), addedAt: origin))
        }
        XCTAssertTrue(before.places.isEmpty)
        XCTAssertEqual(KnownPlaceStore.book(defaults: defaults).places.map(\.name), ["Site"])
        let items = try context.fetch(FetchDescriptor<MediaItem>())
        XCTAssertTrue(items.allSatisfy { $0.tripID == nil && $0.trip == nil }, "time at a named work site is daily life")
        XCTAssertTrue(try context.fetch(FetchDescriptor<Trip>()).isEmpty)
    }

    func testAnswersThatChangeNoPlaceLeaveTripsAlone() throws {
        let context = try seed()
        KnownPlaceStore.change(context: context, defaults: defaults) { book in
            book.markAsked([GeoPoint(latitude: 15.0, longitude: 25.0)])
            book.decline(GeoPoint(latitude: 40.0, longitude: 40.0))
        }
        XCTAssertEqual(try context.fetch(FetchDescriptor<Trip>()).map(\.id), ["away"])
        XCTAssertEqual(KnownPlaceStore.book(defaults: defaults).asked.count, 1)
    }

    func testRememberingWithoutAContextOnlySaves() throws {
        let context = try seed()
        KnownPlaceStore.change(context: nil, defaults: defaults) { book in
            book.rememberNotTrip(name: "Away", centre: GeoPoint(latitude: 15.0, longitude: 25.0), now: origin)
        }
        XCTAssertEqual(try context.fetch(FetchDescriptor<Trip>()).map(\.id), ["away"], "chapters already made stay")
        XCTAssertEqual(KnownPlaceStore.book(defaults: defaults).places.first?.role, .notTrip)
    }

    func testStayLengthCountsAsAChange() {
        var longer = KnownPlaceBook()
        longer.setLivedThereDays(60)
        XCTAssertTrue(KnownPlaceStore.findsTripsDifferently(KnownPlaceBook(), longer))
        var asked = KnownPlaceBook()
        asked.markAsked([GeoPoint(latitude: 1, longitude: 1)])
        XCTAssertFalse(KnownPlaceStore.findsTripsDifferently(KnownPlaceBook(), asked))
    }

    func testFoundPlacesAreNamedAfterTheirCity() async throws {
        let context = try seed()
        let city = Place(id: "city", name: "Synthetic Town", kind: .city, latitude: 10.0, longitude: 20.0)
        context.insert(city)
        for item in try context.fetch(FetchDescriptor<MediaItem>()) where item.id.hasPrefix("home") {
            item.place = city
        }
        try context.save()
        let found = await KnownPlaceStore.findPlaces(items: try context.fetch(FetchDescriptor<MediaItem>()), book: KnownPlaceBook())
        let home = try XCTUnwrap(found.first { $0.candidate.centre.distance(to: GeoPoint(latitude: 10.0, longitude: 20.0)) < 25_000 })
        XCTAssertEqual(home.name, "Synthetic Town")
        XCTAssertEqual(home.candidate.suggestedRole, .home)
    }
}
