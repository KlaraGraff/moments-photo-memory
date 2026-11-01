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
