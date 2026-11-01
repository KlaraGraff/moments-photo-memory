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

    func testSegmentKeptWhenOnlyTheGreatCircleBendCrossesTheRegion() {
        // Sydney to Santiago: both ends lie at about 33° south, but the drawn
        // great circle bends south over the Pacific and crosses this view.
        let viewport = MapViewport(
            centerLatitude: -61.8,
            centerLongitude: -139.4,
            latitudeDelta: 4,
            longitudeDelta: 10
        )
        let sydney = cluster("sydney", latitude: -33.87, longitude: 151.21)
        let santiago = cluster("santiago", latitude: -33.45, longitude: -70.67)
        let crossing = segment(from: sydney, to: santiago)

        XCTAssertEqual(viewport.segments([crossing]), [crossing])
    }

    func testGreatCircleRouteIsKeptForSmallerViews() {
        // The same route and an almost identical centre, with smaller views:
        // the centre lies halfway between two great-circle samples, so a view
        // narrower than the gap between samples still has to keep the route.
        let sydney = cluster("sydney", latitude: -33.87, longitude: 151.21)
        let santiago = cluster("santiago", latitude: -33.45, longitude: -70.67)
        let crossing = segment(from: sydney, to: santiago)
        let deltas: [(latitude: Double, longitude: Double)] = [
            (4, 10),
            (2, 4),
            (1, 2),
            (0.5, 1)
        ]

        for delta in deltas {
            let viewport = MapViewport(
                centerLatitude: -61.78,
                centerLongitude: -139.36,
                latitudeDelta: delta.latitude,
                longitudeDelta: delta.longitude
            )
            XCTAssertEqual(
                viewport.segments([crossing]),
                [crossing],
                "route dropped for latitudeDelta \(delta.latitude), longitudeDelta \(delta.longitude)"
            )
        }
    }

    func testGreatCircleRouteIsNotKeptByAViewAwayFromTheArc() {
        // The same long route, with the view on the equator: the great circle
        // between Sydney and Santiago never comes near it.
        let viewport = MapViewport(
            centerLatitude: 10,
            centerLongitude: 0,
            latitudeDelta: 4,
            longitudeDelta: 10
        )
        let sydney = cluster("sydney", latitude: -33.87, longitude: 151.21)
        let santiago = cluster("santiago", latitude: -33.45, longitude: -70.67)
        let crossing = segment(from: sydney, to: santiago)

        XCTAssertTrue(viewport.segments([crossing]).isEmpty)
    }

    func testShortRouteAwayFromTheRegionIsNotKept() {
        // The great circle from (10, 0) to (10, 20) bends slightly north,
        // nowhere near a view at 40° south.
        let viewport = MapViewport(
            centerLatitude: -40,
            centerLongitude: 10,
            latitudeDelta: 4,
            longitudeDelta: 4
        )
        let west = cluster("west", latitude: 10, longitude: 0)
        let east = cluster("east", latitude: 10, longitude: 20)
        let away = segment(from: west, to: east)

        XCTAssertTrue(viewport.segments([away]).isEmpty)
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

    // MARK: - Wide views

    /// A view 200° wide is not the whole globe. With the default padding the
    /// old code reached 200° either way and kept every longitude, so pins on
    /// the far side stayed on screen.
    func testWideViewKeepsOnlyTheReportedSpan() {
        let viewport = MapViewport(
            centerLatitude: 0,
            centerLongitude: 0,
            latitudeDelta: 20,
            longitudeDelta: 200
        )

        // 170° is behind the camera: the reported view spans only ±100°.
        XCTAssertFalse(viewport.contains(GeoPoint(latitude: 0, longitude: 170)))
        // 95° is inside the reported 200° span, so the padding only widens it.
        XCTAssertTrue(viewport.contains(GeoPoint(latitude: 0, longitude: 95)))
    }

    /// Routes are culled with the same half span: a line wholly on the far
    /// side is out, one that reaches into the reported span is kept.
    func testWideViewKeepsOnlyRoutesInTheReportedSpan() {
        let viewport = MapViewport(
            centerLatitude: 0,
            centerLongitude: 0,
            latitudeDelta: 20,
            longitudeDelta: 200
        )
        let farSide: RouteSegment = segment(
            from: cluster("far-west", latitude: 0, longitude: 150),
            to: cluster("far-east", latitude: 0, longitude: 170)
        )
        let reachingIn: RouteSegment = segment(
            from: cluster("inner", latitude: 0, longitude: 80),
            to: cluster("outer", latitude: 0, longitude: 120)
        )

        XCTAssertTrue(viewport.segments([farSide]).isEmpty)
        XCTAssertEqual(viewport.segments([reachingIn]), [reachingIn])
    }
}
