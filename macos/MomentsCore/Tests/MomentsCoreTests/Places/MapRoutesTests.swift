import Foundation
import XCTest
@testable import MomentsCore

final class MapRoutesTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    func testRepeatedMovesBecomeOneLine() {
        let a = cluster("A")
        let b = cluster("B")
        let hops = [
            segment(a, b, meters: 1_000),
            segment(b, a, meters: 1_000),
            segment(a, b, meters: 1_000),
            segment(b, a, meters: 1_000)
        ]

        let routes = MapRoutes(segments: hops)

        XCTAssertEqual(routes.segments.count, 1)
        XCTAssertEqual(routes.segments[0].id, "A->B")
        XCTAssertEqual(routes.segments[0].from.id, "A")
        XCTAssertEqual(routes.segments[0].to.id, "B")
        XCTAssertEqual(routes.twoWayIDs, ["A->B"])
    }

    func testOneWayStaysOneWay() {
        let a = cluster("A")
        let b = cluster("B")
        let c = cluster("C")
        let triangle = [
            segment(a, b, meters: 1_000),
            segment(b, c, meters: 1_000),
            segment(c, a, meters: 1_000)
        ]

        let routes = MapRoutes(segments: triangle)

        XCTAssertEqual(routes.segments.map(\.id), ["A->B", "B->C", "C->A"])
        XCTAssertTrue(routes.twoWayIDs.isEmpty)
    }

    func testIdsAreUnique() {
        let places = [cluster("A"), cluster("B"), cluster("C"), cluster("D")]
        var pairs: [(PlaceCluster, PlaceCluster)] = []
        for first in places.indices {
            for second in places.indices where first != second {
                pairs.append((places[first], places[second]))
            }
        }
        var hops: [RouteSegment] = []
        for index in 0..<300 {
            let pair = pairs[index % pairs.count]
            hops.append(segment(pair.0, pair.1, meters: Double(index + 1)))
        }

        let routes = MapRoutes(segments: hops)

        XCTAssertLessThanOrEqual(routes.segments.count, 6)
        XCTAssertEqual(Set(routes.segments.map(\.id)).count, routes.segments.count)
    }

    func testLimitKeepsTheLongestInTimeOrder() {
        let places = (0..<5).map { cluster("place-\($0)") }
        var hops: [RouteSegment] = []
        var distance = 10.0
        for first in 0..<places.count {
            for second in (first + 1)..<places.count {
                hops.append(segment(places[first], places[second], meters: distance))
                distance += 10
            }
        }

        let routes = MapRoutes(segments: hops, limit: 3)

        XCTAssertEqual(routes.segments.count, 3)
        XCTAssertEqual(routes.segments.map(\.distanceMeters), [80, 90, 100])
        XCTAssertEqual(routes.segments.map(\.id), ["place-2->place-3", "place-2->place-4", "place-3->place-4"])
    }

    func testEmptyInput() {
        let routes = MapRoutes(segments: [])

        XCTAssertTrue(routes.segments.isEmpty)
        XCTAssertTrue(routes.twoWayIDs.isEmpty)
    }

    // MARK: - longest

    func testLongestKeepsInputOrder() {
        let places = [cluster("A"), cluster("B"), cluster("C"), cluster("D")]
        // Distances run out of order against the input order.
        let hops = [
            segment(places[0], places[1], meters: 30),
            segment(places[1], places[2], meters: 100),
            segment(places[2], places[3], meters: 50),
            segment(places[0], places[3], meters: 80)
        ]

        let kept = MapRoutes.longest(hops, limit: 2)

        XCTAssertEqual(kept.map(\.id), ["B->C", "A->D"])
        XCTAssertEqual(kept.map(\.distanceMeters), [100, 80])
    }

    func testLongestBreaksTiesWithTheLowerIndex() {
        let places = [cluster("A"), cluster("B"), cluster("C"), cluster("D")]
        let hops = [
            segment(places[0], places[1], meters: 50),
            segment(places[1], places[2], meters: 90),
            segment(places[2], places[3], meters: 90),
            segment(places[0], places[3], meters: 90)
        ]

        let kept = MapRoutes.longest(hops, limit: 2)

        XCTAssertEqual(kept.map(\.id), ["B->C", "C->D"])
    }

    func testLongestLimitZeroAndLimitBeyondCount() {
        let places = [cluster("A"), cluster("B"), cluster("C")]
        let hops = [
            segment(places[0], places[1], meters: 10),
            segment(places[1], places[2], meters: 20)
        ]

        XCTAssertTrue(MapRoutes.longest(hops, limit: 0).isEmpty)
        XCTAssertEqual(MapRoutes.longest(hops, limit: 10).map(\.id), ["A->B", "B->C"])
        XCTAssertTrue(MapRoutes.longest([], limit: 5).isEmpty)
    }

    func testInitMatchesLongestAfterDeduplication() {
        let places = [cluster("A"), cluster("B"), cluster("C"), cluster("D")]
        let hops = [
            segment(places[0], places[1], meters: 10),
            segment(places[1], places[0], meters: 10),
            segment(places[1], places[2], meters: 90),
            segment(places[2], places[3], meters: 40),
            segment(places[0], places[3], meters: 70),
            segment(places[3], places[0], meters: 70),
            segment(places[0], places[2], meters: 20)
        ]

        let routes = MapRoutes(segments: hops, limit: 3)
        // The same list without the repeated pairs, longest three kept.
        let deduplicated = MapRoutes(segments: hops, limit: .max).segments

        XCTAssertEqual(routes.segments.map(\.id), MapRoutes.longest(deduplicated, limit: 3).map(\.id))
        XCTAssertEqual(routes.segments.map(\.id), ["B->C", "C->D", "A->D"])
        XCTAssertEqual(Set(routes.segments.map(\.id)).count, routes.segments.count)
    }

    private func cluster(_ id: String) -> PlaceCluster {
        PlaceCluster(
            id: id,
            level: .city,
            stopIDs: ["\(id)-stop"],
            center: GeoPoint(latitude: 0, longitude: 0),
            firstDate: origin
        )
    }

    private func segment(_ from: PlaceCluster, _ to: PlaceCluster, meters: Double) -> RouteSegment {
        RouteSegment(
            from: from,
            to: to,
            fromStopID: "\(from.id)-stop",
            toStopID: "\(to.id)-stop",
            distanceMeters: meters
        )
    }
}
