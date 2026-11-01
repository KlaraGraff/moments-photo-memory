import Foundation
import XCTest
@testable import MomentsCore

final class PlaceClustererEdgeCaseTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)
    private let levels = PlaceLevel.allCases

    func testEmptyInputProducesNoClustersAtEveryLevel() {
        for level in levels {
            XCTAssertTrue(
                PlaceClusterer().clusters(for: [], level: level).isEmpty,
                "\(level) should have no clusters"
            )
        }
    }

    func testStopsWithoutCoordinateAreLeftOutOfEveryCluster() {
        let located = stop("located", hours: 1, latitude: 10, longitude: 10)
        let missing = stop("missing", hours: 0)

        for level in levels {
            let clusters = PlaceClusterer().clusters(for: [located, missing], level: level)
            XCTAssertEqual(clusters.count, 1, "\(level) should only keep the located stop")
            XCTAssertEqual(clusters[0].stopIDs, ["located"])
            XCTAssertFalse(clusters.flatMap(\.stopIDs).contains("missing"))
        }

        // Without any override the unlocated stop is dropped even when it is alone.
        for level in levels {
            XCTAssertTrue(PlaceClusterer().clusters(for: [missing], level: level).isEmpty)
        }
    }

    func testOverrideForcesUnlocatedStopIntoNamedCluster() {
        let missing = stop("missing", hours: 0)
        let located = stop("located", hours: 1, latitude: 10, longitude: 10)
        let clusterer = PlaceClusterer(overrides: [
            PlaceOverride(stopID: "missing", clusterID: "remembered", name: "Home")
        ])

        for level in levels {
            let clusters = clusterer.clusters(for: [located, missing], level: level)
            let overridden = clusters.first { $0.id == "remembered" }
            if level == .spot {
                XCTAssertNotNil(overridden, "\(level) should contain the override cluster")
                XCTAssertEqual(overridden?.name, "Home")
                XCTAssertEqual(overridden?.stopIDs, ["missing"])
                XCTAssertNil(overridden?.center)
            } else {
                // The override defaults to the spot level, so other levels ignore it.
                XCTAssertNil(overridden)
            }
        }

        let alone = clusterer.clusters(for: [missing], level: .spot)
        XCTAssertEqual(alone.count, 1)
        XCTAssertEqual(alone[0].id, "remembered")
        XCTAssertEqual(alone[0].name, "Home")
        XCTAssertNil(alone[0].center)
    }

    func testSpotOverrideDoesNotApplyAtCityLevel() {
        let stops = [
            stop("one", hours: 0, latitude: 10, longitude: 10),
            stop("two", hours: 1, latitude: 10, longitude: 10)
        ]
        let clusterer = PlaceClusterer(overrides: [
            PlaceOverride(stopID: "one", level: .spot, clusterID: "spot-only", name: "Spot only")
        ])

        let spots = clusterer.clusters(for: stops, level: .spot)
        XCTAssertEqual(spots.map(\.id), ["spot-only", "spot-two"])
        XCTAssertEqual(spots[0].name, "Spot only")
        XCTAssertEqual(spots[1].name, nil)

        let cities = clusterer.clusters(for: stops, level: .city)
        XCTAssertEqual(cities.count, 1)
        XCTAssertEqual(cities[0].id, "city-one")
        XCTAssertNil(cities[0].name)
        XCTAssertEqual(cities[0].stopIDs, ["one", "two"])

        let areas = clusterer.clusters(for: stops, level: .area)
        XCTAssertEqual(areas.map(\.id), ["area-one"])
    }

    func testDictionaryOverridesApplyAtAllThreeLevels() {
        let missing = stop("missing", hours: 0)
        let first = stop("first", hours: 1, latitude: 10, longitude: 10)
        let second = stop("second", hours: 2, latitude: 10.005, longitude: 10.005)
        let clusterer = PlaceClusterer(overrides: ["missing": "remembered"])

        for level in levels {
            let clusters = clusterer.clusters(for: [first, missing, second], level: level)
            let remembered = clusters.filter { $0.id == "remembered" }
            XCTAssertEqual(remembered.count, 1, "\(level) should have the dictionary override")
            XCTAssertEqual(remembered[0].stopIDs, ["missing"])
            XCTAssertEqual(remembered[0].level, level)
            XCTAssertNil(remembered[0].name)

            // The located stops are still clustered automatically.
            XCTAssertEqual(clusters.count, 2, "\(level) should also keep the automatic cluster")
        }
    }

    func testLastDuplicateOverrideForTheSameStopAndLevelWins() {
        let stops = [
            stop("one", hours: 0, latitude: 10, longitude: 10),
            stop("two", hours: 1, latitude: 10.001, longitude: 10.001)
        ]
        let first = PlaceOverride(stopID: "one", level: .spot, clusterID: "first", name: "First")
        let second = PlaceOverride(stopID: "one", level: .spot, clusterID: "second", name: "Second")

        let forward = PlaceClusterer(overrides: [first, second]).clusters(for: stops, level: .spot)
        XCTAssertEqual(forward.count, 2)
        XCTAssertEqual(forward[0].id, "second")
        XCTAssertEqual(forward[0].name, "Second")
        XCTAssertEqual(forward[1].id, "spot-two")

        let backward = PlaceClusterer(overrides: [second, first]).clusters(for: stops, level: .spot)
        XCTAssertEqual(backward[0].id, "first")
        XCTAssertEqual(backward[0].name, "First")

        // The dictionary initializer has a single value per key, so it never traps.
        let dictionary = PlaceClusterer(overrides: ["one": "mapped"]).clusters(for: stops, level: .spot)
        XCTAssertEqual(dictionary.map(\.id), ["mapped", "spot-two"])
    }

    func testSpotLevelSplitsOnATwentyFourHourGapWhileAreaLevelDoesNot() {
        let samePlace = GeoPoint(latitude: 10, longitude: 10)
        let stops = [
            stop("first", hours: 0, coordinate: samePlace),
            stop("second", hours: 25, coordinate: samePlace)
        ]

        let spots = PlaceClusterer().clusters(for: stops, level: .spot)
        XCTAssertEqual(spots.count, 2)
        XCTAssertEqual(spots.map(\.stopIDs), [["first"], ["second"]])

        let areas = PlaceClusterer().clusters(for: stops, level: .area)
        XCTAssertEqual(areas.count, 1)
        XCTAssertEqual(areas[0].stopIDs, ["first", "second"])

        let cities = PlaceClusterer().clusters(for: stops, level: .city)
        XCTAssertEqual(cities.count, 1)
        XCTAssertEqual(cities[0].stopIDs, ["first", "second"])
    }

    func testSpotRadiusKeepsFourteenHundredMetersAndRejectsSixteenHundred() {
        let anchor = GeoPoint(latitude: 0, longitude: 0)
        let inside = pointMetresNorth(of: anchor, metres: 1_400)
        let outside = pointMetresNorth(of: anchor, metres: 1_600)

        let insideDistance = anchor.distance(to: inside)
        XCTAssertEqual(insideDistance, 1_400, accuracy: 1)
        XCTAssertLessThan(insideDistance, 1_500)

        let outsideDistance = anchor.distance(to: outside)
        XCTAssertEqual(outsideDistance, 1_600, accuracy: 1)
        XCTAssertGreaterThan(outsideDistance, 1_500)

        let stops = [
            stop("anchor", hours: 0, coordinate: anchor),
            stop("inside", hours: 1, coordinate: inside)
        ]
        let closeSpots = PlaceClusterer().clusters(for: stops, level: .spot)
        XCTAssertEqual(closeSpots.count, 1)
        XCTAssertEqual(closeSpots[0].stopIDs, ["anchor", "inside"])

        let farStops = [
            stop("anchor", hours: 0, coordinate: anchor),
            stop("outside", hours: 1, coordinate: outside)
        ]
        let farSpots = PlaceClusterer().clusters(for: farStops, level: .spot)
        XCTAssertEqual(farSpots.count, 2)
        XCTAssertEqual(farSpots.map(\.stopIDs), [["anchor"], ["outside"]])

        // A wider radius keeps the far stop with the anchor.
        XCTAssertEqual(
            PlaceClusterer(spotRadiusMeters: 2_000)
                .clusters(for: farStops, level: .spot)
                .count,
            1
        )
    }

    func testAutomaticClusterIDUsesTheLevelAndTheEarliestStopID() {
        let stops = [
            stop("b", hours: 1, latitude: 10, longitude: 10),
            stop("a", hours: 0, latitude: 10.001, longitude: 10.001),
            stop("   ", hours: 2, latitude: 10.002, longitude: 10.002)
        ]

        let spots = PlaceClusterer().clusters(for: stops, level: .spot)
        XCTAssertEqual(spots.count, 1)
        // "a" is the earliest stop, so the whole cluster is named after it.
        XCTAssertEqual(spots[0].id, "spot-a")

        let areas = PlaceClusterer().clusters(for: stops, level: .area)
        XCTAssertEqual(areas.map(\.id), ["area-a"])

        let cities = PlaceClusterer().clusters(for: stops, level: .city)
        XCTAssertEqual(cities.map(\.id), ["city-a"])

        let blankOnly = [stop("   ", hours: 0, latitude: 10, longitude: 10)]
        XCTAssertEqual(
            PlaceClusterer().clusters(for: blankOnly, level: .spot).map(\.id),
            ["spot-unnamed"]
        )
        XCTAssertEqual(
            PlaceClusterer().clusters(for: blankOnly, level: .city).map(\.id),
            ["city-unnamed"]
        )
    }

    func testClustersAreSortedByFirstDateThenByID() {
        let later = [stop("z-first", hours: 5, latitude: 10, longitude: 10)]
        let earlierSameDate = [
            stop("b", hours: 0, latitude: 42, longitude: 42),
            stop("a", hours: 0, latitude: 43, longitude: 43)
        ]

        let stops = later + earlierSameDate
        let spots = PlaceClusterer().clusters(for: stops, level: .spot)

        XCTAssertEqual(spots.count, 3)
        XCTAssertEqual(spots.map(\.id), ["spot-a", "spot-b", "spot-z-first"])
        XCTAssertEqual(spots.map(\.firstDate), [origin, origin, origin.addingTimeInterval(5 * 3_600)])
        // The tie on firstDate is broken by the cluster id, not the input order.
        XCTAssertEqual(
            PlaceClusterer().clusters(for: earlierSameDate.reversed() + later, level: .spot).map(\.id),
            ["spot-a", "spot-b", "spot-z-first"]
        )
    }

    func testStopWithinReachOfTwoClustersJoinsTheNearerOne() {
        // A and B are about 2.6 km apart, so the default 1.5 km radius keeps them separate.
        let anchorA = GeoPoint(latitude: 0, longitude: 0)
        let anchorB = GeoPoint(latitude: 0, longitude: 0.023382)
        let probe = GeoPoint(latitude: 0, longitude: 0.0107918)

        XCTAssertGreaterThan(anchorA.distance(to: anchorB), 2_500)
        XCTAssertLessThan(anchorA.distance(to: anchorB), 2_700)
        XCTAssertLessThan(anchorA.distance(to: probe), 1_500)
        XCTAssertLessThan(anchorB.distance(to: probe), 1_500)
        XCTAssertLessThan(anchorA.distance(to: probe), anchorB.distance(to: probe))

        let stops = [
            stop("a", hours: 0, coordinate: anchorA),
            stop("b", hours: 1, coordinate: anchorB),
            stop("probe", hours: 2, coordinate: probe)
        ]

        let spots = PlaceClusterer().clusters(for: stops, level: .spot)
        XCTAssertEqual(spots.count, 2)
        XCTAssertEqual(spots.map(\.stopIDs), [["a", "probe"], ["b"]])

        // A probe nearer to B picks B instead, proving distance decides.
        let towardsB = GeoPoint(latitude: 0, longitude: 0.0125902)
        XCTAssertLessThan(anchorB.distance(to: towardsB), anchorA.distance(to: towardsB))
        let mirrored = [
            stop("a", hours: 0, coordinate: anchorA),
            stop("b", hours: 1, coordinate: anchorB),
            stop("probe", hours: 2, coordinate: towardsB)
        ]
        let mirroredSpots = PlaceClusterer().clusters(for: mirrored, level: .spot)
        XCTAssertEqual(mirroredSpots.map(\.stopIDs), [["a"], ["b", "probe"]])
    }

    func testNegativeRadiusIsClampedToZero() {
        let same = GeoPoint(latitude: 10, longitude: 10)
        let nearby = pointMetresNorth(of: same, metres: 1)
        let stops = [
            stop("first", hours: 0, coordinate: same),
            stop("exact", hours: 1, coordinate: same),
            stop("nearby", hours: 2, coordinate: nearby)
        ]

        let clusterer = PlaceClusterer(spotRadiusMeters: -1, areaRadiusMeters: -1, cityRadiusMeters: -1)
        XCTAssertEqual(clusterer.spotRadiusMeters, 0)
        XCTAssertEqual(clusterer.areaRadiusMeters, 0)
        XCTAssertEqual(clusterer.cityRadiusMeters, 0)

        for level in levels {
            let clusters = clusterer.clusters(for: stops, level: level)
            XCTAssertEqual(clusters.count, 2, "\(level) should split on any distance")
            XCTAssertEqual(clusters.map(\.stopIDs), [["first", "exact"], ["nearby"]])
        }
    }

    func testInputOrderDoesNotChangeTheResult() {
        let stops = [
            stop("a-1", hours: 0, latitude: 0, longitude: 0),
            stop("a-2", hours: 1, latitude: 0, longitude: 0.0036),
            stop("b-1", hours: 2, latitude: 0, longitude: 0.09),
            stop("b-2", hours: 20, latitude: 0, longitude: 0.0936),
            stop("c-1", hours: 60, latitude: 0, longitude: 0.18)
        ]

        var generator = SplitMix64(seed: 0x5EED_1234)
        var previous: [PlaceCluster]?

        for _ in 0..<5 {
            let shuffled = shuffled(stops, using: &generator)
            let result = PlaceClusterer().clusters(for: shuffled, level: .spot)
            if let previous {
                XCTAssertEqual(result, previous)
            } else {
                previous = result
            }
        }

        XCTAssertEqual(previous?.count, 3)
        XCTAssertEqual(previous?.map(\.id), ["spot-a-1", "spot-b-1", "spot-c-1"])
        XCTAssertEqual(previous?.map(\.stopIDs), [["a-1", "a-2"], ["b-1", "b-2"], ["c-1"]])
    }

    private func shuffled(_ stops: [PhotoStop], using generator: inout SplitMix64) -> [PhotoStop] {
        var result = stops
        for index in stride(from: result.count - 1, to: 0, by: -1) {
            let pick = Int(generator.next() % UInt64(index + 1))
            result.swapAt(index, pick)
        }
        return result
    }

    /// A small deterministic generator so the shuffle is reproducible across runs.
    private struct SplitMix64: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { self.state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Moves `metres` north from `point`, using the 6,371,000 m Earth radius of the source.
    private func pointMetresNorth(of point: GeoPoint, metres: Double) -> GeoPoint {
        let degreesPerMetre = 180 / (Double.pi * 6_371_000)
        return GeoPoint(latitude: point.latitude + metres * degreesPerMetre, longitude: point.longitude)
    }

    private func stop(_ id: String, hours: TimeInterval, latitude: Double, longitude: Double) -> PhotoStop {
        stop(id, hours: hours, coordinate: GeoPoint(latitude: latitude, longitude: longitude))
    }

    private func stop(_ id: String, hours: TimeInterval, coordinate: GeoPoint? = nil) -> PhotoStop {
        PhotoStop(
            id: id,
            date: origin.addingTimeInterval(hours * 60 * 60),
            coordinate: coordinate
        )
    }
}
