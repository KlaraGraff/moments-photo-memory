import Foundation
import XCTest
@testable import MomentsCore

/// Scores how well a whole import is organized, on the synthetic catalogue
/// whose right answers are known. Each floor is the score when it was last
/// raised: a change may raise a floor, never lower one.
final class OrganizationAccuracyTests: XCTestCase {
    /// Pairwise F1 of trip membership, and the share of photos whose
    /// "trip or daily life" side is right.
    private static let tripFloors: [String: (pairF1: Double, agreement: Double)] = [
        "weekend-trip": (1, 1),
        "long-trip": (1, 1),
        "nearby-outing": (1, 1),
        "back-to-back": (1, 1),
        "camera-without-gps": (1, 1),
        "moved-city": (1, 1),
        "single-trip-folder": (1, 1),
        "bursts": (1, 1),
        "antimeridian-trip": (1, 1),
        // The weekend town is not a usual place yet in the first weeks.
        "two-homes": (0.9919, 0.9842)
    ]

    /// The harder libraries: moves without photos in between, sea days,
    /// layovers, a far day trip, screenshots on a trip, monthly weekends.
    private static let hardTripFloors: [String: (pairF1: Double, agreement: Double)] = [
        // Sea days no longer split the cruise: the ports are far from home and
        // much closer to each other than to home.
        "cruise": (1, 1),
        "road-trip": (1, 1),
        "layover": (1, 1),
        "day-trip-far": (1, 1),
        // A far move much shorter than the way home keeps the trip together.
        "sparse-long-trip": (1, 1),
        "screenshots-on-trip": (1, 1),
        "monthly-weekends": (1, 1)
    ]

    /// The frequent-place libraries: no frequent place exists yet, so the
    /// floors only hold today's trip scores, rounded down. A later change may
    /// raise them, never lower them.
    private static let placeTripFloors: [String: (pairF1: Double, agreement: Double)] = [
        // The 45-day Tokyo stay becomes a usual place: 727 of the 988 "far"
        // photos land in daily life and only the first legs stay one trip.
        "far-long-trip": (0.1301, 0.5159),
        // The four Dresden visits are found, but they are not one frequent place.
        "second-place-visits": (1, 1),
        // Right today: two visits must stay two trips and form no frequent place.
        "two-visits-only": (1, 1),
        // All thirteen weekends are found, but they are not one frequent place.
        "monthly-dresden": (1, 1),
        // The road trip's Dresden night is no separate visit, but no frequent place exists.
        "pass-through": (1, 1),
        // The three New York stays are three trips, not one frequent place.
        "frequent-far-place": (1, 1)
    ]

    /// Pairwise F1 of burst stacks.
    private static let stackFloors: [String: Double] = [
        "bursts": 1
    ]

    func testTripsScoreAtLeastTheirFloors() {
        let scenarios = SyntheticLibrary.scenarios()
        XCTAssertEqual(Set(scenarios.map(\.name)), Set(Self.tripFloors.keys), "every scenario needs a floor")
        for scenario in scenarios {
            guard let floor = Self.tripFloors[scenario.name] else { continue }
            let ids: [String] = scenario.photos.map(\.id)
            let trips: [[String]] = TripSegmenter().segment(scenario.photos.map(\.stop)).trips
            let pairF1: Double = AccuracyScoring.pairwise(predicted: trips, truth: scenario.truthTrips, universe: ids).f1
            let agreement: Double = AccuracyScoring.membershipAgreement(predicted: trips, truth: scenario.truthTrips, universe: ids)
            print(String(format: "ACCURACY trips %@ pairF1=%.4f agreement=%.4f", scenario.name, pairF1, agreement))
            XCTAssertGreaterThanOrEqual(pairF1, floor.pairF1 - 1e-9, "\(scenario.name) trip pairs")
            XCTAssertGreaterThanOrEqual(agreement, floor.agreement - 1e-9, "\(scenario.name) trip or daily life")
        }
    }

