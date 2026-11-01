import Foundation
import XCTest
@testable import MomentsCore

final class SyntheticLibraryTests: XCTestCase {
    private let baseDate = SyntheticLibrary.baseDate
    private let berlin = GeoPoint(latitude: 52.52, longitude: 13.40)
    private let munich = GeoPoint(latitude: 48.14, longitude: 11.58)
    private let hamburg = GeoPoint(latitude: 53.55, longitude: 9.99)
    private let auckland = GeoPoint(latitude: -36.85, longitude: 174.76)
    private let potsdam = GeoPoint(latitude: 52.40, longitude: 13.06)

    func testSameSeedGivesTheSameCatalogueAndAnotherSeedChangesThePhotos() {
        let first = SyntheticLibrary.scenarios(seed: 1)
        let second = SyntheticLibrary.scenarios(seed: 1)
        XCTAssertEqual(first.map(\.name), second.map(\.name))
        XCTAssertEqual(first.map(\.photos), second.map(\.photos))

        let other = SyntheticLibrary.scenarios(seed: 2)
        XCTAssertEqual(first.map(\.name), other.map(\.name))
        XCTAssertNotEqual(first.map(\.photos), other.map(\.photos))
    }

    func testTheCatalogueHasTheTenScenariosInOrderWithTheirNames() {
        let names = SyntheticLibrary.scenarios().map(\.name)
        XCTAssertEqual(names, [
            "weekend-trip",
            "long-trip",
            "nearby-outing",
            "back-to-back",
            "camera-without-gps",
            "moved-city",
            "single-trip-folder",
            "bursts",
            "antimeridian-trip",
            "two-homes",
        ])
    }

    func testPhotoIDsAreUniqueFollowThePatternAndDatesAreNonDecreasing() {
        for scenario in SyntheticLibrary.scenarios() {
            XCTAssertEqual(Set(scenario.photos.map(\.id)).count, scenario.photos.count, scenario.name)
            for (index, photo) in scenario.photos.enumerated() {
                XCTAssertEqual(photo.id, String(format: "%@-%04d", scenario.name, index), scenario.name)
                if index > 0 {
                    XCTAssertLessThanOrEqual(scenario.photos[index - 1].date, photo.date, scenario.name)
                }
            }
        }
    }

    func testTruthTripsHaveTheExpectedNamesAndStayAwayFromHome() {
        let expected: [(String, [String])] = [
            ("weekend-trip", ["dresden"]),
            ("long-trip", ["italy"]),
            ("nearby-outing", []),
            ("back-to-back", ["paris", "london"]),
            ("camera-without-gps", ["lisbon"]),
            ("moved-city", ["vienna"]),
            ("single-trip-folder", ["tokyo"]),
            ("bursts", []),
            ("antimeridian-trip", ["fiji"]),
            ("two-homes", ["prague"]),
        ]
        let catalogue = SyntheticLibrary.scenarios()
        XCTAssertEqual(catalogue.map(\.name), expected.map { $0.0 })

        for (scenario, expectedTrips) in zip(catalogue, expected.map { $0.1 }) {
            XCTAssertEqual(tripNames(of: scenario), expectedTrips, scenario.name)
            XCTAssertEqual(scenario.truthTrips.count, expectedTrips.count, scenario.name)
            for trip in scenario.truthTrips {
                for id in trip {
                    guard let photo = scenario.photos.first(where: { $0.id == id }),
                          let coordinate = photo.coordinate else { continue }
                    for home in homeCities(of: scenario.name, on: day(of: photo)) {
                        XCTAssertGreaterThan(
                            coordinate.distance(to: home),
                            50_000,
                            "\(scenario.name) \(id) is not away from home"
                        )
                    }
                }
            }
        }
    }

