import Foundation
import XCTest
@testable import MomentsCore

/// Scores trip finding on randomized years of everyday phone libraries
/// (`SyntheticRealLifeLibrary`) and prints a scoreboard per ingredient.
final class RealLifeScoreboardTests: XCTestCase {
    private static let seeds: [UInt64] = [1, 2, 3]

    struct Totals {
        var libraries = 0
        var jaccard = 0.0
        var agreement = 0.0
        var pairF1 = 0.0
        var truthTrips = 0
        var exact = 0
        var missed = 0
        var extra = 0
        var merged = 0
        var split = 0

        mutating func add(_ other: Totals) {
            libraries += other.libraries
            jaccard += other.jaccard
            agreement += other.agreement
            pairF1 += other.pairF1
            truthTrips += other.truthTrips
            exact += other.exact
            missed += other.missed
            extra += other.extra
            merged += other.merged
            split += other.split
        }

        var line: String {
            let n = Double(max(1, libraries))
            return String(
                format: "libs=%d trips=%.4f pairF1=%.4f agreement=%.4f exact=%d/%d missed=%d extra=%d merged=%d split=%d",
                libraries, jaccard / n, pairF1 / n, agreement / n, exact, truthTrips, missed, extra, merged, split
            )
        }
    }

    static func score(_ library: SyntheticRealLifeLibrary, segmenter: TripSegmenter = TripSegmenter()) -> Totals {
        let scenario = library.scenario
        let ids = scenario.photos.map(\.id)
        let predicted = segmenter.segment(scenario.photos.map(\.stop)).trips
        let truth = scenario.truthTrips
        let match = AccuracyScoring.tripMatch(predicted: predicted, truth: truth)
        var totals = Totals()
        totals.libraries = 1
        totals.jaccard = match.meanBestJaccard
        totals.pairF1 = AccuracyScoring.pairwise(predicted: predicted, truth: truth, universe: ids).f1
        totals.agreement = AccuracyScoring.membershipAgreement(predicted: predicted, truth: truth, universe: ids)
        totals.truthTrips = truth.count
        totals.exact = match.exactTrips
        totals.missed = match.missedTrips
        totals.extra = match.extraTrips
        // A predicted trip holding most of two true trips merged them; a true
        // trip whose photos fall in two predicted trips was split.
        let truthOf: [String: Int] = Dictionary(uniqueKeysWithValues: truth.enumerated().flatMap { index, trip in trip.map { ($0, index) } })
        let predictedOf: [String: Int] = Dictionary(predicted.enumerated().flatMap { index, trip in trip.map { ($0, index) } }, uniquingKeysWith: { first, _ in first })
        for trip in predicted {
            var counts: [Int: Int] = [:]
            for id in trip { if let t = truthOf[id] { counts[t, default: 0] += 1 } }
            if counts.values.filter({ $0 >= 3 }).count >= 2 { totals.merged += 1 }
        }
        for trip in truth {
            var counts: [Int: Int] = [:]
            for id in trip { if let p = predictedOf[id] { counts[p, default: 0] += 1 } }
            if counts.values.filter({ $0 >= 3 }).count >= 2 { totals.split += 1 }
        }
        return totals
    }

    func testRealLifeScoreboard() {
        var all = Totals()
        var byIngredient: [RealLifeIngredient: Totals] = [:]
        var plain = Totals()
        var worst: [(String, Double, String)] = []
        for seed in Self.seeds {
            for library in SyntheticLibrary.realLifeLibraries(seed: seed) {
                let totals = Self.score(library)
                all.add(totals)
                for ingredient in library.ingredients { byIngredient[ingredient, default: Totals()].add(totals) }
                if library.ingredients.isEmpty { plain.add(totals) }
                worst.append((library.scenario.name, totals.jaccard, library.ingredients.map(\.rawValue).sorted().joined(separator: ",")))
            }
        }
        print("LIFE total " + all.line)
        // Floors a little under today's scores, so a change that makes
        // everyday libraries worse fails here.
        let libraries = Double(max(1, all.libraries))
        XCTAssertGreaterThanOrEqual(all.jaccard / libraries, 0.96)
        XCTAssertGreaterThanOrEqual(all.agreement / libraries, 0.995)
        XCTAssertLessThanOrEqual(all.extra, 5, "Days at home made into trips")
        print("LIFE plain " + plain.line)
        for ingredient in RealLifeIngredient.allCases {
            print("LIFE " + ingredient.rawValue + " " + (byIngredient[ingredient] ?? Totals()).line)
        }
        for entry in worst.sorted(by: { $0.1 < $1.1 }).prefix(8) {
            print(String(format: "LIFE worst %@ trips=%.4f %@", entry.0, entry.1, entry.2))
        }
    }
}
