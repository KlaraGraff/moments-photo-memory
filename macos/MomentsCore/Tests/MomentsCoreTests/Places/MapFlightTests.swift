import Foundation
import XCTest
@testable import MomentsCore

final class MapFlightTests: XCTestCase {
    /// The flight sampled 60 times a second, ending exactly on its end.
    private func frames(_ flight: MapFlight) -> [MapFlightCamera] {
        let count: Int = max(1, Int((flight.duration * 60).rounded(.up)))
        return (1...count).map { index in
            flight.camera(at: flight.duration * Double(index) / Double(count))
        }
    }

    private let globe = MapFlightCamera(latitude: 20, longitude: 0, distance: 20_000_000)
    private let city = MapFlightCamera(latitude: 48.85, longitude: 2.35, distance: 8_000)
    private let farCity = MapFlightCamera(latitude: 35.6, longitude: 139.7, distance: 8_000)

    // MARK: - Ends

    func testStartsAndEndsExactlyOnTheTwoViews() {
        let flight = MapFlight(from: globe, to: city)
        XCTAssertEqual(flight.camera(at: 0), globe)
        XCTAssertEqual(flight.camera(at: flight.duration), city)
        XCTAssertEqual(flight.camera(at: flight.duration + 5), city)
        XCTAssertEqual(frames(flight).last, city)
    }

    func testSameViewIsAShortStill() {
        let flight = MapFlight(from: city, to: city)
        XCTAssertEqual(flight.pathLength, 0, accuracy: 1e-9)
        XCTAssertEqual(flight.duration, MapFlight.shortestDuration, accuracy: 1e-9)
        let middle: MapFlightCamera = flight.camera(at: flight.duration / 2)
        XCTAssertEqual(middle.distance, city.distance, accuracy: 1e-6)
        XCTAssertEqual(middle.latitude, city.latitude, accuracy: 1e-9)
    }

    // MARK: - Zoom feels even and eases in and out

    /// The reported problem: with the distance moving evenly in metres, the
    /// last tenth of the time held almost every zoom level. Now each tenth
    /// holds a modest share, the middle the most, the ends the least.
    func testZoomLevelsAreSpreadOverTheWholeFlight() {
        let flight = MapFlight(from: globe, to: city)
        let steps: Int = 10
        var shares: [Double] = []
        let total: Double = log(globe.distance / city.distance)
        for index in 0..<steps {
            let from: Double = flight.duration * Double(index) / Double(steps)
            let to: Double = flight.duration * Double(index + 1) / Double(steps)
            let before: Double = flight.camera(at: from).distance
            let after: Double = flight.camera(at: to).distance
            shares.append(log(before / after) / total)
        }
        for share in shares {
            XCTAssertGreaterThanOrEqual(share, -0.001, "The camera went the wrong way: \(shares)")
            XCTAssertLessThan(share, 0.2, "One tenth of the time does too much of the zoom: \(shares)")
        }
        let first: Double = shares[0]
        let middle: Double = shares[4] + shares[5]
        let last: Double = shares[9]
        XCTAssertLessThan(first, 0.05, "It should start slowly: \(shares)")
        XCTAssertLessThan(last, 0.05, "It should settle slowly: \(shares)")
        XCTAssertGreaterThan(middle, 0.25, "It should be fastest in the middle: \(shares)")
    }

    /// What the old move did, for comparison: with the distance eased evenly
    /// in metres, the last tenth of the time held about half of the zoom.
    func testEvenMetresWouldCrowdTheZoomIntoTheEnd() {
        let total: Double = log(globe.distance / city.distance)
        let eased: Double = MapFlight.eased(0.9)
        let atNinetyPercent: Double = globe.distance + (city.distance - globe.distance) * eased
        let lastTenth: Double = log(atNinetyPercent / city.distance) / total
        XCTAssertGreaterThan(lastTenth, 0.4)
    }

    func testEasingIsSlowAtBothEndsAndFastInTheMiddle() {
        XCTAssertEqual(MapFlight.eased(0), 0, accuracy: 1e-12)
        XCTAssertEqual(MapFlight.eased(1), 1, accuracy: 1e-12)
        XCTAssertEqual(MapFlight.eased(0.5), 0.5, accuracy: 1e-12)
        let startStep: Double = MapFlight.eased(0.05) - MapFlight.eased(0)
        let middleStep: Double = MapFlight.eased(0.525) - MapFlight.eased(0.475)
        let endStep: Double = MapFlight.eased(1) - MapFlight.eased(0.95)
        XCTAssertLessThan(startStep * 5, middleStep)
        XCTAssertLessThan(endStep * 5, middleStep)
    }

    // MARK: - Long hops rise out, short ones stay low

    func testFarHopRisesOutToSeeBothEnds() {
        let flight = MapFlight(from: city, to: farCity, distanceCeiling: 20_000_000)
        let highest: Double = frames(flight).map(\.distance).max() ?? 0
        XCTAssertGreaterThan(highest, 5_000_000, "Paris to Tokyo should rise to see both")
        XCTAssertLessThanOrEqual(highest, 20_000_000, "Never above the ceiling")
        XCTAssertEqual(flight.duration, MapFlight.longestDuration, accuracy: 1e-9)
    }

    func testNearHopRisesOnlyALittle() {
        let start = MapFlightCamera(latitude: 48.85, longitude: 2.35, distance: 8_000)
        let end = MapFlightCamera(latitude: 48.86, longitude: 2.37, distance: 8_000)
        let flight = MapFlight(from: start, to: end)
        let highest: Double = frames(flight).map(\.distance).max() ?? 0
        XCTAssertLessThan(highest, 16_000)
        XCTAssertLessThan(flight.duration, 1.0)
    }

