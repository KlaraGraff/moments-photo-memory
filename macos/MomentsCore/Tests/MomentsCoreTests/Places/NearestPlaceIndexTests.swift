import Foundation
import XCTest
@testable import MomentsCore

final class NearestPlaceIndexTests: XCTestCase {
    func testEmptyIndexFindsNothing() {
        let index = NearestPlaceIndex(entries: [])
        XCTAssertTrue(index.isEmpty)
        XCTAssertNil(index.nearestName(to: GeoPoint(latitude: 0, longitude: 0), within: 1_000_000))
        XCTAssertNil(index.nearestName(to: GeoPoint(latitude: 40, longitude: 8), within: 0))
    }

    func testNothingWithinReach() {
        let index = NearestPlaceIndex(entries: [
            NearestPlaceIndex.Entry(point: GeoPoint(latitude: 0, longitude: 0), name: "a")
        ])
        let query = GeoPoint(latitude: 0, longitude: 2)

        XCTAssertNil(index.nearestName(to: query, within: 100_000))
        XCTAssertEqual(index.nearestName(to: query, within: 300_000), "a")
        XCTAssertNil(index.nearestName(to: query, within: -1))
        XCTAssertNil(index.nearestName(to: query, within: .infinity))
        XCTAssertNil(index.nearestName(to: query, within: .nan))
    }

    func testMatchesFullScan() {
        let entries = makeEntries(count: 3_000, seed: 0x5EED_1234)
        let index = NearestPlaceIndex(entries: entries)
        let queries = makeQueries(count: 2_000, seed: 0xC0FF_EE00)
        let radii: [Double] = [50, 1_500, 100_000, 2_000_000]

        XCTAssertEqual(entries.count, 3_000)
        let nearAntimeridian = entries.filter { abs($0.point.longitude) > 179.5 }.count
        let nearPole = entries.filter { abs($0.point.latitude) > 88 }.count
        let duplicatedPoints = entries.count - Set(entries.map(\.point)).count
        XCTAssertGreaterThan(nearAntimeridian, 400)
        XCTAssertGreaterThan(nearPole, 400)
        XCTAssertGreaterThan(duplicatedPoints, 20)
        XCTAssertGreaterThan(
            queries.filter { abs($0.latitude) > 88 || abs($0.longitude) > 179.5 }.count,
            400
        )

        var matches = 0
        for (queryNumber, point) in queries.enumerated() {
            for maxMeters in radii {
                let expected = bruteForceName(entries, point: point, maxMeters: maxMeters)
                let actual = index.nearestName(to: point, within: maxMeters)
                XCTAssertEqual(
                    actual,
                    expected,
                    "query \(queryNumber) at \(point.latitude),\(point.longitude) within \(maxMeters) m"
                )
                if expected != nil { matches += 1 }
            }
        }
        // Most of the wide searches must find a place, otherwise the comparison
        // would only ever check empty answers.
        XCTAssertGreaterThan(matches, 2_000)
    }

    func testTieGoesToTheFirstEntry() {
        let point = GeoPoint(latitude: 48.5, longitude: 9.25)
        let index = NearestPlaceIndex(entries: [
            NearestPlaceIndex.Entry(point: point, name: "first"),
            NearestPlaceIndex.Entry(point: point, name: "second")
        ])
        XCTAssertEqual(index.nearestName(to: point, within: 1), "first")

        let reversed = NearestPlaceIndex(entries: [
            NearestPlaceIndex.Entry(point: point, name: "second"),
            NearestPlaceIndex.Entry(point: point, name: "first")
        ])
        XCTAssertEqual(reversed.nearestName(to: point, within: 1), "second")
    }

    // MARK: - Helpers

    /// The plain scan the index must match: every entry in order, the first
    /// one with the smallest distance wins.
    private func bruteForceName(
        _ entries: [NearestPlaceIndex.Entry],
        point: GeoPoint,
        maxMeters: Double
    ) -> String? {
        var bestIndex: Int?
        var bestDistance = Double.infinity

        for (index, entry) in entries.enumerated() {
            let distance = point.distance(to: entry.point)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }

        guard let bestIndex, bestDistance <= maxMeters else { return nil }
        return entries[bestIndex].name
    }

    /// Places spread over the world, with about a third near the antimeridian
    /// or a pole and some exact copies of earlier places under a new name.
    private func makeEntries(count: Int, seed: UInt64) -> [NearestPlaceIndex.Entry] {
        var random = TestRandom(seed: seed)
        var points: [GeoPoint] = []
        var entries: [NearestPlaceIndex.Entry] = []
        points.reserveCapacity(count)
        entries.reserveCapacity(count)

        for index in 0..<count {
            let point: GeoPoint
            if index > 0, index % 97 == 0 {
                // An exact copy of an earlier place, under a different name.
                point = points[Int(random.next() >> 16) % index]
            } else {
                point = nextWorldPoint(&random)
            }
            points.append(point)
            entries.append(NearestPlaceIndex.Entry(point: point, name: "p\(index)"))
        }

        return entries
    }

    private func makeQueries(count: Int, seed: UInt64) -> [GeoPoint] {
        var random = TestRandom(seed: seed)
        return (0..<count).map { _ in nextWorldPoint(&random) }
    }

    /// A point from one of three bands: near the antimeridian, near a pole or
    /// anywhere else. The two hard bands make up about a third of the points.
    private func nextWorldPoint(_ random: inout TestRandom) -> GeoPoint {
        switch (random.next() >> 11) % 6 {
        case 0:
            let east = random.bool()
            let longitude = east
                ? random.value(in: -180...(-179.5))
                : random.value(in: 179.5...179.999)
            return GeoPoint(latitude: random.value(in: -85...85), longitude: longitude)
        case 1:
            let north = random.bool()
            let latitude = north
                ? random.value(in: 88...89.9)
                : random.value(in: -89.9...(-88))
            return GeoPoint(latitude: latitude, longitude: random.value(in: -180...179.999))
        default:
            return GeoPoint(
                latitude: random.value(in: -88...88),
                longitude: random.value(in: -180...179.999)
            )
        }
    }
}

/// A small pseudo-random generator with a fixed seed, so the test data is the
/// same on every run.
private struct TestRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }

    /// A value in 0..<1.
    mutating func unit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    mutating func bool() -> Bool {
        (next() >> 11) % 2 == 0
    }

    mutating func value(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + unit() * (range.upperBound - range.lowerBound)
    }
}
