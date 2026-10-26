import Foundation
import MomentsCore
import SwiftData
import XCTest
@testable import Moments

final class TimelineGroupingTests: XCTestCase {
    @MainActor
    func testSyntheticDemoBuildsOrderedTripsAndKeepsUndatedItems() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        try DemoSeeder.seedIfNeeded(
            context: context,
            data: Data(contentsOf: root.appendingPathComponent("demo/sample-data.json"))
        )

        let items = try context.fetch(FetchDescriptor<MediaItem>())
        let trips = try context.fetch(FetchDescriptor<Trip>())
        let document = TimelineBuilder(calendar: testCalendar(timeZone: "UTC")).build(
            items: items.map { TimelineItemSnapshot(item: $0) },
            trips: trips.map { TimelineSourceTrip(id: $0.id, name: $0.name, itemIDs: $0.items.map { $0.id }) }
        )

        XCTAssertEqual(document.trips.map { $0.id }, ["journeyA", "journeyB"])
        XCTAssertEqual(document.trips.map { $0.itemCount }, [14, 13])
        XCTAssertNil(document.trips[0].days.last?.date)
        let events = document.trips.flatMap { $0.days }.flatMap { $0.events }
        XCTAssertEqual(events.filter {
            if case .travel = $0 { return true }
            return false
        }.count, 0)
    }

    func testGroupsTripsDaysAndPlacesWithEmptyTrips() {
        let calendar = testCalendar(timeZone: "UTC")
        let items = [
            snapshot("a-1", date: date("2025-01-01T23:30:00Z"), latitude: 0, longitude: 0, tripID: "trip-a", place: "Arrival"),
            snapshot("a-2", date: date("2025-01-02T09:00:00Z"), latitude: 0, longitude: 0.02, tripID: "trip-a", place: "Museum"),
            snapshot("b-1", date: date("2025-02-01T09:00:00Z"), latitude: 1, longitude: 1, tripID: "trip-b", place: "Home")
        ]
        let trips = [
            TimelineSourceTrip(id: "trip-a", name: "A", itemIDs: ["a-1", "a-2"]),
            TimelineSourceTrip(id: "trip-b", name: "B", itemIDs: ["b-1"]),
            TimelineSourceTrip(id: "empty", name: "Empty trip")
        ]

        let document = TimelineBuilder(
            clusterer: PlaceClusterer(spotRadiusMeters: 100, cityRadiusMeters: 100),
            calendar: calendar
        ).build(items: items, trips: trips)

        XCTAssertEqual(document.trips.map(\.id), ["trip-a", "trip-b", "empty"])
        XCTAssertEqual(document.trips[0].days.count, 2)
        XCTAssertEqual(document.trips[0].days.flatMap { day in
            day.events.compactMap { event in
                if case let .place(place) = event { return place.itemIDs }
                return nil
            }
        }.flatMap { $0 }, ["a-1", "a-2"])
        XCTAssertTrue(document.trips[2].days.isEmpty)
    }

    func testDayBoundariesUseTheBuilderCalendarTimeZone() {
        let items = [
            snapshot("before-midnight", date: date("2025-01-01T23:30:00Z"), tripID: "trip"),
            snapshot("after-midnight", date: date("2025-01-02T00:30:00Z"), tripID: "trip")
        ]
        let trip = TimelineSourceTrip(id: "trip", name: "Boundary", itemIDs: ["before-midnight", "after-midnight"])

        let utc = TimelineBuilder(calendar: testCalendar(timeZone: "UTC")).build(items: items, trips: [trip])
        let losAngeles = TimelineBuilder(calendar: testCalendar(timeZone: "America/Los_Angeles")).build(items: items, trips: [trip])

        XCTAssertEqual(utc.trips[0].days.count, 2)
        XCTAssertEqual(losAngeles.trips[0].days.count, 1)
        XCTAssertEqual(losAngeles.trips[0].days[0].events.count, 1)
    }

    func testCreatesTravelRowFromCityOverviewBeforeDestinationPlace() {
        let items = [
            snapshot("from", date: date("2025-03-01T09:00:00Z"), latitude: 0, longitude: 0, tripID: "trip", place: "Alpha"),
            snapshot("to", date: date("2025-03-01T12:00:00Z"), latitude: 0, longitude: 10, tripID: "trip", place: "Beta")
        ]
        let trip = TimelineSourceTrip(id: "trip", name: "Route", itemIDs: ["from", "to"])

        let document = TimelineBuilder(
            clusterer: PlaceClusterer(spotRadiusMeters: 1_000, cityRadiusMeters: 100_000),
            calendar: testCalendar(timeZone: "UTC")
        ).build(items: items, trips: [trip])

        let events = document.trips[0].days[0].events
        XCTAssertEqual(events.count, 3)
        guard case let .travel(travel) = events[1] else {
            return XCTFail("Expected a travel event between the two place nodes")
        }
        XCTAssertEqual(travel.fromName, "Alpha")
        XCTAssertEqual(travel.toName, "Beta")
        XCTAssertEqual(travel.fromStopID, "from")
        XCTAssertEqual(travel.toStopID, "to")
        XCTAssertEqual(travel.distanceMeters / 1_000, 1_111, accuracy: 3)
    }

    func testTripCardSummaryAndDayMemoryKeys() {
        let items = [
            TimelineItemSnapshot(id: "v", date: date("2025-03-01T08:00:00Z"), latitude: 0, longitude: 0, kindRaw: MediaKind.video.rawValue, tripID: "trip", placeHint: "Alpha"),
            TimelineItemSnapshot(id: "p1", date: date("2025-03-01T09:00:00Z"), latitude: 0, longitude: 0, tripID: "trip", placeHint: "Alpha", dayKey: "2025-03-01"),
            TimelineItemSnapshot(id: "p2", date: date("2025-03-02T10:00:00Z"), latitude: 0, longitude: 10, tripID: "trip", placeHint: "Beta"),
            TimelineItemSnapshot(id: "p3", date: date("2025-03-03T10:00:00Z"), latitude: 0, longitude: 0, tripID: "trip", placeHint: "Alpha"),
            TimelineItemSnapshot(id: "loose", date: date("2025-04-01T10:00:00Z")),
            TimelineItemSnapshot(id: "ghost", date: date("2025-04-02T10:00:00Z"), tripID: "deleted-trip")
        ]
        let trip = TimelineSourceTrip(id: "trip", name: "Route", itemIDs: ["v", "p1", "p2", "p3"])

        let document = TimelineBuilder(
            clusterer: PlaceClusterer(spotRadiusMeters: 1_000, cityRadiusMeters: 100_000),
            calendar: testCalendar(timeZone: "UTC")
        ).build(items: items, trips: [trip])

        let built = document.trips[0]
        XCTAssertEqual(built.orderedItems.map(\.id), ["v", "p1", "p2", "p3"])
        XCTAssertEqual(built.cover?.id, "p1", "A video is not the cover while there is a photo")
        XCTAssertEqual(built.datedDayCount, 3)
        XCTAssertEqual(built.placeCount, 2, "A place visited twice counts once")
        XCTAssertEqual(built.cityNames, ["Alpha", "Beta"])
        XCTAssertEqual(built.endDate, date("2025-03-03T10:00:00Z"))
        XCTAssertFalse(built.isUnsorted)
        // The photo's own day key wins; otherwise the builder's calendar day.
        XCTAssertEqual(built.days.map(\.memoryKey), ["2025-03-01", "2025-03-02", "2025-03-03"])

        XCTAssertEqual(document.trips.last?.id, TimelineBuilder.unassignedTripID)
        XCTAssertTrue(document.trips.last?.isUnsorted ?? false)
        XCTAssertEqual(document.trips.count, 2, "A photo whose trip is gone joins the photos in no trip")
        XCTAssertEqual(document.trips.last?.orderedItems.map(\.id), ["loose", "ghost"])
    }

    func testDayMemoryKeyFollowsThePhotosLocalDay() {
        // Taken late on the 1st in local time, which is already the 2nd in UTC.
        let item = TimelineItemSnapshot(id: "late", date: date("2025-03-02T01:00:00Z"), tripID: "trip", dayKey: "2025-03-01")
        let document = TimelineBuilder(calendar: testCalendar(timeZone: "UTC"))
            .build(items: [item], trips: [TimelineSourceTrip(id: "trip", name: "T", itemIDs: ["late"])])
        XCTAssertEqual(document.trips[0].days[0].memoryKey, "2025-03-01")
        XCTAssertEqual(document.trips[0].days[0].date, date("2025-03-01T00:00:00Z"), "The header shows the local day")
    }

    private func snapshot(
        _ id: String,
        date: Date?,
        latitude: Double? = nil,
        longitude: Double? = nil,
        tripID: String? = nil,
        place: String? = nil
    ) -> TimelineItemSnapshot {
        TimelineItemSnapshot(
            id: id,
            date: date,
            latitude: latitude,
            longitude: longitude,
            tripID: tripID,
            placeHint: place
        )
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func testCalendar(timeZone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }
}
