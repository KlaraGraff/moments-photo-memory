import Foundation
import MomentsCore
import SwiftData
import XCTest
@testable import Moments

/// Checks the Places-backed `NearestPlaceIndex` against the per-photo scan the
/// Timeline and Chapters pages used before: same name, same 100 km limit and
/// the same answer when two places are equally near.
@MainActor
final class NearestPlaceIndexPlacesTests: XCTestCase {
    /// Held for the whole test: a ModelContext whose container is released crashes.
    private var container: ModelContainer?

    override func tearDown() {
        container = nil
        super.tearDown()
    }

    func testIndexGivesTheSameAnswersAsTheScanForEveryPhoto() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        self.container = container
        let context = container.mainContext

        let places = makePlaces()
        places.forEach(context.insert)

        let items = makeItems()
        items.forEach(context.insert)
        try context.save()

        let index = NearestPlaceIndex(places: places)
        var labelled = 0
        for item in items {
            let expected = bruteForceNearestPlaceName(for: item, in: places)
            let actual = index.nearestPlaceName(for: item)
            XCTAssertEqual(actual, expected, "Photo \(item.id) should be labelled like the old scan")
            if actual != nil { labelled += 1 }
        }
        // The synthetic data covers both answers: some photos get a place, some none.
        XCTAssertGreaterThan(labelled, 0)
        XCTAssertLessThan(labelled, items.count)
    }

    func testEquallyNearPlacesKeepTheFirstOneInPlacesOrder() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        self.container = container
        let context = container.mainContext

        let first = Place(id: "spot-first", name: "Synthetic First", kind: .spot, latitude: 1.5, longitude: 2.5)
        let second = Place(id: "spot-second", name: "Synthetic Second", kind: .spot, latitude: 1.5, longitude: 2.5)
        [first, second].forEach(context.insert)
        let item = MediaItem(id: "photo-between", latitude: 1.5, longitude: 2.5)
        context.insert(item)
        try context.save()

        XCTAssertEqual(NearestPlaceIndex(places: [first, second]).nearestPlaceName(for: item), "Synthetic First")
        XCTAssertEqual(NearestPlaceIndex(places: [second, first]).nearestPlaceName(for: item), "Synthetic Second")
    }

    func testPhotosBeyondOneHundredKilometresGetNoPlace() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        self.container = container
        let context = container.mainContext

        let near = Place(id: "spot-near", name: "Synthetic Near", kind: .spot, latitude: 0, longitude: 1)
        let far = Place(id: "spot-far", name: "Synthetic Far", kind: .spot, latitude: 0, longitude: 5)
        [near, far].forEach(context.insert)
        let item = MediaItem(id: "photo-just-outside", latitude: 0, longitude: 1.95)
        context.insert(item)
        try context.save()

        // About 105 km east of "Synthetic Near": past the limit, before the far place.
        XCTAssertNil(NearestPlaceIndex(places: [near, far]).nearestPlaceName(for: item))
        XCTAssertNil(bruteForceNearestPlaceName(for: item, in: [near, far]))
    }

    // MARK: Synthetic data

    /// 300 made-up places: 10 named cities, and spots around them. Some spots
    /// have no coordinate, some carry only the import's placeholder label.
    private func makePlaces() -> [Place] {
        var random = SeededRandom(seed: 20_260_101)
        var places: [Place] = []

        let centres: [(latitude: Double, longitude: Double)] = (0..<10).map { index in
            (latitude: Double(index % 5) * 1.2 - 2.4, longitude: Double(index % 3) * 1.5 - 1.5)
        }

        var cities: [Place] = []
        for (index, centre) in centres.enumerated() {
            let city = Place(
                id: "city-\(index)",
                name: "Synthetic City \(index)",
                kind: .city,
                latitude: centre.latitude,
                longitude: centre.longitude
            )
            cities.append(city)
            places.append(city)
        }

        for index in 0..<290 {
            let centre = centres[index % centres.count]
            let latitude = centre.latitude + random.double(in: -0.3...0.3)
            let longitude = centre.longitude + random.double(in: -0.3...0.3)

            switch index % 10 {
            case 0, 1:
                // No coordinate at all: never indexed.
                places.append(Place(id: "spot-\(index)", name: "Synthetic Spot \(index)", kind: .spot))
            case 2:
                // The import's internal handle, with no parent: no name to show.
                let suffix = String(format: "%06d", index)
                places.append(Place(
                    id: "spot-\(suffix)",
                    name: "Spot \(suffix)",
                    kind: .spot,
                    latitude: latitude,
                    longitude: longitude
                ))
            case 3:
                // The same placeholder, but a named city above it supplies the name.
                let suffix = String(format: "%06d", index)
                places.append(Place(
                    id: "spot-\(suffix)",
                    name: "Spot \(suffix)",
                    kind: .spot,
                    latitude: latitude,
                    longitude: longitude,
                    parent: cities[index % cities.count]
                ))
            default:
                places.append(Place(
                    id: "spot-\(index)",
                    name: "Synthetic Spot \(index)",
                    kind: .spot,
                    latitude: latitude,
                    longitude: longitude
                ))
            }
        }
        return places
    }

    /// 500 made-up photos: around the cities, far out at sea, and a few
    /// without a coordinate.
    private func makeItems() -> [MediaItem] {
        var random = SeededRandom(seed: 500 + 300)
        let centres: [(latitude: Double, longitude: Double)] = (0..<10).map { index in
            (latitude: Double(index % 5) * 1.2 - 2.4, longitude: Double(index % 3) * 1.5 - 1.5)
        }

        return (0..<500).map { index in
            switch index % 20 {
            case 0:
                // No coordinate: no place.
                return MediaItem(id: "photo-\(index)", captureDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)))
            case 1, 2:
                // Far outside every place, near the map's edge.
                return MediaItem(
                    id: "photo-\(index)",
                    captureDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                    latitude: random.double(in: -4.9...4.9),
                    longitude: random.double(in: -4.9...4.9)
                )
            default:
                let centre = centres[index % centres.count]
                return MediaItem(
                    id: "photo-\(index)",
                    captureDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                    latitude: centre.latitude + random.double(in: -0.5...0.5),
                    longitude: centre.longitude + random.double(in: -0.5...0.5)
                )
            }
        }
    }

    // MARK: Brute force

    /// The scan both screens did before the index: every named place, every photo.
    private func bruteForceNearestPlaceName(for item: MediaItem, in places: [Place]) -> String? {
        guard let latitude = item.latitude, let longitude = item.longitude else { return nil }
        let coordinate = GeoPoint(latitude: latitude, longitude: longitude)
        let nearest = places.compactMap { place -> (name: String, distance: Double)? in
            guard let placeLatitude = place.latitude, let placeLongitude = place.longitude,
                  let name = PlaceDisplayName.resolvedName(of: place) else { return nil }
            let distance = coordinate.distance(to: GeoPoint(latitude: placeLatitude, longitude: placeLongitude))
            return (name, distance)
        }
        .min { $0.distance < $1.distance }
        guard let nearest, nearest.distance <= 100_000 else { return nil }
        return nearest.name
    }
}

/// A tiny repeatable generator, so the synthetic data is the same every run.
private struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func unit() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / Double(1 << 53)
    }

    mutating func double(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + unit() * (range.upperBound - range.lowerBound)
    }
}
