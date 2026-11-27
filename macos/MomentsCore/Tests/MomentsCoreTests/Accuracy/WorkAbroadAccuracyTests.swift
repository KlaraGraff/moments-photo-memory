import Foundation
import XCTest
@testable import MomentsCore

/// Someone working away from their home town and moving between work sites:
/// going home, the journey there, a new work site and a visit to a former
/// one are daily life; only holidays are trips.
final class WorkAbroadAccuracyTests: XCTestCase {
    private static let seeds: [UInt64] = [1, 2, 3]

    func testHomeTownHolidayIsNoTrip() {
        for seed in Self.seeds {
            let scenario = SyntheticLibrary.workAbroadScenarios(seed: seed)[0]
            let trips = TripSegmenter().segment(scenario.photos.map(\.stop)).trips
            let ids = scenario.photos.map(\.id)
            let agreement = AccuracyScoring.membershipAgreement(predicted: trips, truth: scenario.truthTrips, universe: ids)
            let pairF1 = AccuracyScoring.pairwise(predicted: trips, truth: scenario.truthTrips, universe: ids).f1
            XCTAssertGreaterThanOrEqual(agreement, 0.99, "seed \(seed)")
            XCTAssertGreaterThanOrEqual(pairF1, 0.98, "seed \(seed)")
            // Both holidays are found, each as one trip.
            let match = AccuracyScoring.tripMatch(predicted: trips, truth: scenario.truthTrips)
            XCTAssertEqual(match.exactTrips, 2, "seed \(seed)")
            // No photo of the three weeks back home is in a trip.
            let inTrips = Set(trips.joined())
            let holiday = scenario.photos.filter { (photo: SyntheticPhoto) -> Bool in
                let day = Int(photo.date.timeIntervalSince(SyntheticLibrary.baseDate) / 86_400)
                return (550..<571).contains(day)
            }
            XCTAssertFalse(holiday.isEmpty)
            XCTAssertTrue(holiday.allSatisfy { !inTrips.contains($0.id) }, "seed \(seed)")
        }
    }

    func testMovingBetweenWorkSitesIsNoTrip() {
        for seed in Self.seeds {
            let scenario = SyntheticLibrary.workAbroadScenarios(seed: seed)[1]
            let trips = TripSegmenter().segment(scenario.photos.map(\.stop)).trips
            let ids = scenario.photos.map(\.id)
            // Only the Seville holiday is a trip; the new sites and the visit
            // back to a former one are not.
            XCTAssertEqual(trips.count, 1, "seed \(seed)")
            XCTAssertGreaterThanOrEqual(
                AccuracyScoring.membershipAgreement(predicted: trips, truth: scenario.truthTrips, universe: ids), 0.995,
                "seed \(seed)"
            )
        }
    }
}