    func testNearbyOutingHasThirtyPotsdamPhotosOnDayFiftyAndNoTrip() {
        guard let scenario = SyntheticLibrary.scenarios().first(where: { $0.name == "nearby-outing" }) else {
            return XCTFail("missing nearby-outing")
        }
        let onDayFifty = scenario.photos.filter { day(of: $0) == 50 }
        XCTAssertEqual(onDayFifty.count, 30)
        for photo in onDayFifty {
            guard let coordinate = photo.coordinate else {
                return XCTFail("\(photo.id) has no location")
            }
            XCTAssertLessThan(coordinate.distance(to: potsdam), 15_000, photo.id)
        }
        XCTAssertTrue(scenario.truthTrips.isEmpty)
        XCTAssertTrue(scenario.photos.allSatisfy { $0.truthTrip == nil })
    }

    func testBurstsAreThirtyStacksOfAlikeShotsWithThirtyQuickPairs() {
        guard let scenario = SyntheticLibrary.scenarios().first(where: { $0.name == "bursts" }) else {
            return XCTFail("missing bursts")
        }
        let stacks = scenario.truthStacks
        XCTAssertEqual(stacks.count, 30)

        for stack in stacks {
            XCTAssertTrue((3...8).contains(stack.count), "burst has \(stack.count) shots")
            let photos = stack.compactMap { id in scenario.photos.first(where: { $0.id == id }) }
            XCTAssertEqual(photos.count, stack.count)
            for index in 1..<photos.count {
                let gap = photos[index].date.timeIntervalSince(photos[index - 1].date)
                XCTAssertLessThanOrEqual(gap, 2.0 + 1e-9)
                XCTAssertLessThanOrEqual(
                    (photos[index].perceptualHash ^ photos[index - 1].perceptualHash).nonzeroBitCount,
                    8
                )
            }
        }

        for photo in scenario.photos where photo.truthStack != nil {
            for other in scenario.photos where other.truthStack != photo.truthStack {
                XCTAssertGreaterThanOrEqual(
                    abs(other.date.timeIntervalSince(photo.date)),
                    60 - 1e-6,
                    "\(photo.id) and \(other.id) are too close"
                )
            }
        }

        // The quick pairs are the only photos shot exactly 2 s apart.
        let singles = scenario.photos.filter { $0.truthStack == nil }
        var pairs: [(SyntheticPhoto, SyntheticPhoto)] = []
        for index in 1..<singles.count {
            let gap = singles[index].date.timeIntervalSince(singles[index - 1].date)
            if abs(gap - 2.0) < 1e-6 {
                pairs.append((singles[index - 1], singles[index]))
            }
        }
        XCTAssertEqual(pairs.count, 30)
    }

    func testCameraWithoutGPSHasMostlyPhotosWithoutALocation() {
        guard let scenario = SyntheticLibrary.scenarios().first(where: { $0.name == "camera-without-gps" }) else {
            return XCTFail("missing camera-without-gps")
        }
        let lisbon = scenario.photos.filter { $0.truthTrip == "lisbon" }
        XCTAssertFalse(lisbon.isEmpty)
        let withoutLocation = lisbon.filter { $0.coordinate == nil }.count
        XCTAssertGreaterThanOrEqual(withoutLocation * 2, lisbon.count)
    }

    func testBuildingTheWholeCatalogueTakesUnderOneSecond() {
        let started = Date()
        let catalogue = SyntheticLibrary.scenarios(seed: 1)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(catalogue.count, 10)
        XCTAssertLessThan(elapsed, 1.0, "building took \(elapsed) seconds")
    }

    // MARK: - Helpers

    private func day(of photo: SyntheticPhoto) -> Int {
        Int((photo.date.timeIntervalSince(baseDate) / 86_400).rounded(.down))
    }

    private func tripNames(of scenario: SyntheticScenario) -> [String] {
        var names: [String] = []
        for photo in scenario.photos {
            if let name = photo.truthTrip, !names.contains(name) {
                names.append(name)
            }
        }
        return names
    }

    private func homeCities(of scenario: String, on day: Int) -> [GeoPoint] {
        switch scenario {
        case "moved-city":
            return day >= 240 ? [munich] : [berlin]
        case "antimeridian-trip":
            return [auckland]
        case "two-homes":
            return [berlin, hamburg]
        default:
            return [berlin]
        }
    }
}
