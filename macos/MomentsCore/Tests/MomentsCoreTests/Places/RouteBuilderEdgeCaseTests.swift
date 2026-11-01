import Foundation
import XCTest
@testable import MomentsCore

final class RouteBuilderEdgeCaseTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    func testNoStopsOrASingleClusterGiveNoSegments() {
        XCTAssertTrue(RouteBuilder().overview(level: .city).isEmpty)
        XCTAssertTrue(RouteBuilder().local(level: .spot).isEmpty)

        let together = [
            stop("a", hours: 0, latitude: 10, longitude: 10),
            stop("b", hours: 1, latitude: 10, longitude: 10.001)
        ]
        XCTAssertEqual(PlaceClusterer().clusters(for: together, level: .spot).count, 1)
        XCTAssertTrue(RouteBuilder(stops: together).local(level: .spot).isEmpty)
        XCTAssertTrue(RouteBuilder(stops: together).overview(level: .city).isEmpty)
        XCTAssertTrue(RouteBuilder(stops: [stop("only", hours: 0, latitude: 10, longitude: 10)])
            .overview(level: .city).isEmpty)
    }

    func testReturningToAStartGivesTwoSegments() {
        // Three places far enough apart to be separate city clusters.
        let a = (latitude: 40.0, longitude: -74.0)
        let b = (latitude: 51.5, longitude: -0.12)
        let stops = [
            stop("a-1", hours: 0, latitude: a.latitude, longitude: a.longitude),
            stop("b-1", hours: 1, latitude: b.latitude, longitude: b.longitude),
            stop("a-2", hours: 2, latitude: a.latitude, longitude: a.longitude)
        ]

        let clusters = PlaceClusterer().clusters(for: stops, level: .city)
        XCTAssertEqual(clusters.count, 2)

        let segments = RouteBuilder(stops: stops).overview(level: .city)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.map(\.id), ["city-a-1->city-b-1", "city-b-1->city-a-1"])
        XCTAssertEqual(segments[0].from.id, "city-a-1")
        XCTAssertEqual(segments[0].to.id, "city-b-1")
        XCTAssertEqual(segments[1].from.id, "city-b-1")
        XCTAssertEqual(segments[1].to.id, "city-a-1")
        XCTAssertEqual(segments[1].id, "\(segments[1].from.id)->\(segments[1].to.id)")
    }

    func testConsecutivePhotosInOneClusterCountAsOneVisit() {
        let a = (latitude: 10.0, longitude: 10.0)
        let b = (latitude: 20.0, longitude: 20.0)
        let stops = [
            stop("a-1", hours: 0, latitude: a.latitude, longitude: a.longitude),
            stop("a-2", hours: 1, latitude: a.latitude, longitude: a.longitude),
            stop("b-1", hours: 2, latitude: b.latitude, longitude: b.longitude),
            stop("b-2", hours: 3, latitude: b.latitude, longitude: b.longitude)
        ]

        let segments = RouteBuilder(stops: stops).overview(level: .city)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].from.id, "city-a-1")
        XCTAssertEqual(segments[0].to.id, "city-b-1")
        // The visit is summarised by its last A photo and its first B photo.
        XCTAssertEqual(segments[0].fromStopID, "a-2")
        XCTAssertEqual(segments[0].toStopID, "b-1")
        XCTAssertEqual(segments[0].from.stopIDs, ["a-1", "a-2"])
        XCTAssertEqual(segments[0].to.stopIDs, ["b-1", "b-2"])
    }

    func testSegmentDistanceRunsFromTheLastFromStopToTheFirstToStop() {
        // Each visit holds two photos at slightly different coordinates, so the
        // measured pair (a-2, b-1) is distinguishable from the other combinations.
        let aFirst = GeoPoint(latitude: 10.000, longitude: 10.000)
        let aLast = GeoPoint(latitude: 10.010, longitude: 10.010)
        let bFirst = GeoPoint(latitude: 20.000, longitude: 20.000)
        let bLast = GeoPoint(latitude: 20.010, longitude: 20.010)
        let stops = [
            stop("a-1", hours: 0, coordinate: aFirst),
            stop("a-2", hours: 1, coordinate: aLast),
            stop("b-1", hours: 2, coordinate: bFirst),
            stop("b-2", hours: 3, coordinate: bLast)
        ]

        let clusters = PlaceClusterer().clusters(for: stops, level: .city)
        XCTAssertEqual(clusters.count, 2)

        let segments = RouteBuilder(stops: stops).overview(level: .city)
        XCTAssertEqual(segments.count, 1)

        let expected = aLast.distance(to: bFirst)
        XCTAssertEqual(segments[0].distanceMeters, expected, accuracy: 1e-6)
        XCTAssertEqual(segments[0].distanceKilometers, expected / 1_000, accuracy: 1e-9)
        XCTAssertGreaterThan(segments[0].distanceKilometers, 1_000)
        // From the last A photo to the first B photo, not from a-1 or to b-2.
        XCTAssertEqual(segments[0].fromStopID, "a-2")
        XCTAssertEqual(segments[0].toStopID, "b-1")
        XCTAssertNotEqual(segments[0].distanceMeters, aFirst.distance(to: bFirst), accuracy: 1e-6)
        XCTAssertNotEqual(segments[0].distanceMeters, aLast.distance(to: bLast), accuracy: 1e-6)
    }

    func testNegativeSegmentDistanceIsClampedToZero() {
        let from = PlaceCluster(
            id: "from",
            level: .city,
            stopIDs: ["from-stop"],
            center: nil,
            firstDate: origin
        )
        let to = PlaceCluster(
            id: "to",
            level: .city,
            stopIDs: ["to-stop"],
            center: nil,
            firstDate: origin.addingTimeInterval(3_600)
        )

        let negative = RouteSegment(from: from, to: to, distanceMeters: -5)
        XCTAssertEqual(negative.distanceMeters, 0)
        XCTAssertEqual(negative.distanceKilometers, 0)
        XCTAssertEqual(negative.id, "from->to")

        let positive = RouteSegment(from: from, to: to, distanceMeters: 5)
        XCTAssertEqual(positive.distanceMeters, 5)
        XCTAssertEqual(positive.distanceKilometers, 0.005)
    }

    func testStopsWithoutCoordinateAreSkipped() {
        let a = (latitude: 10.0, longitude: 10.0)
        let b = (latitude: 20.0, longitude: 20.0)
        let located = [
            stop("a", hours: 0, latitude: a.latitude, longitude: a.longitude),
            stop("b", hours: 1, latitude: b.latitude, longitude: b.longitude)
        ]
        let missing = [
            stop("gap-0", hours: 0, coordinate: nil),
            stop("gap-1", hours: 2, coordinate: nil)
        ]

        let withGaps = RouteBuilder(stops: missing + located).overview(level: .city)
        XCTAssertEqual(withGaps.count, 1)
        XCTAssertEqual(withGaps[0].from.id, "city-a")
        XCTAssertEqual(withGaps[0].to.id, "city-b")
        XCTAssertEqual(withGaps[0].fromStopID, "a")
        XCTAssertEqual(withGaps[0].toStopID, "b")

        // Missing coordinates alone never produce a segment.
        XCTAssertTrue(RouteBuilder(stops: missing).overview(level: .city).isEmpty)
        XCTAssertTrue(RouteBuilder(stops: missing).local(level: .spot).isEmpty)
    }

    func testOverviewUsesCityLevelAndLocalUsesSpotLevel() {
        // 0.045 degrees of longitude on the equator is about 5 km.
        let stops = [
            stop("near", hours: 0, latitude: 0, longitude: 0),
            stop("far", hours: 1, latitude: 0, longitude: 0.045)
        ]

        guard let first = stops[0].coordinate, let second = stops[1].coordinate else {
            return XCTFail("both stops need a coordinate")
        }
        let distance = first.distance(to: second)
        XCTAssertEqual(distance / 1_000, 5, accuracy: 0.2)

        // City level merges the pair (25 km radius), so the overview has no segment.
        XCTAssertEqual(PlaceClusterer().clusters(for: stops, level: .city).count, 1)
        XCTAssertTrue(RouteBuilder(stops: stops).overview().isEmpty)

        // Spot level splits them (1.5 km radius), so the local route has one segment.
        XCTAssertEqual(PlaceClusterer().clusters(for: stops, level: .spot).count, 2)
        let local = RouteBuilder(stops: stops).local()
        XCTAssertEqual(local.count, 1)
        XCTAssertEqual(local[0].id, "spot-near->spot-far")
        XCTAssertEqual(local[0].distanceMeters, distance, accuracy: 1e-6)
    }

    private func stop(_ id: String, hours: TimeInterval, coordinate: GeoPoint?) -> PhotoStop {
        PhotoStop(
            id: id,
            date: origin.addingTimeInterval(hours * 60 * 60),
            coordinate: coordinate
        )
    }

    private func stop(_ id: String, hours: TimeInterval, latitude: Double, longitude: Double) -> PhotoStop {
        stop(id, hours: hours, coordinate: GeoPoint(latitude: latitude, longitude: longitude))
    }
}
