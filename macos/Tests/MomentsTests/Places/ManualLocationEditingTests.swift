import Foundation
import MapKit
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

    func testMovingWithinTheSameAreaKeepsItsParents() throws {
        let context = try makeContext()
        let item = MediaItem(id: "a", captureDate: base)
        context.insert(item)
        try context.save()
        ManualLocationEditing.setLocation(GeoPoint(latitude: 0.3, longitude: 0.3), name: nil, on: [item], context: context, now: base)
        let first = try XCTUnwrap(item.place)
        let area = try XCTUnwrap(first.parent?.id)
        let city = try XCTUnwrap(first.parent?.parent?.id)

        // About 3 km away: past the spot radius, inside the same area.
        let undo = ManualLocationEditing.setLocation(GeoPoint(latitude: 0.327, longitude: 0.3), name: nil, on: [item], context: context, now: base)
        XCTAssertNotEqual(item.place?.id, first.id)
        XCTAssertEqual(item.place?.parent?.id, area, "The new spot lost its area")
        XCTAssertEqual(item.place?.parent?.parent?.id, city, "The new spot lost its city")
        let spot = try XCTUnwrap(item.place?.id)
        XCTAssertEqual(Set(try places(context).map(\.id)), [area, city, spot])

        undo?.perform(in: context)
        XCTAssertEqual(item.place?.parent?.id, area)
        XCTAssertEqual(try places(context).count, 3)
    }

    func testMovingWithinTheSameCityKeepsTheCity() throws {
        let context = try makeContext()
        let item = MediaItem(id: "a", captureDate: base)
        context.insert(item)
        try context.save()
        ManualLocationEditing.setLocation(GeoPoint(latitude: 0.3, longitude: 0.3), name: nil, on: [item], context: context, now: base)
        let city = try XCTUnwrap(item.place?.parent?.parent?.id)
        let firstArea = try XCTUnwrap(item.place?.parent?.id)

        // About 11 km away: past the area radius, inside the same city.
        ManualLocationEditing.setLocation(GeoPoint(latitude: 0.4, longitude: 0.3), name: nil, on: [item], context: context, now: base)
        XCTAssertEqual(item.place?.parent?.parent?.id, city, "The new area lost its city")
        XCTAssertNotEqual(item.place?.parent?.id, firstArea)
        XCTAssertEqual(try places(context).count, 3, "The emptied area stayed, or the city went")
    }

    func testANewSearchedNameFollowsTheNewPlace() throws {
        let context = try makeContext()
        let item = MediaItem(id: "a", captureDate: base)
        context.insert(item)
        try context.save()
        ManualLocationEditing.setLocation(GeoPoint(latitude: 0.3, longitude: 0.3), name: "Synthetic Harbour", on: [item], context: context, now: base)
        XCTAssertEqual(item.namedPlace, "Synthetic Harbour")
        XCTAssertNil(item.placeOverrideName, "A searched name went into the photo's own name")

        ManualLocationEditing.setLocation(GeoPoint(latitude: -0.4, longitude: -0.4), name: "Synthetic Market", on: [item], context: context, now: base)
        XCTAssertEqual(item.namedPlace, "Synthetic Market", "The first searched name stayed after a move")
    }

    func testASearchNamesAnUnnamedSpotMadeForAPinAndUndoTakesItBack() throws {
        let context = try makeContext()
        let item = MediaItem(id: "a", captureDate: base)
        context.insert(item)
        try context.save()
        // A pin dropped by hand: a spot with no name.
        ManualLocationEditing.setLocation(GeoPoint(latitude: 0.3, longitude: 0.3), name: nil, on: [item], context: context, now: base)
        let spot = try XCTUnwrap(item.place)
        XCTAssertEqual(spot.name, "")

        // A search a few hundred metres away joins that spot and names it.
        let undo = ManualLocationEditing.setLocation(GeoPoint(latitude: 0.302, longitude: 0.3), name: "Synthetic Harbour", on: [item], context: context, now: base)
        XCTAssertEqual(item.place?.id, spot.id)
        XCTAssertEqual(item.namedPlace, "Synthetic Harbour")

        undo?.perform(in: context)
        XCTAssertEqual(spot.name, "", "Undo left the searched name on the spot")
        XCTAssertEqual(item.manualLocation?.point, GeoPoint(latitude: 0.3, longitude: 0.3))
    }

    func testClearingKeepsAMapLink() throws {
        let context = try makeContext()
        let item = MediaItem(id: "a", captureDate: base)
        context.insert(item)
        context.insert(PlaceOverride(mediaID: "a", mapLinkOverride: "https://example.com/synthetic", updatedAt: base, mediaItem: item))
        try context.save()
        ManualLocationEditing.setLocation(GeoPoint(latitude: 0.3, longitude: 0.3), name: nil, on: [item], context: context, now: base)

        ManualLocationEditing.clearLocation(on: [item], context: context, now: base)
        XCTAssertNil(item.manualLocation)
        XCTAssertEqual(item.placeOverrideMapLink, "https://example.com/synthetic", "Clear Location removed the photo's map link")
    }

    func testFetchingManyIDsReadsThemAll() throws {
        let context = try makeContext()
        for index in 0..<900 { context.insert(MediaItem(id: "p\(index)", captureDate: base)) }
        try context.save()
        let ids = (0..<900).map { "p\($0)" }
        XCTAssertEqual(ManualLocationEditing.items(withIDs: ids, context: context).count, 900)
    }

    func testClearingKeepsANameTypedByHand() throws {
        let context = try makeContext()
        let item = MediaItem(id: "a", captureDate: base)
        context.insert(item)
        PhotoInfoEditing.setPlaceName("My own name", on: item, context: context, now: base)
        try context.save()
        ManualLocationEditing.setLocation(GeoPoint(latitude: 0.3, longitude: 0.3), name: nil, on: [item], context: context, now: base)

        ManualLocationEditing.clearLocation(on: [item], context: context, now: base)
        XCTAssertNil(item.manualLocation)
        XCTAssertEqual(item.placeOverrideName, "My own name", "Clear Location removed a name typed by hand")
    }

    func testARenamedPlaceIsNotRemoved() throws {
        let context = try makeContext()
        let item = MediaItem(id: "a", captureDate: base)
        context.insert(item)
        try context.save()
        ManualLocationEditing.setLocation(GeoPoint(latitude: 0.3, longitude: 0.3), name: nil, on: [item], context: context, now: base)
        let city = try XCTUnwrap(item.place?.parent?.parent)
        context.insert(PlaceOverride(placeID: city.id, nameOverride: "Renamed", place: city))
        try context.save()

        ManualLocationEditing.setLocation(GeoPoint(latitude: -0.4, longitude: -0.4), name: nil, on: [item], context: context, now: base)
        XCTAssertTrue(try places(context).contains { $0.id == city.id }, "A city renamed in Places was removed")
    }

    func testClearingGoesToThePartnersLocation() throws {
        let context = try makeContext()
        let item = MediaItem(id: "a", captureDate: base)
        context.insert(item)
        context.insert(PlaceOverride(mediaID: "a", accountID: "partner", latitude: 0.2, longitude: 0.2, updatedAt: base, mediaItem: item))
        try context.save()
        ManualLocationEditing.setLocation(GeoPoint(latitude: 0.6, longitude: 0.6), name: nil, on: [item], context: context, now: base.addingTimeInterval(60))
        XCTAssertEqual(item.manualLocation?.point, GeoPoint(latitude: 0.6, longitude: 0.6))

        ManualLocationEditing.clearLocation(on: [item], context: context, now: base.addingTimeInterval(120))
        XCTAssertEqual(item.manualLocation?.point, GeoPoint(latitude: 0.2, longitude: 0.2))
        XCTAssertEqual(item.place?.latitude, 0.2, "The photo's place does not follow the location it now shows")
    }

    func testTheBackfillNamesAnAreaMadeUnderANamedCity() async throws {
        let context = try makeContext()
        let city = Place(id: "city", name: "Synthetic City", kind: .city, latitude: 0.3, longitude: 0.3)
        context.insert(city)
        let item = MediaItem(id: "a", captureDate: base)
        context.insert(item)
        try context.save()
        // About 11 km from the city's centre: a new area under it.
        ManualLocationEditing.setLocation(GeoPoint(latitude: 0.4, longitude: 0.3), name: nil, on: [item], context: context, now: base)
        let area = try XCTUnwrap(item.place?.parent)
        XCTAssertEqual(area.parent?.id, "city")
        XCTAssertEqual(area.name, "")

        let container = try XCTUnwrap(self.container)
        let backfill = PlaceNameBackfill(geocoder: SyntheticAreaGeocoder(), geocodeCache: ImportGeocodeCache(), pace: {})
        _ = try await backfill.run(container: container)
        XCTAssertFalse(try PlaceNameBackfill.hasUnnamedManualAreas(in: container))
        let fresh = ModelContext(container)
        let areaID = area.id
        let named = try fresh.fetch(FetchDescriptor<Place>(predicate: #Predicate { $0.id == areaID })).first
        XCTAssertEqual(named?.name, "Synthetic Area")
        let cityName = try fresh.fetch(FetchDescriptor<Place>(predicate: #Predicate { $0.id == "city" })).first?.name
        XCTAssertEqual(cityName, "Synthetic City", "The backfill renamed a city that had its name")
    }

    func testFitShowsALonePhotoAwayFromTheRest() {
        // Many photos together near 0,0 and one about 4 km off, as a photo
        // placed by hand often is: Fit must show that one too.
        var stops = (0..<25).map { index in
            PhotoStop(id: "p\(index)", date: base, coordinate: GeoPoint(latitude: Double(index % 5) * 0.002, longitude: Double(index / 5) * 0.002))
        }
        stops.append(PhotoStop(id: "lone", date: base, coordinate: GeoPoint(latitude: 0.03, longitude: 0.03)))
        let region = PlacesViewModel().initialRegion(for: stops)
        for stop in stops {
            guard let point = stop.coordinate else { continue }
            XCTAssertLessThan(abs(point.latitude - region.center.latitude), region.span.latitudeDelta / 2, "\(stop.id) is outside the region")
            XCTAssertLessThan(abs(point.longitude - region.center.longitude), region.span.longitudeDelta / 2, "\(stop.id) is outside the region")
        }
    }

    func testIntervalText() {
        XCTAssertNotEqual(ManualLocationSheet.intervalText(-600), ManualLocationSheet.intervalText(600))
        // Under a minute reads as a minute.
        XCTAssertEqual(ManualLocationSheet.intervalText(20), ManualLocationSheet.intervalText(60))
    }
}

/// Answers every lookup with the same made-up names, without the network.
private struct SyntheticAreaGeocoder: ImportGeocoder {
    func reverseGeocode(coordinate: GeoPoint) async throws -> ImportGeocodeResult {
        ImportGeocodeResult(city: "Synthetic City", area: "Synthetic Area")
    }
}
