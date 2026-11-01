import Foundation
import XCTest
@testable import MomentsCore

/// Checks the grid index against a full scan on the shapes real libraries
/// have: many places in one city, places on both sides of the antimeridian,
/// places near the poles, and places exactly at the distance limit.
final class NearestPlaceIndexAcceptanceTests: XCTestCase {
    func testDenseCityMatchesFullScan() {
        var random = AcceptanceRandom(seed: 99)
        let entries = (0..<2_000).map { index in
            NearestPlaceIndex.Entry(
                point: GeoPoint(latitude: 48.85 + random.signed() * 0.2, longitude: 2.35 + random.signed() * 0.2),
                name: "city-\(index)"
            )
        }
        assertMatchesScan(entries, queries: (0..<1_500).map { _ in
            GeoPoint(latitude: 48.85 + random.signed() * 0.4, longitude: 2.35 + random.signed() * 0.4)
        }, limits: [10, 150, 1_500, 100_000])
    }

    func testAntimeridianAndPolesMatchFullScan() {
        var random = AcceptanceRandom(seed: 7)
        var entries: [NearestPlaceIndex.Entry] = []
        for index in 0..<1_500 {
            let point: GeoPoint
            switch index % 3 {
            case 0: point = GeoPoint(latitude: random.signed() * 60, longitude: 179.5 + random.unit() * 1.0)
            case 1: point = GeoPoint(latitude: 89 + random.unit() * 0.99, longitude: random.signed() * 180)
            default: point = GeoPoint(latitude: -(89 + random.unit() * 0.99), longitude: random.signed() * 180)
            }
            entries.append(.init(point: point, name: "edge-\(index)"))
        }
        let queries = (0..<1_500).map { index -> GeoPoint in
            switch index % 3 {
            case 0: return GeoPoint(latitude: random.signed() * 60, longitude: index % 2 == 0 ? -179.9 : 179.9)
            case 1: return GeoPoint(latitude: 88.5 + random.unit() * 1.5, longitude: random.signed() * 180)
            default: return GeoPoint(latitude: -(88.5 + random.unit() * 1.5), longitude: random.signed() * 180)
            }
        }
        assertMatchesScan(entries, queries: queries, limits: [1_500, 100_000, 500_000, 3_000_000])
    }

    func testExactlyAtTheLimitIsFound() {
        let place = GeoPoint(latitude: 10, longitude: 20)
        let query = GeoPoint(latitude: 10, longitude: 20.5)
        let distance = query.distance(to: place)
        let index = NearestPlaceIndex(entries: [.init(point: place, name: "edge")])
        XCTAssertEqual(index.nearestName(to: query, within: distance), "edge")
        XCTAssertNil(index.nearestName(to: query, within: distance.nextDown))
    }

    func testHugeLimitStillFindsTheNearest() {
        let entries = [
            NearestPlaceIndex.Entry(point: GeoPoint(latitude: -40, longitude: 170), name: "far"),
            NearestPlaceIndex.Entry(point: GeoPoint(latitude: 40, longitude: -10), name: "near"),
        ]
        let index = NearestPlaceIndex(entries: entries)
        XCTAssertEqual(index.nearestName(to: GeoPoint(latitude: 41, longitude: -9), within: 30_000_000), "near")
        XCTAssertEqual(index.nearestName(to: GeoPoint(latitude: -41, longitude: 171), within: .greatestFiniteMagnitude), "far")
    }

    private func assertMatchesScan(_ entries: [NearestPlaceIndex.Entry], queries: [GeoPoint], limits: [Double], file: StaticString = #filePath, line: UInt = #line) {
        let index = NearestPlaceIndex(entries: entries)
        for query in queries {
            for limit in limits {
                var best: (distance: Double, name: String)?
                for entry in entries {
                    let distance = query.distance(to: entry.point)
                    if best == nil || distance < best!.distance { best = (distance, entry.name) }
                }
                let expected = best.flatMap { $0.distance <= limit ? $0.name : nil }
                let found = index.nearestName(to: query, within: limit)
                if found != expected {
                    XCTFail("query \(query) within \(limit): index \(found ?? "nil"), scan \(expected ?? "nil")", file: file, line: line)
                    return
                }
            }
        }
    }
}

private struct AcceptanceRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func signed() -> Double { unit() * 2 - 1 }
}
