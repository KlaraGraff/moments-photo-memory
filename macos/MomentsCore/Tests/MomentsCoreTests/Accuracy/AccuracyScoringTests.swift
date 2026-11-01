import Foundation
import XCTest
@testable import MomentsCore

final class AccuracyScoringTests: XCTestCase {
    private let universe = ["a", "b", "c", "d", "e"]

    // MARK: - Pairwise score

    func testHandExampleMatchesExpectedPairCountsAndScores() {
        let score = AccuracyScoring.pairwise(
            predicted: [["a", "b"], ["c", "d", "e"]],
            truth: [["a", "b", "c"], ["d", "e"]],
            universe: universe
        )

        XCTAssertEqual(score.truePairs, 4)
        XCTAssertEqual(score.predictedPairs, 4)
        XCTAssertEqual(score.correctPairs, 2)
        XCTAssertEqual(score.precision, 0.5, accuracy: 1e-12)
        XCTAssertEqual(score.recall, 0.5, accuracy: 1e-12)
        XCTAssertEqual(score.f1, 0.5, accuracy: 1e-12)
    }

    func testIdenticalGroupingsScoreOneOnEveryMeasure() {
        let groups = [["a", "b", "c"], ["d", "e"]]
        let score = AccuracyScoring.pairwise(predicted: groups, truth: groups, universe: universe)
        let ari = AccuracyScoring.adjustedRandIndex(predicted: groups, truth: groups, universe: universe)

        XCTAssertEqual(score.precision, 1, accuracy: 1e-12)
        XCTAssertEqual(score.recall, 1, accuracy: 1e-12)
        XCTAssertEqual(score.f1, 1, accuracy: 1e-12)
        XCTAssertEqual(ari, 1, accuracy: 1e-12)
    }

    func testAllSingletonsScoreOneWithNoPairs() {
        let singletons = [["a"], ["b"], ["c"], ["d"], ["e"]]
        let score = AccuracyScoring.pairwise(predicted: singletons, truth: singletons, universe: universe)
        let ari = AccuracyScoring.adjustedRandIndex(predicted: singletons, truth: singletons, universe: universe)

        XCTAssertEqual(score.truePairs, 0)
        XCTAssertEqual(score.predictedPairs, 0)
        XCTAssertEqual(score.precision, 1, accuracy: 1e-12)
        XCTAssertEqual(score.recall, 1, accuracy: 1e-12)
        XCTAssertEqual(score.f1, 1, accuracy: 1e-12)
        XCTAssertEqual(ari, 1, accuracy: 1e-12)
    }

    func testOnePredictedGroupAgainstAllSingletonsScoresZeroPrecision() {
        let truth = [["a"], ["b"], ["c"], ["d"], ["e"]]
        let score = AccuracyScoring.pairwise(predicted: [universe], truth: truth, universe: universe)
        let ari = AccuracyScoring.adjustedRandIndex(predicted: [universe], truth: truth, universe: universe)

        XCTAssertEqual(score.truePairs, 0)
        XCTAssertEqual(score.predictedPairs, 10)
        XCTAssertEqual(score.correctPairs, 0)
        XCTAssertEqual(score.precision, 0, accuracy: 1e-12)
        XCTAssertEqual(score.recall, 1, accuracy: 1e-12)
        XCTAssertEqual(score.f1, 0, accuracy: 1e-12)
        XCTAssertEqual(ari, 0, accuracy: 1e-12)
    }

