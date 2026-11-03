import Foundation
import SwiftData
import XCTest
@testable import Moments

/// Library place-filter rows use cities without hiding personal place names.
@MainActor
final class PlaceFilterCityTests: XCTestCase {
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

    private func countedOptions(for items: [MediaItem]) -> [LibraryPlaceOption] {
        var overrideCounts: [String: Int] = [:]
        var placeCounts: [PersistentIdentifier: (place: Place, count: Int)] = [:]
        for item in items {
            let override: String? = item.placeOverrideName?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let override, !override.isEmpty {
                overrideCounts[override, default: 0] += 1
                continue
            }
            guard let place = item.place else { continue }
            let id: PersistentIdentifier = place.persistentModelID
            if let entry = placeCounts[id] {
                let updatedCount: Int = entry.count + 1
                placeCounts[id] = (place: entry.place, count: updatedCount)
            } else {
                placeCounts[id] = (place: place, count: 1)
            }
        }
        return PlaceNames.options(overrideCounts: overrideCounts, placeCounts: placeCounts)
    }

    private func assertOptions(
        _ items: [MediaItem],
        names: [String],
        ids: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let uncached: [LibraryPlaceOption] = PlaceNames.options(for: items)
        XCTAssertEqual(uncached.map { (option: LibraryPlaceOption) -> String in option.name }, names, file: file, line: line)
        XCTAssertEqual(uncached.map { (option: LibraryPlaceOption) -> String in option.id }, ids, file: file, line: line)
        let counted: [LibraryPlaceOption] = countedOptions(for: items)
        XCTAssertEqual(counted.map { (option: LibraryPlaceOption) -> String in option.name }, names, file: file, line: line)
        XCTAssertEqual(counted.map { (option: LibraryPlaceOption) -> String in option.id }, ids, file: file, line: line)
    }

    private func cityID(_ name: String) -> String {
        PlaceNames.optionPrefix + PlaceNames.key(name)
    }

    func testTwoAreasAndSpotsUnderOneCityProduceOneCityRow() throws {
        let context = try makeContext()
        let city = Place(id: "synthetic-city", name: "Chongqing", kind: .city)
        let firstArea = Place(id: "synthetic-area-1", name: "First District", kind: .area, parent: city)
        let secondArea = Place(id: "synthetic-area-2", name: "Second District", kind: .area, parent: city)
        let firstSpot = Place(id: "synthetic-spot-1", name: "Spot one", parent: firstArea)
        let secondSpot = Place(id: "synthetic-spot-2", name: "Spot two", parent: secondArea)
        let places = [city, firstArea, secondArea, firstSpot, secondSpot]
        places.forEach { (place: Place) -> Void in context.insert(place) }
        let first = MediaItem(id: "synthetic-photo-1", place: firstSpot)
        let second = MediaItem(id: "synthetic-photo-2", place: secondSpot)
        [first, second].forEach { (item: MediaItem) -> Void in context.insert(item) }
        try context.save()

        assertOptions([first, second], names: ["Chongqing"], ids: [cityID("Chongqing")])
    }

    func testCorrectedSpotNameProducesAPersonalRowSeparateFromItsCity() throws {
        let context = try makeContext()
        let city = Place(id: "synthetic-city", name: "Chongqing", kind: .city)
        let correctedSpot = Place(id: "synthetic-cafe-spot", name: "Cafe spot", parent: city)
        let otherSpot = Place(id: "synthetic-other-spot", name: "Other spot", parent: city)
        [city, correctedSpot, otherSpot].forEach { (place: Place) -> Void in context.insert(place) }
        let corrected = MediaItem(id: "synthetic-cafe-photo", place: correctedSpot)
        let other = MediaItem(id: "synthetic-city-photo", place: otherSpot)
        [corrected, other].forEach { (item: MediaItem) -> Void in context.insert(item) }
        let correction = PlaceOverride(placeID: correctedSpot.id, nameOverride: "My cafe", place: correctedSpot)
        context.insert(correction)
        try context.save()

        assertOptions(
            [corrected, other],
            names: ["Chongqing", "My cafe"],
            ids: [cityID("Chongqing"), cityID("My cafe")]
        )
    }

    func testMediaItemOverrideProducesAPersonalRowSeparateFromItsCity() throws {
        let context = try makeContext()
        let city = Place(id: "synthetic-city", name: "Chongqing", kind: .city)
        let firstSpot = Place(id: "synthetic-spot-1", name: "First spot", parent: city)
        let secondSpot = Place(id: "synthetic-spot-2", name: "Second spot", parent: city)
        [city, firstSpot, secondSpot].forEach { (place: Place) -> Void in context.insert(place) }
        let personal = MediaItem(id: "synthetic-personal-photo", place: firstSpot)
        let other = MediaItem(id: "synthetic-city-photo", place: secondSpot)
        [personal, other].forEach { (item: MediaItem) -> Void in context.insert(item) }
        let override = PlaceOverride(mediaID: personal.id, nameOverride: "  Family lunch  ", mediaItem: personal)
        context.insert(override)
        try context.save()

        assertOptions(
            [personal, other],
            names: ["Chongqing", "Family lunch"],
            ids: [cityID("Chongqing"), cityID("Family lunch")]
        )
    }

    func testSpotWithoutACityAncestorKeepsItsResolvedName() throws {
        let context = try makeContext()
        let spot = Place(id: "synthetic-independent-spot", name: "Independent spot", kind: .spot)
        context.insert(spot)
        let item = MediaItem(id: "synthetic-independent-photo", place: spot)
        context.insert(item)
        try context.save()

        let resolved = PlaceDisplayName.resolvedName(of: spot)
        XCTAssertEqual(resolved, "Independent spot")
        assertOptions([item], names: ["Independent spot"], ids: [cityID("Independent spot")])
    }

    func testCityFilterKeyStillMatchesBothCityDescendants() throws {
        let context = try makeContext()
        let city = Place(id: "synthetic-city", name: "Chongqing", kind: .city)
        let firstArea = Place(id: "synthetic-area-1", name: "First District", kind: .area, parent: city)
        let secondArea = Place(id: "synthetic-area-2", name: "Second District", kind: .area, parent: city)
        let firstSpot = Place(id: "synthetic-spot-1", name: "Spot one", parent: firstArea)
        let secondSpot = Place(id: "synthetic-spot-2", name: "Spot two", parent: secondArea)
        let places = [city, firstArea, secondArea, firstSpot, secondSpot]
        places.forEach { (place: Place) -> Void in context.insert(place) }
        let first = MediaItem(id: "synthetic-photo-1", place: firstSpot)
        let second = MediaItem(id: "synthetic-photo-2", place: secondSpot)
        [first, second].forEach { (item: MediaItem) -> Void in context.insert(item) }
        try context.save()

        let key = PlaceNames.key("Chongqing")
        XCTAssertTrue(PlaceNames.matches(first, key: key))
        XCTAssertTrue(PlaceNames.matches(second, key: key))
    }
}
