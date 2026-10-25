import Foundation
import XCTest
@testable import MomentsCore

final class PlaceAndRouteTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    func testLargeScenicAreaIsOneSpot() {
        let stops = [
            stop("park-a", hours: 0, latitude: 35.000, longitude: 10.000),
            stop("park-b", hours: 1, latitude: 35.006, longitude: 10.006),
            stop("park-c", hours: 2, latitude: 35.009, longitude: 10.012)
        ]

        let spots = PlaceClusterer().clusters(for: stops, level: .spot)
        XCTAssertEqual(spots.count, 1)
        XCTAssertEqual(spots[0].stopIDs, ["park-a", "park-b", "park-c"])
    }

    func testTwoCitiesHaveOneOverviewSegment() {
        let stops = [
            stop("city-a", hours: 0, latitude: 48.8566, longitude: 2.3522),
            stop("city-a-2", hours: 1, latitude: 48.8600, longitude: 2.3600),
            stop("city-b", hours: 30, latitude: 51.5074, longitude: -0.1278)
        ]

        let segments = RouteBuilder(stops: stops).overview(level: .city)
        XCTAssertEqual(PlaceClusterer().clusters(for: stops, level: .city).count, 2)
        XCTAssertEqual(segments.count, 1)
        XCTAssertGreaterThan(segments[0].distanceMeters, 300_000)
    }

    func testReturningToCityKeepsMajorMoves() {
        let stops = [
            stop("a-1", hours: 0, latitude: 40.000, longitude: -74.000),
            stop("b", hours: 1, latitude: 41.000, longitude: -73.000),
            stop("a-2", hours: 2, latitude: 40.002, longitude: -74.002),
            stop("c", hours: 3, latitude: 42.000, longitude: -72.000)
        ]

        let segments = RouteBuilder(stops: stops).overview(level: .city)
        XCTAssertEqual(segments.map { $0.from.id }, ["city-a-1", "city-b", "city-a-1"])
        XCTAssertEqual(segments.map { $0.to.id }, ["city-b", "city-a-1", "city-c"])
    }

    func testAntimeridianUsesShortDistance() {
        let left = GeoPoint(latitude: 10, longitude: 179.8)
        let right = GeoPoint(latitude: 10, longitude: -179.8)
        XCTAssertLessThan(left.distance(to: right), 50_000)
    }

    func testEmptySingleAndMissingCoordinateInputs() {
        XCTAssertTrue(PlaceClusterer().clusters(for: [], level: .spot).isEmpty)
        let one = stop("one", hours: 0, latitude: 1, longitude: 1)
        XCTAssertEqual(PlaceClusterer().clusters(for: [one], level: .city).count, 1)
        XCTAssertTrue(RouteBuilder(stops: [one]).overview(level: .city).isEmpty)

        let missing = PhotoStop(id: "missing", date: origin)
        XCTAssertTrue(PlaceClusterer().clusters(for: [missing], level: .spot).isEmpty)
        XCTAssertTrue(RouteBuilder(stops: [missing, one]).local(level: .spot).isEmpty)
    }

    func testOverridesWinOverDistanceClustering() {
        let stops = [
            stop("one", hours: 0, latitude: 0, longitude: 0),
            stop("two", hours: 1, latitude: 0, longitude: 0.001)
        ]
        let clusterer = PlaceClusterer(overrides: ["one": "remembered-place"])
        let clusters = clusterer.clusters(for: stops, level: .spot)
        XCTAssertEqual(clusters.map(\.id), ["remembered-place", "spot-two"])
        XCTAssertEqual(clusters[0].stopIDs, ["one"])

        let duplicate = PlaceClusterer(overrides: [
            PlaceOverride(stopID: "one", clusterID: "first"),
            PlaceOverride(stopID: "one", clusterID: "second")
        ])
        XCTAssertEqual(duplicate.clusters(for: stops, level: .spot).first?.id, "second")
    }

    private func stop(_ id: String, hours: TimeInterval, latitude: Double, longitude: Double) -> PhotoStop {
        PhotoStop(
            id: id,
            date: origin.addingTimeInterval(hours * 60 * 60),
            coordinate: GeoPoint(latitude: latitude, longitude: longitude)
        )
    }
}