    func testIdsOutsideUniverseAreIgnoredAndUngroupedIdsAreSingletons() {
        let withOutsiders = AccuracyScoring.pairwise(
            predicted: [["a", "b"], ["x"], ["y"]],
            truth: [["a", "b"]],
            universe: ["a", "b", "c"]
        )
        XCTAssertEqual(withOutsiders, PairwiseScore(truePairs: 1, predictedPairs: 1, correctPairs: 1))

        let ungrouped = AccuracyScoring.pairwise(
            predicted: [["a", "b"]],
            truth: [["a", "b"], ["c"]],
            universe: universe
        )
        XCTAssertEqual(ungrouped, PairwiseScore(truePairs: 1, predictedPairs: 1, correctPairs: 1))
        XCTAssertEqual(
            AccuracyScoring.adjustedRandIndex(predicted: [["a", "b"]], truth: [["a", "b"], ["c"]], universe: universe),
            1,
            accuracy: 1e-12
        )
    }

    func testPairwiseAndAdjustedRandIndexMatchBruteForceOnRandomPartitions() {
        var rng = SplitMix64(seed: 0xC0FFEE)
        for _ in 0..<200 {
            let itemCount = rng.int(below: 40) + 1
            let ids = (0..<itemCount).map { "id-\($0)" }
            let truth = randomPartition(of: ids, using: &rng)
            let predicted = randomPartition(of: ids, using: &rng)
            let bruteForce = bruteForceScores(predicted: predicted, truth: truth, universe: ids)

            XCTAssertEqual(AccuracyScoring.pairwise(predicted: predicted, truth: truth, universe: ids), bruteForce.pairwise)
            XCTAssertEqual(
                AccuracyScoring.adjustedRandIndex(predicted: predicted, truth: truth, universe: ids),
                bruteForce.ari,
                accuracy: 1e-9
            )
        }
    }

    func testAdjustedRandIndexIsNearZeroForIndependentRandomPartitions() {
        var rng = SplitMix64(seed: 7)
        let ids = (0..<2_000).map { "item-\($0)" }
        let truth = randomPartition(of: ids, into: 50, using: &rng)
        let predicted = randomPartition(of: ids, into: 50, using: &rng)

        let ari = AccuracyScoring.adjustedRandIndex(predicted: predicted, truth: truth, universe: ids)

        XCTAssertLessThan(abs(ari), 0.05)
    }

    // MARK: - Trip match

    func testTripMatchScoresExactSplitMissingAndEmptyPredictions() {
        let truth = [["a", "b", "c", "d"]]

        XCTAssertEqual(
            AccuracyScoring.tripMatch(predicted: [["a", "b", "c", "d"]], truth: truth),
            TripMatchScore(meanBestJaccard: 1, exactTrips: 1, missedTrips: 0, extraTrips: 0)
        )

        let split = AccuracyScoring.tripMatch(predicted: [["a", "b"], ["c", "d"], ["x"]], truth: truth)
        XCTAssertEqual(split.meanBestJaccard, 0.5, accuracy: 1e-12)
        XCTAssertEqual(split.exactTrips, 0)
        XCTAssertEqual(split.missedTrips, 0)
        XCTAssertEqual(split.extraTrips, 1)

        let missing = AccuracyScoring.tripMatch(predicted: [], truth: truth)
        XCTAssertEqual(missing.meanBestJaccard, 0, accuracy: 1e-12)
        XCTAssertEqual(missing.exactTrips, 0)
        XCTAssertEqual(missing.missedTrips, 1)
        XCTAssertEqual(missing.extraTrips, 0)

        XCTAssertEqual(
            AccuracyScoring.tripMatch(predicted: [], truth: []),
            TripMatchScore(meanBestJaccard: 1, exactTrips: 0, missedTrips: 0, extraTrips: 0)
        )
        XCTAssertEqual(
            AccuracyScoring.tripMatch(predicted: [["x"]], truth: []),
            TripMatchScore(meanBestJaccard: 0, exactTrips: 0, missedTrips: 0, extraTrips: 1)
        )
    }

    // MARK: - Membership agreement

    func testMembershipAgreementCountsGroupedAndUngroupedItems() {
        let ids = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"]
        let agreement = AccuracyScoring.membershipAgreement(
            predicted: [["a", "b"], ["d"]],
            truth: [["a", "b", "c"]],
            universe: ids
        )

        XCTAssertEqual(agreement, 0.8, accuracy: 1e-12)
    }

