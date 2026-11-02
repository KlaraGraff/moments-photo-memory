import Foundation
import SwiftData
import XCTest
@testable import Moments

/// Proves that resolving a place name once per place, instead of once per
/// photo, still produces exactly the same `PlaceNames.groups(for:)` result.
@MainActor
final class PlaceNamesGroupsEquivalenceTests: XCTestCase {
    private var container: ModelContainer?

    override func tearDown() {
        container = nil
        super.tearDown()
    }

    private func makeContext() throws -> ModelContext {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        self.container = container
        return container.mainContext
    }

    /// `PlaceNames.groups(for:)` as it was before the per-place cache,
    /// copied verbatim (only the type prefixes are spelled out here).
    private func referenceGroups(for items: [MediaItem]) -> [PlaceNames.Group] {
        var groups: [String: PlaceNames.Group] = [:]
        var spellings: [String: [String: Int]] = [:]
        for item in items {
            guard let name = PlaceNames.listedName(of: item) else { continue }
            let key = PlaceNames.key(name)
            guard !key.isEmpty else { continue }
            spellings[key, default: [:]][name, default: 0] += 1
            let emptyGroup = PlaceNames.Group(key: key, name: name, itemIDs: [])
            groups[key, default: emptyGroup].itemIDs.append(item.id)
        }
        for (key, counts) in spellings {
            if let name = counts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key {
                groups[key]?.name = name
            }
        }
        return groups.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 3 cities, 6 areas, 30 spots (unnamed, placeholder, "Unknown area",
    /// renamed places) and 400 photos spread over them, some with their own
    /// name, some with only whitespace, some without a place.
    private func makeFixture(in context: ModelContext) throws -> [MediaItem] {
        var areas: [Place] = []
        for cityIndex in 0..<3 {
            let city = Place(id: "city-\(cityIndex)", name: "City \(cityIndex)", kind: .city)
            context.insert(city)
            for areaIndex in 0..<2 {
                let area = Place(
                    id: "area-\(cityIndex)-\(areaIndex)",
                    name: "Area \(cityIndex) \(areaIndex)",
                    kind: .area,
                    parent: city
                )
                context.insert(area)
                areas.append(area)
            }
        }

        var spots: [Place] = []
        spots.reserveCapacity(30)
        for spotIndex in 0..<30 {
            let area: Place = areas[spotIndex % areas.count]
            let id = String(format: "spot-%06d", spotIndex)
            let place: Place
            switch spotIndex % 5 {
            case 0:
                place = Place(id: id, name: "", parent: area)
            case 1:
                place = Place(id: id, name: "Spot " + String(id.suffix(6)), parent: area)
            case 2:
                place = Place(id: id, name: "Unknown area", parent: area)
            case 3:
                place = Place(id: id, name: "Harbor \(spotIndex)", parent: area)
            default:
                place = Place(id: id, name: "Beach \(spotIndex)", parent: area)
            }
            context.insert(place)
            spots.append(place)
        }

        // Place-wide renames: one merges two places under one name, two differ
        // only in spelling, one replaces the import's internal spot handle.
        let renames: [(index: Int, name: String)] = [
            (3, "Harbor Renamed"),
            (8, "Harbor Renamed"),
            (13, "Lighthouse"),
            (18, "lighthouse"),
            (1, "Cliff Walk")
        ]
        for rename in renames {
            let place: Place = spots[rename.index]
            context.insert(PlaceOverride(placeID: place.id, nameOverride: rename.name, place: place))
        }

        var items: [MediaItem] = []
        items.reserveCapacity(400)
        for index in 0..<400 {
            let place: Place? = index % 37 == 0 ? nil : spots[index % spots.count]
            let date = Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 3_600)
            let item = MediaItem(id: "photo-\(index)", captureDate: date, place: place)
            context.insert(item)
            if index % 40 == 0 {
                context.insert(PlaceOverride(mediaID: item.id, nameOverride: "Same", mediaItem: item))
            } else if index % 40 == 1 {
                context.insert(PlaceOverride(mediaID: item.id, nameOverride: "same", mediaItem: item))
            } else if index % 11 == 0 {
                context.insert(PlaceOverride(mediaID: item.id, nameOverride: "Own spot \(index)", mediaItem: item))
            } else if index % 13 == 0 {
                context.insert(PlaceOverride(mediaID: item.id, nameOverride: "   ", mediaItem: item))
            }
            items.append(item)
        }
        try context.save()
        return items
    }

    private func assertSameGroups(
        _ actual: [PlaceNames.Group],
        _ expected: [PlaceNames.Group],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actualKeys: [String] = actual.map { $0.key }
        let expectedKeys: [String] = expected.map { $0.key }
        XCTAssertEqual(actualKeys, expectedKeys, file: file, line: line)
        let actualNames: [String] = actual.map { $0.name }
        let expectedNames: [String] = expected.map { $0.name }
        XCTAssertEqual(actualNames, expectedNames, file: file, line: line)
        let actualIDLists: [[String]] = actual.map { $0.itemIDs }
        let expectedIDLists: [[String]] = expected.map { $0.itemIDs }
        XCTAssertEqual(actualIDLists, expectedIDLists, file: file, line: line)
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    func testGroupsMatchTheReferenceForThePhotos() throws {
        let context = try makeContext()
        let items = try makeFixture(in: context)

        let groups: [PlaceNames.Group] = PlaceNames.groups(for: items)
        XCTAssertGreaterThan(groups.count, 5, "The fixture must produce several place names")
        assertSameGroups(groups, referenceGroups(for: items))
    }

    func testGroupsMatchTheReferenceForThePhotosReversed() throws {
        let context = try makeContext()
        let items = try makeFixture(in: context)
        let reversed: [MediaItem] = Array(items.reversed())

        let groups: [PlaceNames.Group] = PlaceNames.groups(for: reversed)
        assertSameGroups(groups, referenceGroups(for: reversed))
    }

    func testGroupsMatchTheReferenceForAnEmptyList() throws {
        let context = try makeContext()
        _ = try makeFixture(in: context)
        let empty: [MediaItem] = []

        assertSameGroups(PlaceNames.groups(for: empty), referenceGroups(for: empty))
    }

    /// Two spellings of one name with the same count must pick the same one
    /// whatever order the photos come in.
    func testEqualSpellingsDoNotDependOnThePhotoOrder() throws {
        let context = try makeContext()
        let items = try makeFixture(in: context)
        let reversed: [MediaItem] = Array(items.reversed())

        let forwardKeys: [String] = PlaceNames.groups(for: items).map { $0.key }
        let backwardKeys: [String] = PlaceNames.groups(for: reversed).map { $0.key }
        XCTAssertEqual(forwardKeys, backwardKeys)
        let forwardNames: [String] = PlaceNames.groups(for: items).map { $0.name }
        let backwardNames: [String] = PlaceNames.groups(for: reversed).map { $0.name }
        XCTAssertEqual(forwardNames, backwardNames)
    }

    /// A photo's own name wins over its place's, also when it is listed in the
    /// same name group as place-only photos.
    func testOwnNamesAndPlaceNamesShareOneGroup() throws {
        let context = try makeContext()
        let city = Place(id: "city-shared", name: "Marrakesh", kind: .city)
        let spot = Place(id: "spot-shared", name: "Spot shared", parent: city)
        context.insert(city)
        context.insert(spot)
        XCTAssertTrue(PlaceDisplayName.isPlaceholder(spot.name, placeID: spot.id))
        let named = MediaItem(id: "named", place: spot)
        let own = MediaItem(id: "own", place: spot)
        context.insert(named)
        context.insert(own)
        context.insert(PlaceOverride(mediaID: own.id, nameOverride: "Marrakesh", mediaItem: own))
        try context.save()

        let groups: [PlaceNames.Group] = PlaceNames.groups(for: [named, own])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.name, "Marrakesh")
        XCTAssertEqual(Set(groups.first?.itemIDs ?? []), Set(["named", "own"]))
    }
}
