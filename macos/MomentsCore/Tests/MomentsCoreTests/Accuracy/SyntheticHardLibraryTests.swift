import Foundation
import XCTest
@testable import MomentsCore

final class SyntheticHardLibraryTests: XCTestCase {
    private let baseDate = SyntheticLibrary.baseDate
    private let berlin = GeoPoint(latitude: 52.52, longitude: 13.40)
    private let hamburg = GeoPoint(latitude: 53.55, longitude: 9.99)
    private let dubai = GeoPoint(latitude: 25.25, longitude: 55.36)

    private let expectedNames = [
        "cruise",
        "road-trip",
        "layover",
        "day-trip-far",
        "sparse-long-trip",
        "screenshots-on-trip",
        "monthly-weekends",
    ]

    func testSameSeedGivesTheSameHardCatalogueAndAnotherSeedChangesThePhotos() {
        let first = SyntheticLibrary.hardScenarios(seed: 1)
        let second = SyntheticLibrary.hardScenarios(seed: 1)
        XCTAssertEqual(first.map(\.name), second.map(\.name))
        XCTAssertEqual(first.map(\.photos), second.map(\.photos))

        let other = SyntheticLibrary.hardScenarios(seed: 2)
        XCTAssertEqual(first.map(\.name), other.map(\.name))
        XCTAssertNotEqual(first.map(\.photos), other.map(\.photos))
    }

    func testTheHardCatalogueHasTheSevenScenariosInOrderWithTheirTrips() {
        let catalogue = SyntheticLibrary.hardScenarios()
        XCTAssertEqual(catalogue.map(\.name), expectedNames)

        let expectedTripNames: [[String]] = [
            ["cruise"],
            ["roadtrip"],
            ["tokyo"],
            ["hamburg-day"],
            ["japan"],
            ["paris"],
            (1...13).map { String(format: "dresden-%02d", $0) },
        ]
        let expectedTripCounts = [1, 1, 1, 1, 1, 1, 13]
        XCTAssertEqual(catalogue.map { $0.truthTrips.count }, expectedTripCounts)

        for (scenario, names) in zip(catalogue, expectedTripNames) {
            XCTAssertEqual(tripNames(of: scenario), names, scenario.name)
            XCTAssertEqual(scenario.truthTrips.count, names.count, scenario.name)
        }

        // The weekend trips are the 13 two-day stays at days 28k+20 and 28k+21.
        if let weekends = catalogue.last(where: { $0.name == "monthly-weekends" }) {
            for (index, trip) in weekends.truthTrips.enumerated() {
                let days = Set(trip.compactMap { id in
                    weekends.photos.first { $0.id == id }.map(day(of:))
                })
                XCTAssertEqual(days, [28 * index + 20, 28 * index + 21], "dresden-\(index + 1)")
            }
        }
    }

    func testHardPhotoIDsAreUniqueFollowThePatternAndDatesAreNonDecreasing() {
        let easyIDs = Set(SyntheticLibrary.scenarios().flatMap { $0.photos.map(\.id) })
        for scenario in SyntheticLibrary.hardScenarios() {
            XCTAssertEqual(Set(scenario.photos.map(\.id)).count, scenario.photos.count, scenario.name)
            for (index, photo) in scenario.photos.enumerated() {
                XCTAssertEqual(photo.id, String(format: "%@-%04d", scenario.name, index), scenario.name)
                XCTAssertFalse(easyIDs.contains(photo.id), "\(scenario.name) reuses \(photo.id)")
                if index > 0 {
                    XCTAssertLessThanOrEqual(scenario.photos[index - 1].date, photo.date, scenario.name)
                }
            }
        }
    }