    // MARK: - Speed

    func testPairwiseAndAdjustedRandIndexScoreFiftyThousandItemsQuickly() {
        var rng = SplitMix64(seed: 99)
        let ids = (0..<50_000).map { "item-\($0)" }
        let truth = randomPartition(of: ids, into: 1_000, using: &rng)
        let predicted = randomPartition(of: ids, into: 1_000, using: &rng)

        let start = Date()
        let score = AccuracyScoring.pairwise(predicted: predicted, truth: truth, universe: ids)
        let ari = AccuracyScoring.adjustedRandIndex(predicted: predicted, truth: truth, universe: ids)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 1.0)
        XCTAssertEqual(score.truePairs, pairsInside(groups: truth))
        XCTAssertEqual(score.predictedPairs, pairsInside(groups: predicted))
        XCTAssertTrue(ari.isFinite)
    }

    // MARK: - Helpers

    private struct SplitMix64 {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        mutating func int(below bound: Int) -> Int {
            Int(next() % UInt64(bound))
        }
    }

    private func randomPartition(of ids: [String], using rng: inout SplitMix64) -> [[String]] {
        let groupCount = rng.int(below: ids.count) + 1
        var groups = Array(repeating: [String](), count: groupCount)
        for id in ids {
            guard rng.int(below: 10) > 0 else { continue }
            groups[rng.int(below: groupCount)].append(id)
        }
        return groups
    }

    private func randomPartition(of ids: [String], into groupCount: Int, using rng: inout SplitMix64) -> [[String]] {
        var groups = Array(repeating: [String](), count: groupCount)
        for id in ids {
            groups[rng.int(below: groupCount)].append(id)
        }
        return groups
    }

    private func pairsInside(groups: [[String]]) -> Int {
        groups.reduce(0) { total, group in
            total + group.count * (group.count - 1) / 2
        }
    }

    private func labels(for groups: [[String]], universe: [String]) -> [String: Int] {
        let universeIDs = Set(universe)
        var result: [String: Int] = [:]
        var nextLabel = 0
        for group in groups {
            let members = group.filter { universeIDs.contains($0) }
            guard !members.isEmpty else { continue }
            for id in members where result[id] == nil {
                result[id] = nextLabel
            }
            nextLabel += 1
        }
        for (index, id) in universe.enumerated() where result[id] == nil {
            result[id] = nextLabel + index
        }
        return result
    }

    private func bruteForceScores(
        predicted: [[String]],
        truth: [[String]],
        universe: [String]
    ) -> (pairwise: PairwiseScore, ari: Double) {
        let truthLabels = labels(for: truth, universe: universe)
        let predictedLabels = labels(for: predicted, universe: universe)

        var truePairs = 0
        var predictedPairs = 0
        var correctPairs = 0
        for first in 0..<universe.count {
            for second in (first + 1)..<universe.count {
                let sameTruth = truthLabels[universe[first]] == truthLabels[universe[second]]
                let samePredicted = predictedLabels[universe[first]] == predictedLabels[universe[second]]
                if sameTruth { truePairs += 1 }
                if samePredicted { predictedPairs += 1 }
                if sameTruth && samePredicted { correctPairs += 1 }
            }
        }

        let score = PairwiseScore(truePairs: truePairs, predictedPairs: predictedPairs, correctPairs: correctPairs)
        let totalPairs = universe.count * (universe.count - 1) / 2
        guard totalPairs > 0 else { return (score, 1) }
        let expected = Double(truePairs) * Double(predictedPairs) / Double(totalPairs)
        let maxIndex = Double(truePairs + predictedPairs) / 2
        let ari = maxIndex == expected ? 1 : (Double(correctPairs) - expected) / (maxIndex - expected)
        return (score, ari)
    }
}
