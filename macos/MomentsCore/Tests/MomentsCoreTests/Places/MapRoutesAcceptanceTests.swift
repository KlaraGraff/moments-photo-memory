import Foundation
import XCTest
@testable import MomentsCore

/// Edge cases of the map's route and pin helpers, beyond the cases in the task.
final class MapRoutesAcceptanceTests: XCTestCase {
    private func cluster(_ id: String, _ latitude: Double, _ longitude: Double, stops: [String]? = nil, day: Double = 0, name: String? = nil) -> PlaceCluster {
        PlaceCluster(
            id: id,
            level: .city,
            stopIDs: stops ?? [id + "-1"],
            center: GeoPoint(latitude: latitude, longitude: longitude),
            firstDate: Date(timeIntervalSince1970: 1_700_000_000 + day * 86_400),
            name: name
        )
    }

    private func segment(_ from: PlaceCluster, _ to: PlaceCluster) -> RouteSegment {
        RouteSegment(from: from, to: to, distanceMeters: from.center!.distance(to: to.center!))
    }

    func testTwoWayMarkIsDroppedWithItsSegment() {
        let a = cluster("A", 0, 0), b = cluster("B", 0, 1), c = cluster("C", 0, 30)
        // A<->B is short and two-way; A->C is long. A limit of 1 keeps A->C only.
        let routes = MapRoutes(segments: [segment(a, b), segment(b, a), segment(a, c)], limit: 1)
        XCTAssertEqual(routes.segments.map(\.id), ["A->C"])
        XCTAssertTrue(routes.twoWayIDs.isEmpty)
    }

    func testLimitZeroAndNegativeKeepNothing() {
        let a = cluster("A", 0, 0), b = cluster("B", 0, 1)
        XCTAssertTrue(MapRoutes(segments: [segment(a, b)], limit: 0).segments.isEmpty)
        XCTAssertTrue(MapRoutes(segments: [segment(a, b)], limit: -5).segments.isEmpty)
    }

    func testEqualDistancesKeepTheEarlierOnes() {
        let hub = cluster("H", 0, 0)
        let spokes = (1...5).map { cluster("S\($0)", 0, Double($0) * 0 + 1, stops: ["s\($0)"]) }
        let routes = MapRoutes(segments: spokes.map { segment(hub, $0) }, limit: 2)
        XCTAssertEqual(routes.segments.map(\.id), ["H->S1", "H->S2"])
    }

    func testFirstDirectionWins() {
        let a = cluster("A", 0, 0), b = cluster("B", 0, 1)
        let routes = MapRoutes(segments: [segment(b, a), segment(a, b), segment(b, a)])
        XCTAssertEqual(routes.segments.map(\.id), ["B->A"])
        XCTAssertEqual(routes.twoWayIDs, ["B->A"])
    }

    func testMergedNameOnlyWhenAllAgree() {
        let same = [cluster("A", 1, 1, name: "Rome"), cluster("B", 1.5, 1.5, day: 1, name: "Rome")]
        XCTAssertEqual(MapPinGrid.merge(same, cellDegrees: 10).first?.name, "Rome")
        let mixed = [cluster("A", 1, 1, name: "Rome"), cluster("B", 1.5, 1.5, day: 1, name: nil)]
        XCTAssertNil(MapPinGrid.merge(mixed, cellDegrees: 10).first?.name)
    }

    func testNegativeCoordinatesUseFloorCells() {
        // -0.5 and 0.5 are in different 1° cells; -0.5 and -0.9 are in the same one.
        let merged = MapPinGrid.merge([cluster("A", -0.5, 5), cluster("B", -0.9, 5.2, day: 1), cluster("C", 0.5, 5, day: 2)], cellDegrees: 1)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].stopIDs, ["A-1", "B-1"])
        XCTAssertEqual(merged[1].id, "C")
    }

    func testMergedFirstDateIsTheEarliest() {
        let merged = MapPinGrid.merge([cluster("A", 1, 1, day: 5), cluster("B", 1.2, 1.2, day: 2)], cellDegrees: 10)
        XCTAssertEqual(merged.first?.firstDate, Date(timeIntervalSince1970: 1_700_000_000 + 2 * 86_400))
    }
}