    func testSeaDaysRestDaysAndTheSparseTripHaveNoPhotos() {
        let catalogue = SyntheticLibrary.hardScenarios()
        guard let cruise = catalogue.first(where: { $0.name == "cruise" }),
              let roadTrip = catalogue.first(where: { $0.name == "road-trip" }),
              let sparse = catalogue.first(where: { $0.name == "sparse-long-trip" }) else {
            return XCTFail("missing a hard scenario")
        }

        XCTAssertTrue(cruise.photos.filter { day(of: $0) == 103 }.isEmpty)
        XCTAssertTrue(cruise.photos.filter { day(of: $0) == 107 }.isEmpty)
        XCTAssertTrue(roadTrip.photos.filter { day(of: $0) == 65 }.isEmpty)

        let tripDays = Set(sparse.photos.map(day(of:)).filter { (90..<111).contains($0) })
        XCTAssertEqual(tripDays, [90, 91, 95, 99, 100, 102, 106, 108, 110])

        // Each of those days is a trip stay: 5…25 photos, all in the trip.
        let photosByDay = Dictionary(grouping: sparse.photos, by: day(of:))
        for tripDay in tripDays {
            let photos = photosByDay[tripDay] ?? []
            XCTAssertTrue((5...25).contains(photos.count), "day \(tripDay) has \(photos.count) photos")
            XCTAssertTrue(photos.allSatisfy { $0.truthTrip == "japan" }, "day \(tripDay)")
        }
    }

    func testLayoverHasThreeDubaiPhotosBeforeTokyoAndTwoAfterIt() {
        guard let layover = SyntheticLibrary.hardScenarios().first(where: { $0.name == "layover" }) else {
            return XCTFail("missing layover")
        }

        let dubaiPhotos = layover.photos.filter { photo in
            photo.coordinate.map { $0.distance(to: dubai) < 15_000 } ?? false
        }
        XCTAssertEqual(dubaiPhotos.count, 5)
        for photo in dubaiPhotos {
            XCTAssertEqual(photo.truthTrip, "tokyo", photo.id)
        }

        let dubaiIDs = Set(dubaiPhotos.map(\.id))
        let tokyoPhotos = layover.photos.filter { $0.truthTrip == "tokyo" && !dubaiIDs.contains($0.id) }
        guard let firstTokyo = tokyoPhotos.first, let lastTokyo = tokyoPhotos.last else {
            return XCTFail("missing Tokyo photos")
        }
        XCTAssertEqual(dubaiPhotos.filter { $0.date < firstTokyo.date }.count, 3)
        XCTAssertEqual(dubaiPhotos.filter { $0.date > lastTokyo.date }.count, 2)
    }

    func testDayTripFarHasTwentyFiveHamburgPhotosOnDayForty() {
        guard let scenario = SyntheticLibrary.hardScenarios().first(where: { $0.name == "day-trip-far" }) else {
            return XCTFail("missing day-trip-far")
        }

        let onDayForty = scenario.photos.filter { day(of: $0) == 40 }
        XCTAssertEqual(onDayForty.count, 25)
        for photo in onDayForty {
            guard let coordinate = photo.coordinate else {
                return XCTFail("\(photo.id) has no location")
            }
            XCTAssertLessThan(coordinate.distance(to: hamburg), 15_000, photo.id)
            XCTAssertEqual(photo.truthTrip, "hamburg-day", photo.id)
        }
    }

    func testScreenshotsOnTripAreTenLocationlessPhotosWithinTwoHoursOfALocatedOne() {
        guard let scenario = SyntheticLibrary.hardScenarios().first(where: { $0.name == "screenshots-on-trip" }) else {
            return XCTFail("missing screenshots-on-trip")
        }

        let trip = scenario.photos.filter { $0.truthTrip == "paris" }
        let located = trip.filter { $0.coordinate != nil }
        let withoutLocation = trip.filter { $0.coordinate == nil }
        XCTAssertEqual(withoutLocation.count, 10)

        for photo in withoutLocation {
            let nearest = located.map { abs($0.date.timeIntervalSince(photo.date)) }.min()
            guard let nearest else {
                return XCTFail("\(photo.id) has no located trip photo")
            }
            XCTAssertLessThanOrEqual(nearest, 2 * 3_600, photo.id)
        }
    }

    func testTripPhotosAreFarFromBerlinAndDailyLifeIsNearIt() {
        for scenario in SyntheticLibrary.hardScenarios() {
            for photo in scenario.photos {
                guard let coordinate = photo.coordinate else { continue }
                if photo.truthTrip == nil {
                    XCTAssertLessThan(coordinate.distance(to: berlin), 20_000, "\(scenario.name) \(photo.id) daily life")
                } else {
                    XCTAssertGreaterThan(coordinate.distance(to: berlin), 50_000, "\(scenario.name) \(photo.id) trip")
                }
            }
        }
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
}
