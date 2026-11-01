import Foundation
import XCTest
@testable import MomentsCore

final class MapViewportTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Points

    func testPointInsideOutsideAndPaddingEdge() {
        let viewport = MapViewport(
            centerLatitude: 10,
            centerLongitude: 20,
            latitudeDelta: 2,
            longitudeDelta: 4
        )

        // Inside the reported region.
        XCTAssertTrue(viewport.contains(GeoPoint(latitude: 10.5, longitude: 21)))
        // Outside, even with the default half-screen padding: the region reaches
        // 2° of latitude either way and 4° of longitude either way.
        XCTAssertFalse(viewport.contains(GeoPoint(latitude: 12.1, longitude: 20)))
        XCTAssertFalse(viewport.contains(GeoPoint(latitude: 10, longitude: 24.1)))
        // On the padded edge: latitude 10 ± (1 + 1) = 8…12, longitude 20 ± (2 + 2) = 16…24.
        XCTAssertTrue(viewport.contains(GeoPoint(latitude: 12, longitude: 24)))
        XCTAssertFalse(viewport.contains(GeoPoint(latitude: 12.01, longitude: 20)))
        XCTAssertFalse(viewport.contains(GeoPoint(latitude: 10, longitude: 24.01)))
        // No padding asks only about the reported region itself.
        XCTAssertFalse(viewport.contains(GeoPoint(latitude: 12, longitude: 20), padding: 0))
        XCTAssertTrue(viewport.contains(GeoPoint(latitude: 11, longitude: 22), padding: 0))
    }

    func testCentreAt179PointAtMinus179() {
        let viewport = MapViewport(
            centerLatitude: 0,
            centerLongitude: 179.5,
            latitudeDelta: 1,
            longitudeDelta: 2
        )

        XCTAssertTrue(viewport.contains(GeoPoint(latitude: 0, longitude: -179.5)))
        XCTAssertTrue(viewport.contains(GeoPoint(latitude: 0, longitude: 179.9)))
        XCTAssertFalse(viewport.contains(GeoPoint(latitude: 0, longitude: -178), padding: 0))
    }

    func testCentreAtMinus179PointAt179() {
        let viewport = MapViewport(
            centerLatitude: 0,
            centerLongitude: -179.5,
            latitudeDelta: 1,
            longitudeDelta: 2
        )

        XCTAssertTrue(viewport.contains(GeoPoint(latitude: 0, longitude: 179.5)))
        XCTAssertTrue(viewport.contains(GeoPoint(latitude: 0, longitude: -179.9)))
        XCTAssertFalse(viewport.contains(GeoPoint(latitude: 0, longitude: 178), padding: 0))
    }

    func testSpansNearThePolesClampToThePole() {
        // A region hanging over the north pole: every latitude from 88.5° up,
        // and no latitude below it.
        let viewport = MapViewport(
            centerLatitude: 89.5,
            centerLongitude: 0,
            latitudeDelta: 1,
            longitudeDelta: 2
        )

        XCTAssertTrue(viewport.contains(GeoPoint(latitude: 90, longitude: 0)))
        XCTAssertTrue(viewport.contains(GeoPoint(latitude: 89.9, longitude: 0)))
        XCTAssertFalse(viewport.contains(GeoPoint(latitude: 78, longitude: 0)))
    }

    func testWholeWorldSpanContainsEverything() {
        let viewport = MapViewport(
            centerLatitude: 0,
            centerLongitude: 0,
            latitudeDelta: 180,
            longitudeDelta: 360
        )

        XCTAssertTrue(viewport.contains(GeoPoint(latitude: 89.9, longitude: 179.9)))
        XCTAssertTrue(viewport.contains(GeoPoint(latitude: -89.9, longitude: -179.9)))
        XCTAssertTrue(viewport.contains(GeoPoint(latitude: 0, longitude: 0)))
    }

    func testNaNAndInfiniteSpansMatchEverything() {
        let notANumber = MapViewport(
            centerLatitude: 0,
            centerLongitude: 0,
            latitudeDelta: .nan,
            longitudeDelta: .nan
        )
        let infinite = MapViewport(
            centerLatitude: 0,
            centerLongitude: 0,
            latitudeDelta: .infinity,
            longitudeDelta: .infinity
        )

        for viewport in [notANumber, infinite] {
            XCTAssertTrue(viewport.contains(GeoPoint(latitude: 80, longitude: 170)))
            XCTAssertTrue(viewport.contains(GeoPoint(latitude: -80, longitude: -170)))
            XCTAssertEqual(viewport.clusters([cluster("a", latitude: 80, longitude: 170)]).map(\.id), ["a"])
        }
    }

    // MARK: - Clusters

    func testClusterWithoutACentreIsLeftOut() {
        let viewport = MapViewport(
            centerLatitude: 0,
            centerLongitude: 0,
            latitudeDelta: 2,
            longitudeDelta: 2
        )
        let placed = cluster("placed", latitude: 0.5, longitude: 0.5)
        let placeless = PlaceCluster(
            id: "placeless",
            level: .spot,
            stopIDs: ["stop"],
            center: nil,
            firstDate: origin
        )

        XCTAssertEqual(viewport.clusters([placed, placeless]).map(\.id), ["placed"])
    }

    func testClustersKeepInputOrder() {
        let viewport = MapViewport(
            centerLatitude: 0,
            centerLongitude: 0,
            latitudeDelta: 2,
            longitudeDelta: 2
        )
        let input = [
            cluster("third", latitude: 0.3, longitude: 0.3),
            cluster("first", latitude: 0.1, longitude: 0.1),
            cluster("second", latitude: 0.2, longitude: 0.2)
        ]

        XCTAssertEqual(viewport.clusters(input).map(\.id), ["third", "first", "second"])
        XCTAssertTrue(viewport.clusters([]).isEmpty)
    }

    // MARK: - Segments

    func testSegmentCrossingTheRegionIsKept() {
        let viewport = MapViewport(
            centerLatitude: 0,
            centerLongitude: 0,
            latitudeDelta: 2,
            longitudeDelta: 2
        )
        // Both ends are off screen, but the line between them crosses it.
        let crossing = segment(
            from: cluster("west", latitude: 0, longitude: -5),
            to: cluster("east", latitude: 0, longitude: 5)
        )
        // A segment far to the north never touches the region.
        let elsewhere = segment(
            from: cluster("north-west", latitude: 30, longitude: -5),
            to: cluster("north-east", latitude: 30, longitude: 5)
        )

        XCTAssertEqual(viewport.segments([crossing, elsewhere]), [crossing])
        XCTAssertEqual(viewport.segments([crossing, elsewhere], padding: 0), [crossing])
    }

    func testSegmentAcrossTheAntimeridianIsKept() {
        let viewport = MapViewport(
            centerLatitude: 0,
            centerLongitude: 179,
            latitudeDelta: 2,
            longitudeDelta: 4
        )
        // Both ends are within 3° of the centre the short way round.
        let crossing = segment(
            from: cluster("east", latitude: 0, longitude: 178),
            to: cluster("west", latitude: 0, longitude: -178)
        )
        // The same two numbers taken the long way round: a centre at 0° does
        // not see that line, because the short path runs over the antimeridian.
        let away = MapViewport(
            centerLatitude: 0,
            centerLongitude: 0,
            latitudeDelta: 2,
            longitudeDelta: 4
        )

        XCTAssertEqual(viewport.segments([crossing]), [crossing])
        XCTAssertTrue(away.segments([crossing]).isEmpty)
    }

    func testSegmentWithoutACentreIsLeftOut() {
        let viewport = MapViewport(
            centerLatitude: 0,
            centerLongitude: 0,
            latitudeDelta: 2,
            longitudeDelta: 2
        )
        let placeless = PlaceCluster(
            id: "placeless",
            level: .spot,
            stopIDs: ["stop"],
            center: nil,
            firstDate: origin
        )
        let placed = cluster("placed", latitude: 0, longitude: 0)

        XCTAssertTrue(viewport.segments([segment(from: placed, to: placeless)]).isEmpty)
        XCTAssertTrue(viewport.segments([segment(from: placeless, to: placed)]).isEmpty)
    }

    func testSegmentsKeepInputOrderAndEmptyInput() {
        let viewport = MapViewport(
            centerLatitude: 0,
            centerLongitude: 0,
            latitudeDelta: 2,
            longitudeDelta: 2
        )
        let a = cluster("a", latitude: 0, longitude: 0)
        let b = cluster("b", latitude: 0.5, longitude: 0.5)
        let c = cluster("c", latitude: 0.6, longitude: 0.6)
        let input = [
            segment(from: b, to: c),
            segment(from: a, to: b)
        ]

        XCTAssertEqual(viewport.segments(input), input)
        XCTAssertTrue(viewport.segments([]).isEmpty)
    }

    // MARK: - Helpers

    private func cluster(_ id: String, latitude: Double, longitude: Double) -> PlaceCluster {
        PlaceCluster(
            id: id,
            level: .spot,
            stopIDs: ["\(id)-stop"],
            center: GeoPoint(latitude: latitude, longitude: longitude),
            firstDate: origin
        )
    }

    private func segment(from: PlaceCluster, to: PlaceCluster) -> RouteSegment {
        RouteSegment(
            from: from,
            to: to,
            fromStopID: "\(from.id)-stop",
            toStopID: "\(to.id)-stop",
            distanceMeters: 1_000
        )
    }
}