    func testCentreMovesSteadilyTowardTheTarget() {
        let flight = MapFlight(from: city, to: farCity, distanceCeiling: 20_000_000)
        var previous: Double = city.longitude
        for frame in frames(flight) {
            XCTAssertGreaterThanOrEqual(frame.longitude, previous - 1e-9)
            XCTAssertLessThanOrEqual(frame.longitude, farCity.longitude + 1e-9)
            previous = frame.longitude
        }
    }

    // MARK: - Frames

    func testFramesAreSmallSteps() {
        let flight = MapFlight(from: globe, to: city)
        let cameras: [MapFlightCamera] = [globe] + frames(flight)
        var largest: Double = 0
        for index in 1..<cameras.count {
            let ratio: Double = abs(log(cameras[index].distance / cameras[index - 1].distance))
            largest = max(largest, ratio)
        }
        // No single sixtieth of a second may zoom by more than about 25 %.
        XCTAssertLessThan(largest, log(1.25))
    }

    /// "Zoom to photos" on one city, then "Whole world": the two centres are
    /// a few metres apart, where the paper's formula lost every digit.
    func testRisingFromACloseViewToANearbyCentreStaysFinite() {
        for offset in [0.5, 2.0, 20.0, 128.0, 500.0, 5_000.0] {
            let close = MapFlightCamera(latitude: 20, longitude: offset / 111_320 / cos(20 * Double.pi / 180), distance: 6_232)
            let flight = MapFlight(from: close, to: globe, distanceCeiling: 20_000_000)
            var previous: Double = close.distance
            for frame in frames(flight) {
                XCTAssertTrue(frame.distance.isFinite && frame.latitude.isFinite && frame.longitude.isFinite, "Offset \(offset) m gave \(frame)")
                XCTAssertGreaterThanOrEqual(frame.distance, previous * 0.999, "Offset \(offset) m: the camera came down on the way out")
                previous = frame.distance
            }
            XCTAssertEqual(frames(flight).last, globe)
            XCTAssertGreaterThan(flight.duration, 1.0, "Offset \(offset) m: the flight lost its length")
        }
    }

    func testExtremeViewsStayFinite() {
        let cameras: [MapFlightCamera] = [
            MapFlightCamera(latitude: 90, longitude: 180, distance: 1),
            MapFlightCamera(latitude: -90, longitude: -180, distance: 100_000_000),
            MapFlightCamera(latitude: 0, longitude: 0, distance: 1),
            MapFlightCamera(latitude: 0, longitude: 0.000001, distance: 100_000_000),
            city,
            globe,
        ]
        for start in cameras {
            for end in cameras {
                let flight = MapFlight(from: start, to: end, distanceCeiling: 20_000_000)
                XCTAssertTrue(flight.duration.isFinite)
                for frame in frames(flight) {
                    XCTAssertTrue(frame.distance.isFinite && frame.distance > 0, "\(start) → \(end) gave \(frame)")
                    XCTAssertTrue(frame.latitude.isFinite && frame.longitude.isFinite, "\(start) → \(end) gave \(frame)")
                }
            }
        }
    }

    func testDurationGrowsWithThePath() {
        let short = MapFlight(
            from: city,
            to: MapFlightCamera(latitude: 48.85, longitude: 2.35, distance: 16_000)
        )
        let long = MapFlight(from: globe, to: city)
        XCTAssertLessThan(short.duration, long.duration)
        XCTAssertGreaterThanOrEqual(short.duration, MapFlight.shortestDuration)
        XCTAssertLessThanOrEqual(long.duration, MapFlight.longestDuration)
    }

    // MARK: - Heading, longitude and regions

    func testHeadingTurnsTheShortWayRound() {
        let turned = MapFlightCamera(latitude: 48.85, longitude: 2.35, distance: 8_000, heading: 350)
        let flight = MapFlight(from: turned, to: city)
        let middle: MapFlightCamera = flight.camera(at: flight.duration / 2)
        XCTAssertEqual(middle.heading, 355, accuracy: 1e-6)
    }

    func testLongitudeIsNormalisedAndNeverWraps() {
        let east = MapFlightCamera(latitude: 0, longitude: 190, distance: 1_000_000)
        let west = MapFlightCamera(latitude: 0, longitude: -170, distance: 1_000_000)
        let flight = MapFlight(from: east, to: MapFlightCamera(latitude: 0, longitude: 170, distance: 1_000_000))
        XCTAssertEqual(flight.start.longitude, west.longitude, accuracy: 1e-9)
        for frame in frames(flight) {
            XCTAssertGreaterThanOrEqual(frame.longitude, -170 - 1e-9)
            XCTAssertLessThanOrEqual(frame.longitude, 170 + 1e-9)
        }
    }

    func testRegionDistanceFitsTheTighterDirection() {
        // A 1° tall region in a square map: 111 km of ground fills 30°.
        let square: Double = MapFlight.distance(fittingLatitudeDelta: 1, longitudeDelta: 0.1, at: 0, width: 800, height: 800)
        XCTAssertEqual(square * MapFlight.visibleHeightPerMetre, 111_320, accuracy: 1)
        // A wide region in a short, wide map is fitted by its width.
        let wide: Double = MapFlight.distance(fittingLatitudeDelta: 0.1, longitudeDelta: 4, at: 60, width: 1_000, height: 500)
        let expectedHeight: Double = 4 * 111_320 * 0.5 * 0.5
        XCTAssertEqual(wide * MapFlight.visibleHeightPerMetre, expectedHeight, accuracy: 1)
    }
}
