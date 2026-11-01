import Foundation
import XCTest
@testable import MomentsCore

final class GeoPointEdgeCaseTests: XCTestCase {
    func testLatitudeIsClampedToTheValidRange() {
        XCTAssertEqual(point(100, 0).latitude, 90, accuracy: 1e-12)
        XCTAssertEqual(point(-100, 0).latitude, -90, accuracy: 1e-12)
        XCTAssertEqual(point(45, 0).latitude, 45, accuracy: 1e-12)
        XCTAssertEqual(point(90, 0).latitude, 90, accuracy: 1e-12)
        XCTAssertEqual(point(-90, 0).latitude, -90, accuracy: 1e-12)
    }

    func testNonFiniteCoordinatesBecomeZero() {
        let nonFinite: [Double] = [.nan, .infinity, -.infinity, .signalingNaN]

        for value in nonFinite {
            let latitudeOnly = point(value, 0)
            XCTAssertEqual(latitudeOnly.latitude, 0, "latitude \(value) should be 0")
            XCTAssertTrue(latitudeOnly.latitude.isFinite)

            let longitudeOnly = point(0, value)
            XCTAssertEqual(longitudeOnly.longitude, 0, "longitude \(value) should be 0")
            XCTAssertTrue(longitudeOnly.longitude.isFinite)
        }

        let both = GeoPoint(latitude: .nan, longitude: .infinity)
        XCTAssertEqual(both.latitude, 0)
        XCTAssertEqual(both.longitude, 0)
    }

    func testLongitudeWrapsIntoTheValidRange() {
        XCTAssertEqual(point(0, 190).longitude, -170, accuracy: 1e-9)
        XCTAssertEqual(point(0, -190).longitude, 170, accuracy: 1e-9)
        XCTAssertEqual(point(0, 360).longitude, 0, accuracy: 1e-9)
        XCTAssertEqual(point(0, 180).longitude, 180, accuracy: 1e-9)
        XCTAssertEqual(point(0, -180).longitude, -180, accuracy: 1e-9)
        XCTAssertGreaterThan(point(0, 180).longitude, 0)
        XCTAssertLessThan(point(0, -180).longitude, 0)
    }

    func testDistanceIsZeroToItselfSymmetricAndMatchesKnownCityPairs() {
        let berlin = point(52.52, 13.40)
        let paris = point(48.85, 2.35)

        XCTAssertEqual(berlin.distance(to: berlin), 0, accuracy: 1e-9)
        XCTAssertEqual(paris.distance(to: paris), 0, accuracy: 1e-9)

        let there = berlin.distance(to: paris)
        let back = paris.distance(to: berlin)
        XCTAssertEqual(there, back, accuracy: 1e-6)

        XCTAssertEqual(there / 1_000, 878, accuracy: 5)
    }

    func testDistanceAcrossTheAntimeridianTakesTheShortPath() {
        let west = point(0, 179.9)
        let east = point(0, -179.9)

        let kilometres = west.distance(to: east) / 1_000
        XCTAssertEqual(kilometres, 22.2, accuracy: 0.5)
        XCTAssertEqual(east.distance(to: west) / 1_000, 22.2, accuracy: 0.5)
    }

    func testCentreHandlesEmptySingleAndAntimeridianGroups() {
        XCTAssertNil(GeoPoint.centre(of: []))

        let only = point(12.5, -45.25)
        guard let single = GeoPoint.centre(of: [only]) else {
            return XCTFail("a single point must have a centre")
        }
        XCTAssertEqual(single.latitude, only.latitude, accuracy: 1e-9)
        XCTAssertEqual(single.longitude, only.longitude, accuracy: 1e-9)

        guard let acrossTheDateLine = GeoPoint.centre(of: [point(0, 179), point(0, -179)]) else {
            return XCTFail("two points must have a centre")
        }
        XCTAssertEqual(acrossTheDateLine.latitude, 0, accuracy: 1e-6)
        XCTAssertEqual(abs(acrossTheDateLine.longitude), 180, accuracy: 1e-6)
        XCTAssertGreaterThan(abs(acrossTheDateLine.longitude), 179)
    }

    private func point(_ latitude: Double, _ longitude: Double) -> GeoPoint {
        GeoPoint(latitude: latitude, longitude: longitude)
    }
}
