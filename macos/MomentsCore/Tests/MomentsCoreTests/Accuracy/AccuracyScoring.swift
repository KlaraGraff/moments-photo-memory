import Foundation

/// How well predicted groups match true groups, counted over pairs of items.
struct PairwiseScore: Equatable {
    let truePairs: Int        // pairs of items in the same true group
    let predictedPairs: Int   // pairs of items in the same predicted group
    let correctPairs: Int     // pairs in the same group on both sides

    var precision: Double {   // correctPairs / predictedPairs; 1 when predictedPairs == 0
        predictedPairs == 0 ? 1 : Double(correctPairs) / Double(predictedPairs)
    }

    var recall: Double {      // correctPairs / truePairs; 1 when truePairs == 0
        truePairs == 0 ? 1 : Double(correctPairs) / Double(truePairs)
    }

    var f1: Double {          // 2pr / (p + r); 0 when p + r == 0
        let p = precision
        let r = recall
        return p + r == 0 ? 0 : 2 * p * r / (p + r)
    }
}

/// How the predicted trips line up with the true trips.
struct TripMatchScore: Equatable {
    /// For each true trip, the best Jaccard overlap with any predicted trip, averaged. 1 when there are no true trips and no predicted trips; 0 when there are no true trips but some predicted ones.
    let meanBestJaccard: Double
    /// True trips whose best predicted trip has exactly the same ids.
    let exactTrips: Int
    /// True trips with no predicted trip overlapping at least half of them (Jaccard < 0.5 for all).
    let missedTrips: Int
    /// Predicted trips that overlap no true trip at all.
    let extraTrips: Int
}

enum AccuracyScoring {
    /// Groups are lists of ids. An id that is in no group counts as a group of one.
    /// Only ids in `universe` count; ids outside it are ignored. An id must not be in two groups on one side (precondition).
    static func pairwise(predicted: [[String]], truth: [[String]], universe: [String]) -> PairwiseScore {
        let universeIDs = Set(universe)
        let truthSide = side(truth, universe: universeIDs)
        let predictedSide = side(predicted, universe: universeIDs)

        let truePairs = truthSide.groupSizes.reduce(0) { $0 + pairCount($1) }
        let predictedPairs = predictedSide.groupSizes.reduce(0) { $0 + pairCount($1) }
        let correctPairs = sharedCellCounts(truthSide, predictedSide).values.reduce(0) { $0 + pairCount($1) }

        return PairwiseScore(truePairs: truePairs, predictedPairs: predictedPairs, correctPairs: correctPairs)
    }

    /// Adjusted Rand index of the two partitions of `universe` (ungrouped ids are singletons).
    /// 1 for identical partitions (also when every item is a singleton on both sides).
    static func adjustedRandIndex(predicted: [[String]], truth: [[String]], universe: [String]) -> Double {
        let universeIDs = Set(universe)
        let truthSide = side(truth, universe: universeIDs)
        let predictedSide = side(predicted, universe: universeIDs)

        let itemCount = universeIDs.count
        let totalPairs = pairCount(itemCount)
        let truePairs = truthSide.groupSizes.reduce(0) { $0 + pairCount($1) }
        let predictedPairs = predictedSide.groupSizes.reduce(0) { $0 + pairCount($1) }
        let index = Double(sharedCellCounts(truthSide, predictedSide).values.reduce(0) { $0 + pairCount($1) })

        let expected = totalPairs == 0 ? 0 : Double(truePairs) * Double(predictedPairs) / Double(totalPairs)
        let maxIndex = Double(truePairs + predictedPairs) / 2
        guard maxIndex != expected else { return 1 }
        return (index - expected) / (maxIndex - expected)
    }

    static func tripMatch(predicted: [[String]], truth: [[String]]) -> TripMatchScore {
        let trueTrips = truth.map { Set($0) }
        let predictedTrips = predicted.map { Set($0) }

        guard !trueTrips.isEmpty else {
            return TripMatchScore(
                meanBestJaccard: predictedTrips.isEmpty ? 1 : 0,
                exactTrips: 0,
                missedTrips: 0,
                extraTrips: predictedTrips.count
            )
        }

        var totalBest = 0.0
        var exactTrips = 0
        var missedTrips = 0
        for trueTrip in trueTrips {
            var best = 0.0
            for predictedTrip in predictedTrips {
                best = max(best, jaccard(trueTrip, predictedTrip))
            }
            totalBest += best
            if best == 1 { exactTrips += 1 }
            if best < 0.5 { missedTrips += 1 }
        }

        var extraTrips = 0
        for predictedTrip in predictedTrips where trueTrips.allSatisfy({ $0.isDisjoint(with: predictedTrip) }) {
            extraTrips += 1
        }

        return TripMatchScore(
            meanBestJaccard: totalBest / Double(trueTrips.count),
            exactTrips: exactTrips,
            missedTrips: missedTrips,
            extraTrips: extraTrips
        )
    }

    /// Share of `universe` where "is in some group" agrees between predicted and truth (for trips: daily life vs away).
    static func membershipAgreement(predicted: [[String]], truth: [[String]], universe: [String]) -> Double {
        let universeIDs = Set(universe)
        guard !universeIDs.isEmpty else { return 1 }

        let truthGrouped = Set(truth.joined().filter { universeIDs.contains($0) })
        let predictedGrouped = Set(predicted.joined().filter { universeIDs.contains($0) })
        let matches = universeIDs.filter { truthGrouped.contains($0) == predictedGrouped.contains($0) }.count
        return Double(matches) / Double(universeIDs.count)
    }

    // MARK: - Counting helpers

    private struct CellKey: Hashable {
        let truthGroup: Int
        let predictedGroup: Int
    }

    /// Maps each id in `universe` to the first group that holds it and gives every group's size.
    private static func side(_ groups: [[String]], universe: Set<String>) -> (groupOfID: [String: Int], groupSizes: [Int]) {
        var groupOfID: [String: Int] = [:]
        var groupSizes: [Int] = []
        groupSizes.reserveCapacity(groups.count)

        for (groupIndex, group) in groups.enumerated() {
            var seenInGroup = Set<String>()
            var size = 0
            for id in group where universe.contains(id) {
                guard seenInGroup.insert(id).inserted, groupOfID[id] == nil else { continue }
                groupOfID[id] = groupIndex
                size += 1
            }
            groupSizes.append(size)
        }
        return (groupOfID, groupSizes)
    }

    /// Counts the items in each (true group, predicted group) cell.
    private static func sharedCellCounts(
        _ truth: (groupOfID: [String: Int], groupSizes: [Int]),
        _ predicted: (groupOfID: [String: Int], groupSizes: [Int])
    ) -> [CellKey: Int] {
        var cells: [CellKey: Int] = [:]
        cells.reserveCapacity(min(truth.groupOfID.count, predicted.groupOfID.count))
        for (id, truthGroup) in truth.groupOfID {
            guard let predictedGroup = predicted.groupOfID[id] else { continue }
            cells[CellKey(truthGroup: truthGroup, predictedGroup: predictedGroup), default: 0] += 1
        }
        return cells
    }

    private static func pairCount(_ count: Int) -> Int {
        count * (count - 1) / 2
    }

    private static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        let unionCount = a.union(b).count
        guard unionCount > 0 else { return 0 }
        return Double(a.intersection(b).count) / Double(unionCount)
    }
}
