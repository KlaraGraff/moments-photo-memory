import Foundation
import SwiftData
import XCTest
@testable import Moments

@MainActor
final class PlaceDisplayNameTests: XCTestCase {
    func testGeneratedSpotLabelsArePlaceholders() {
        XCTAssertTrue(PlaceDisplayName.isPlaceholder("Spot 402a14", placeID: "spot-9f3c402a14"))
        XCTAssertTrue(PlaceDisplayName.isPlaceholder("地点 402a14", placeID: "spot-9f3c402a14"))
        XCTAssertTrue(PlaceDisplayName.isPlaceholder("Ort 402a14", placeID: "spot-9f3c402a14"))
        XCTAssertTrue(PlaceDisplayName.isPlaceholder("  ", placeID: "spot-9f3c402a14"))
    }

    func testRealNamesAreKept() {
        XCTAssertFalse(PlaceDisplayName.isPlaceholder("Old harbour", placeID: "spot-9f3c402a14"))
        // A real name that happens to end in a number is not the generated label.
        XCTAssertFalse(PlaceDisplayName.isPlaceholder("Spot 402a14", placeID: "spot-000000"))
        XCTAssertFalse(PlaceDisplayName.isPlaceholder("Café on the 402a14", placeID: "spot-9f3c402a14"))
    }

    func testGeneratedSpotShowsNearestNamedParent() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let city = Place(id: "city-1", name: "Synthetic Town", kind: .city)
        let area = Place(id: "area-1", name: "Unknown area", kind: .area, parent: city)
        let spot = Place(id: "spot-abc123", name: "Spot abc123", kind: .spot, parent: area)
        let orphan = Place(id: "spot-def456", name: "Spot def456", kind: .spot)
        [city, area, spot, orphan].forEach(context.insert)
        try context.save()

        XCTAssertEqual(spot.displayName, "Synthetic Town")
        XCTAssertEqual(orphan.displayName, String(localized: "Unknown place"))
        XCTAssertEqual(city.displayName, "Synthetic Town")
        XCTAssertTrue(PlaceDisplayName.place(spot, isWithin: "city-1"), "A city filter must match the spots under it")
        XCTAssertFalse(PlaceDisplayName.place(orphan, isWithin: "city-1"))
    }

    func testImportFallbackNamesInAnyLanguageAreSkipped() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let city = Place(id: "city-2", name: "未知城市", kind: .city)
        let area = Place(id: "area-2", name: "Unbekanntes Gebiet", kind: .area, parent: city)
        let spot = Place(id: "spot-aaa111", name: "Ort aaa111", kind: .spot, parent: area)
        [city, area, spot].forEach(context.insert)
        try context.save()

        XCTAssertNil(PlaceDisplayName.namingPlace(of: spot))
        XCTAssertEqual(spot.displayName, String(localized: "Unknown place"))
    }
}