    func testHarderTripsScoreAtLeastTheirFloors() {
        let scenarios = SyntheticLibrary.hardScenarios()
        XCTAssertEqual(Set(scenarios.map(\.name)), Set(Self.hardTripFloors.keys), "every scenario needs a floor")
        for scenario in scenarios {
            guard let floor = Self.hardTripFloors[scenario.name] else { continue }
            let ids: [String] = scenario.photos.map(\.id)
            let trips: [[String]] = TripSegmenter().segment(scenario.photos.map(\.stop)).trips
            let pairF1: Double = AccuracyScoring.pairwise(predicted: trips, truth: scenario.truthTrips, universe: ids).f1
            let agreement: Double = AccuracyScoring.membershipAgreement(predicted: trips, truth: scenario.truthTrips, universe: ids)
            print(String(format: "ACCURACY hard trips %@ pairF1=%.4f agreement=%.4f", scenario.name, pairF1, agreement))
            XCTAssertGreaterThanOrEqual(pairF1, floor.pairF1 - 1e-9, "\(scenario.name) trip pairs")
            XCTAssertGreaterThanOrEqual(agreement, floor.agreement - 1e-9, "\(scenario.name) trip or daily life")
        }
    }

    func testPlaceScenariosTripsScoreAtLeastTheirFloors() {
        let scenarios = SyntheticLibrary.placeScenarios()
        let names: Set<String> = Set(scenarios.map { (entry: SyntheticPlaceScenario) -> String in entry.scenario.name })
        XCTAssertEqual(names, Set(Self.placeTripFloors.keys), "every scenario needs a floor")
        for entry in scenarios {
            let scenario = entry.scenario
            guard let floor = Self.placeTripFloors[scenario.name] else { continue }
            let ids: [String] = scenario.photos.map(\.id)
            let result = TripSegmenter().segment(scenario.photos.map(\.stop))
            let trips: [[String]] = result.trips
            let pairF1: Double = AccuracyScoring.pairwise(predicted: trips, truth: scenario.truthTrips, universe: ids).f1
            let agreement: Double = AccuracyScoring.membershipAgreement(predicted: trips, truth: scenario.truthTrips, universe: ids)
            if scenario.name == "far-long-trip" {
                let farIDs: [String] = scenario.photos.compactMap { (photo: SyntheticPhoto) -> String? in
                    photo.truthTrip == "far" ? photo.id : nil
                }
                let inDailyLife: Int = farIDs.filter { (id: String) -> Bool in
                    result.atUsualPlaceIDs.contains(id)
                }.count
                print(String(
                    format: "ACCURACY place trips %@ pairF1=%.4f agreement=%.4f farInDailyLife=%d",
                    scenario.name,
                    pairF1,
                    agreement,
                    inDailyLife
                ))
            } else {
                print(String(format: "ACCURACY place trips %@ pairF1=%.4f agreement=%.4f", scenario.name, pairF1, agreement))
            }
            let frequentPhotos: [[String]] = entry.truthFrequentPhotoGroups()
            XCTAssertEqual(frequentPhotos.count, entry.frequentGroups.count, "\(scenario.name) frequent groups")
            for (group, photos) in zip(entry.frequentGroups, frequentPhotos) {
                XCTAssertGreaterThanOrEqual(group.count, 3, "\(scenario.name) a frequent place needs three visits")
                XCTAssertFalse(photos.isEmpty, "\(scenario.name) a frequent place needs photos")
                let trips: Set<String> = Set(group)
                let photoTrips: Set<String> = Set(scenario.photos.compactMap { (photo: SyntheticPhoto) -> String? in
                    photos.contains(photo.id) ? photo.truthTrip : nil
                })
                XCTAssertEqual(photoTrips, trips, "\(scenario.name) frequent group photos")
            }
            print(String(format: "ACCURACY place frequentGroups %@ truthGroups=%d", scenario.name, frequentPhotos.count))
            XCTAssertGreaterThanOrEqual(pairF1, floor.pairF1 - 1e-9, "\(scenario.name) trip pairs")
            XCTAssertGreaterThanOrEqual(agreement, floor.agreement - 1e-9, "\(scenario.name) trip or daily life")
        }
    }

    func testBurstsScoreAtLeastTheirFloors() {
        for scenario in SyntheticLibrary.scenarios() {
            guard let floor = Self.stackFloors[scenario.name] else { continue }
            let ids: [String] = scenario.photos.map(\.id)
            let index = PhotoStackDetector().detect(scenario.photos.map(\.stackPhoto))
            let stacks: [[String]] = index.stacks.values.map(\.memberIDs)
            let pairF1: Double = AccuracyScoring.pairwise(predicted: stacks, truth: scenario.truthStacks, universe: ids).f1
            print(String(format: "ACCURACY stacks %@ pairF1=%.4f", scenario.name, pairF1))
            XCTAssertGreaterThanOrEqual(pairF1, floor - 1e-9, "\(scenario.name) bursts")
        }
    }
}
