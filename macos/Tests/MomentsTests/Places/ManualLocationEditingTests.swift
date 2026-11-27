import Foundation
import MomentsCore
import SwiftData
import XCTest
@testable import Moments

/// Set Location on the app's models: where the coordinate is kept, which
/// place the photo joins, what the map reads, and that Clear and Undo put
/// everything back. Synthetic photos near 0,0 in an in-memory store.
@MainActor
final class ManualLocationEditingTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    /// Held for the whole test: a ModelContext whose container is released crashes.
    private var container: ModelContainer?

    private func makeContext() throws -> ModelContext {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        self.container = container
        return container.mainContext
    }

    override func tearDown() {
        container = nil
        super.tearDown()
    }

    private func places(_ context: ModelContext) throws -> [Place] {
        try context.fetch(FetchDescriptor<Place>())
    }

    func testSettingKeepsTheCameraCoordinateAndMakesUnnamedPlaces() throws {
        let context = try makeContext()
        let item = MediaItem(id: "a", captureDate: base)
        context.insert(item)
        try context.save()

        let point = GeoPoint(latitude: 0.3, longitude: 0.3)
        let undo = ManualLocationEditing.setLocation(point, name: "Synthetic Harbour", on: [item], context: context, now: base)
        XCTAssertNotNil(undo)
        XCTAssertNil(item.latitude, "The camera's coordinate field was written")
        XCTAssertEqual(item.localPlaceOverride?.latitude, 0.3)
        XCTAssertEqual(item.localPlaceOverride?.longitude, 0.3)
        XCTAssertEqual(item.manualLocation?.point, point)
        XCTAssertEqual(item.mapLocation, point)
        XCTAssertEqual(item.namedPlace, "Synthetic Harbour")
        // A new city, area and spot, unnamed for the name backfill.
        XCTAssertEqual(item.place?.kind, .spot)
        XCTAssertEqual(item.place?.parent?.kind, .area)
        XCTAssertEqual(item.place?.parent?.parent?.kind, .city)
        XCTAssertEqual(item.place?.parent?.parent?.name, "")
        XCTAssertEqual(try places(context).count, 3)
        XCTAssertEqual(ManualLocationIndex.coordinates(in: context), ["a": point])

        undo?.perform(in: context)
        XCTAssertNil(item.localPlaceOverride)
        XCTAssertNil(item.place)
        XCTAssertNil(item.manualLocation)
        XCTAssertTrue(try places(context).isEmpty, "Undo left the places it made")
        XCTAssertTrue(ManualLocationIndex.coordinates(in: context).isEmpty)
    }

    func testANearbySpotIsSharedAndATypedNameStays() throws {
        let context = try makeContext()
        let spot = Place(id: "spot", name: "Demo spot", kind: .spot, latitude: 0.001, longitude: 0.001)
        context.insert(spot)
        let item = MediaItem(id: "a", captureDate: base)
        context.insert(item)
        PhotoInfoEditing.setPlaceName("My own name", on: item, context: context, now: base)
        try context.save()

        let undo = ManualLocationEditing.setLocation(GeoPoint(latitude: 0, longitude: 0), name: "Searched", on: [item], context: context, now: base)
        XCTAssertEqual(item.place?.id, "spot")
        XCTAssertEqual(item.namedPlace, "My own name", "A searched name replaced the one typed by hand")
        XCTAssertEqual(try places(context).count, 1)

        undo?.perform(in: context)
        XCTAssertNil(item.place)
        XCTAssertEqual(item.namedPlace, "My own name")
        XCTAssertNil(item.localPlaceOverride?.latitude)
        XCTAssertEqual(try places(context).count, 1, "Undo removed a place it did not make")
    }

    func testClearingGoesBackToTheCameraLocationAndUndoReturns() throws {
        let context = try makeContext()
        let cameraSpot = Place(id: "camera-spot", name: "", kind: .spot, latitude: 0.01, longitude: 0.01)
        context.insert(cameraSpot)
        let item = MediaItem(id: "a", captureDate: base, latitude: 0.01, longitude: 0.01, place: cameraSpot)
        context.insert(item)
        try context.save()

        let moved = GeoPoint(latitude: 0.5, longitude: 0.5)
        ManualLocationEditing.setLocation(moved, name: nil, on: [item], context: context, now: base)
        XCTAssertEqual(item.mapLocation, moved)
        XCTAssertNotEqual(item.place?.id, "camera-spot")

        let undo = ManualLocationEditing.clearLocation(on: [item], context: context, now: base.addingTimeInterval(60))
        XCTAssertNotNil(undo)
        XCTAssertNil(item.manualLocation)
        XCTAssertEqual(item.mapLocation, GeoPoint(latitude: 0.01, longitude: 0.01))
        XCTAssertEqual(item.place?.id, "camera-spot", "Use Camera Location did not go back to the camera's place")
        XCTAssertEqual(try places(context).map(\.id), ["camera-spot"], "The places made for the hand-set location stayed behind, empty")

        undo?.perform(in: context)
        XCTAssertEqual(item.mapLocation, moved)
        XCTAssertEqual(item.place?.id.hasPrefix(ManualLocationEditing.placeIDPrefix), true)
        XCTAssertEqual(item.place?.parent?.parent?.kind, .city, "Undo did not bring the place's parents back")
        XCTAssertEqual(try places(context).count, 4)
    }

    func testClearingWithoutHandSetLocationDoesNothing() throws {
        let context = try makeContext()
        let item = MediaItem(id: "a", captureDate: base, latitude: 0.01, longitude: 0.01)
        context.insert(item)
        XCTAssertNil(ManualLocationEditing.clearLocation(on: [item], context: context))
    }

    func testABatchSharesOnePlaceAndUndoesTogether() throws {
        let context = try makeContext()
        let items = (0..<3).map { MediaItem(id: "p\($0)", captureDate: base.addingTimeInterval(Double($0) * 60)) }
        for item in items { context.insert(item) }
        try context.save()

        let undo = ManualLocationEditing.setLocation(GeoPoint(latitude: 0.2, longitude: 0.2), name: nil, on: items, context: context, now: base)
        XCTAssertEqual(Set(items.compactMap { $0.place?.id }).count, 1)
        XCTAssertEqual(ManualLocationIndex.coordinates(in: context).count, 3)
        XCTAssertEqual(undo?.message, String(localized: "Location set for \(3) photos"))

        undo?.perform(in: context)
        XCTAssertTrue(items.allSatisfy { $0.place == nil && $0.localPlaceOverride == nil })
        XCTAssertTrue(try places(context).isEmpty)
    }

    func testTheNewestHandSetLocationWinsAcrossAccounts() throws {
        let context = try makeContext()
        let item = MediaItem(id: "a", captureDate: base)
        context.insert(item)
        context.insert(PlaceOverride(mediaID: "a", accountID: MomentsAccount.localID, latitude: 0.1, longitude: 0.1, updatedAt: base, mediaItem: item))
        context.insert(PlaceOverride(mediaID: "a", accountID: "partner", latitude: 0.2, longitude: 0.2, updatedAt: base.addingTimeInterval(5), mediaItem: item))
        try context.save()
        XCTAssertEqual(item.manualLocation?.point, GeoPoint(latitude: 0.2, longitude: 0.2))
        XCTAssertEqual(ManualLocationIndex.coordinates(in: context)["a"], GeoPoint(latitude: 0.2, longitude: 0.2))
    }

    func testMapStopsAndFootprintsUseTheHandSetLocation() throws {
        let context = try makeContext()
        let unlocated = MediaItem(id: "a", captureDate: base)
        let located = MediaItem(id: "b", captureDate: base, latitude: 0.01, longitude: 0.01)
        context.insert(unlocated)
        context.insert(located)
        try context.save()
        let manual = ["a": GeoPoint(latitude: 0.3, longitude: 0.3)]

        let stops = PlacesViewModel().photoStops(from: [unlocated, located], visibleItemIDs: nil, manualCoordinates: manual)
        XCTAssertEqual(stops.first { $0.id == "a" }?.coordinate, GeoPoint(latitude: 0.3, longitude: 0.3))
        XCTAssertEqual(stops.first { $0.id == "b" }?.coordinate, GeoPoint(latitude: 0.01, longitude: 0.01))
        XCTAssertNil(PlacesViewModel().photoStops(from: [unlocated], visibleItemIDs: nil).first?.coordinate)

        let input = FootprintsCalculator.input(from: [unlocated, located], visibleItemIDs: nil, manualCoordinates: manual)
        XCTAssertEqual(Set(input.stops.map(\.id)), ["a", "b"])
    }

    func testChangingAgainRemovesThePlaceLeftEmpty() throws {
        let context = try makeContext()
        let item = MediaItem(id: "a", captureDate: base)
        context.insert(item)
        try context.save()
        ManualLocationEditing.setLocation(GeoPoint(latitude: 0.3, longitude: 0.3), name: nil, on: [item], context: context, now: base)
        let first = try XCTUnwrap(item.place?.id)
        // Far away: a new city, and the first one is left with nothing.
        let undo = ManualLocationEditing.setLocation(GeoPoint(latitude: -0.4, longitude: -0.4), name: nil, on: [item], context: context, now: base)
        XCTAssertEqual(try places(context).count, 3)
        undo?.perform(in: context)
        XCTAssertEqual(item.place?.id, first)
        XCTAssertEqual(try places(context).count, 3)
    }

    func testIntervalText() {
        XCTAssertNotEqual(ManualLocationSheet.intervalText(-600), ManualLocationSheet.intervalText(600))
        // Under a minute reads as a minute.
        XCTAssertEqual(ManualLocationSheet.intervalText(20), ManualLocationSheet.intervalText(60))
    }
}
