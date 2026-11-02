import Foundation
import XCTest
@testable import MomentsCore

final class FaceGroupingMathTests: XCTestCase {
    // MARK: - Helpers

    /// A tiny deterministic linear congruential generator (Numerical Recipes
    /// constants) so every run builds the same synthetic vectors.
    private struct LCG {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        /// Next value in [0, 1).
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }

        /// Next value in [-1, 1).
        mutating func nextSigned() -> Double {
            next() * 2 - 1
        }

        mutating func vector(dimension: Int) -> [Float] {
            var values: [Float] = []
            values.reserveCapacity(dimension)
            for _ in 0..<dimension {
                values.append(Float(nextSigned()))
            }
            return values
        }
    }

    /// Sorts each cluster and orders the clusters by their smallest member.
    private func canonical(_ clusters: [[Int]]) -> [[Int]] {
        let sortedMembers: [[Int]] = clusters.map { (cluster: [Int]) -> [Int] in cluster.sorted() }
        return sortedMembers.sorted { (lhs: [Int], rhs: [Int]) -> Bool in
            (lhs.first ?? -1) < (rhs.first ?? -1)
        }
    }

    /// Naive O(n^3) average-link clustering: repeatedly merge the closest pair
    /// of clusters (mean pairwise distance) while that distance is < threshold.
    private func bruteForceAverageLink(_ unit: [[Double]], threshold: Double) -> [[Int]] {
        var clusters: [[Int]] = unit.indices.map { (index: Int) -> [Int] in [index] }

        func meanDistance(_ lhs: [Int], _ rhs: [Int]) -> Double {
            var total = 0.0
            var pairs = 0
            for left in lhs {
                for right in rhs {
                    total += FaceGroupingMath.cosineDistance(unit[left], unit[right])
                    pairs += 1
                }
            }
            guard pairs > 0 else { return Double.infinity }
            return total / Double(pairs)
        }

        while clusters.count > 1 {
            var bestLeft = -1
            var bestRight = -1
            var bestDistance = Double.infinity
            for left in 0..<clusters.count {
                for right in (left + 1)..<clusters.count {
                    let distance = meanDistance(clusters[left], clusters[right])
                    if distance < bestDistance {
                        bestDistance = distance
                        bestLeft = left
                        bestRight = right
                    }
                }
            }
            guard bestLeft >= 0, bestRight >= 0, bestDistance < threshold else { break }
            clusters[bestLeft].append(contentsOf: clusters[bestRight])
            clusters.remove(at: bestRight)
        }
        return canonical(clusters)
    }

    /// Naive k-nearest neighbours per row: every other row, sorted by
    /// (distance, index), then cut to k.
    private func bruteForceNeighbours(_ unit: [[Double]], k: Int) -> (indices: [[Int]], distances: [[Double]]) {
        let limit = max(0, min(k, unit.count - 1))
        var indices = Array(repeating: [Int](), count: unit.count)
        var distances = Array(repeating: [Double](), count: unit.count)
        for row in unit.indices {
            var candidates: [(distance: Double, index: Int)] = []
            for other in unit.indices where other != row {
                let distance = FaceGroupingMath.cosineDistance(unit[row], unit[other])
                candidates.append((distance: distance, index: other))
            }
            candidates.sort { (lhs: (distance: Double, index: Int), rhs: (distance: Double, index: Int)) -> Bool in
                if lhs.distance == rhs.distance { return lhs.index < rhs.index }
                return lhs.distance < rhs.distance
            }
            for position in 0..<limit {
                indices[row].append(candidates[position].index)
                distances[row].append(candidates[position].distance)
            }
        }
        return (indices, distances)
    }

    private func unitVector(angle: Double) -> [Float] {
        [Float(cos(angle)), Float(sin(angle))]
    }

    // MARK: - Tests

    func testAverageLinkMatchesBruteForce() {
        let thresholds: [Double] = [0.3, 0.6, 0.9]
        let seeds: [UInt64] = [1, 7, 42]
        var mergedAnything = false
        var keptSingletons = false
        for seed in seeds {
            var generator = LCG(seed: seed)
            var vectors: [[Float]] = []
            vectors.reserveCapacity(40)
            for _ in 0..<40 {
                vectors.append(generator.vector(dimension: 8))
            }
            let unit: [[Double]] = FaceGroupingMath.unitVectors(vectors)
            for threshold in thresholds {
                let actual: [[Int]] = canonical(FaceGroupingMath.averageLink(unit, threshold: threshold).clusters)
                let expected: [[Int]] = bruteForceAverageLink(unit, threshold: threshold)
                XCTAssertEqual(
                    actual,
                    expected,
                    "averageLink differs from brute force for seed \(seed), threshold \(threshold)"
                )
                if actual.count < 40 { mergedAnything = true }
                if actual.count > 1 { keptSingletons = true }
            }
        }
        // The comparison is only meaningful if the thresholds actually split and
        // merge something.
        XCTAssertTrue(mergedAnything, "no threshold merged any vector")
        XCTAssertTrue(keptSingletons, "no threshold kept clusters apart")
    }

    func testAverageLinkStops() {
        var generator = LCG(seed: 3)
        var vectors: [[Float]] = []
        for _ in 0..<10 {
            vectors.append(generator.vector(dimension: 4))
        }
        let unit: [[Double]] = FaceGroupingMath.unitVectors(vectors)
        let result: FaceGroupingMath.AverageLinkResult = FaceGroupingMath.averageLink(
            unit,
            threshold: 0.9,
            shouldStop: { () -> Bool in true }
        )
        XCTAssertTrue(result.stopped)
        XCTAssertEqual(result.clusters, [[Int]]())
        // Edge cases: nothing to cluster, one row, and a threshold below every
        // cosine distance (which is >= 0), so nothing may merge.
        let empty: FaceGroupingMath.AverageLinkResult = FaceGroupingMath.averageLink([], threshold: 0.9)
        XCTAssertEqual(empty, FaceGroupingMath.AverageLinkResult(clusters: [], stopped: false))
        let single: FaceGroupingMath.AverageLinkResult = FaceGroupingMath.averageLink([unit[0]], threshold: 0.9)
        XCTAssertEqual(single, FaceGroupingMath.AverageLinkResult(clusters: [[0]], stopped: false))
        let noMerge: [[Int]] = FaceGroupingMath.averageLink(unit, threshold: -1).clusters
        XCTAssertEqual(noMerge.count, 10)
        for row in 0..<10 {
            XCTAssertEqual(noMerge[row], [row])
        }
    }

    func testNearestNeighboursMatchBruteForce() {
        var generator = LCG(seed: 11)
        var vectors: [[Float]] = []
        vectors.reserveCapacity(30)
        for _ in 0..<30 {
            vectors.append(generator.vector(dimension: 6))
        }
        let unit: [[Double]] = FaceGroupingMath.unitVectors(vectors)
        let k = 5
        let actual = FaceGroupingMath.nearestNeighbours(unit, k: k)
        let expected = bruteForceNeighbours(unit, k: k)
        XCTAssertEqual(actual.indices.count, 30)
        XCTAssertEqual(actual.distances.count, 30)
        XCTAssertEqual(actual.indices, expected.indices)
        XCTAssertEqual(actual.distances, expected.distances)
        for row in 0..<30 {
            XCTAssertEqual(actual.indices[row].count, k)
            XCTAssertEqual(actual.distances[row].count, k)
            XCTAssertFalse(actual.indices[row].contains(row), "row \(row) lists itself")
            for position in 1..<k {
                XCTAssertLessThanOrEqual(actual.distances[row][position - 1], actual.distances[row][position])
            }
            for position in 0..<k {
                let other = actual.indices[row][position]
                let distance: Double = FaceGroupingMath.cosineDistance(unit[row], unit[other])
                XCTAssertEqual(actual.distances[row][position], distance, accuracy: 1e-12)
            }
        }
        // k is clamped to count - 1, and never negative.
        let clamped = FaceGroupingMath.nearestNeighbours(unit, k: 100)
        for row in 0..<30 {
            XCTAssertEqual(clamped.indices[row].count, 29)
            XCTAssertEqual(clamped.distances[row].count, 29)
            XCTAssertEqual(Set(clamped.indices[row]).count, 29)
        }
        let none = FaceGroupingMath.nearestNeighbours(unit, k: 0)
        for row in 0..<30 {
            XCTAssertTrue(none.indices[row].isEmpty)
            XCTAssertTrue(none.distances[row].isEmpty)
        }
        let negative = FaceGroupingMath.nearestNeighbours(unit, k: -3)
        for row in 0..<30 {
            XCTAssertTrue(negative.indices[row].isEmpty)
            XCTAssertTrue(negative.distances[row].isEmpty)
        }
    }

    func testMutualEdgesAndSharedNeighbours() {
        // Two tight triangles of 2-d unit vectors, one around angle 0 and one
        // around angle pi, so every point's two nearest neighbours are its
        // triangle mates.
        let angles: [Double] = [0, 0.05, 0.1, Double.pi, Double.pi + 0.05, Double.pi + 0.1]
        let vectors: [[Float]] = angles.map { (angle: Double) -> [Float] in unitVector(angle: angle) }
        let unit: [[Double]] = FaceGroupingMath.unitVectors(vectors)
        let neighbours = FaceGroupingMath.nearestNeighbours(unit, k: 2)
        let edges: [FaceGroupingMath.Edge] = FaceGroupingMath.mutualEdges(
            indices: neighbours.indices,
            distances: neighbours.distances
        )
        let expectedPairs: [(Int, Int)] = [(0, 1), (0, 2), (1, 2), (3, 4), (3, 5), (4, 5)]
        let actualPairs: [(Int, Int)] = edges.map { (edge: FaceGroupingMath.Edge) -> (Int, Int) in (edge.a, edge.b) }
        XCTAssertEqual(actualPairs.count, 6, "expected exactly the 6 within-triangle edges, got \(actualPairs)")
        for pair in expectedPairs {
            XCTAssertTrue(
                actualPairs.contains { (candidate: (Int, Int)) -> Bool in candidate.0 == pair.0 && candidate.1 == pair.1 },
                "missing edge \(pair)"
            )
        }
        XCTAssertEqual(edges.map { (edge: FaceGroupingMath.Edge) -> Int in edge.sharedNeighbours }, [1, 1, 1, 1, 1, 1])
        for edge in edges {
            XCTAssertLessThan(edge.a, edge.b)
            let expected: Double = FaceGroupingMath.cosineDistance(unit[edge.a], unit[edge.b])
            XCTAssertEqual(edge.distance, expected, accuracy: 1e-12)
        }
        // Sorted by (a, b).
        for position in 1..<edges.count {
            let previous = edges[position - 1]
            let current = edges[position]
            XCTAssertTrue(previous.a < current.a || (previous.a == current.a && previous.b < current.b))
        }
        // Without the nearest-neighbour restriction the same two triangles give
        // the same six mutual edges, so the distance values are not accidental.
        for edge in edges {
            XCTAssertLessThan(edge.distance, 0.01)
        }
        // The centre of each triangle is a unit vector pointing at its angle.
        let firstCentre: [Double] = FaceGroupingMath.centre(of: [0, 1, 2], in: unit)
        let secondCentre: [Double] = FaceGroupingMath.centre(of: [3, 4, 5], in: unit)
        XCTAssertEqual(firstCentre.count, 2)
        XCTAssertEqual(secondCentre.count, 2)
        let firstLength: Double = (firstCentre[0] * firstCentre[0] + firstCentre[1] * firstCentre[1]).squareRoot()
        XCTAssertEqual(firstLength, 1, accuracy: 1e-12)
        XCTAssertGreaterThan(firstCentre[0], 0.99)
        XCTAssertLessThan(secondCentre[0], -0.99)
        // Unit length survives the average, so the centre of one row is that row.
        XCTAssertEqual(FaceGroupingMath.centre(of: [0], in: unit)[0], unit[0][0], accuracy: 1e-12)
        XCTAssertEqual(FaceGroupingMath.centre(of: [Int](), in: unit), [Double]())
        XCTAssertEqual(FaceGroupingMath.centre(of: [99], in: unit), [Double]())
        // A zero vector stays zero in unitVectors and the centre of zeros is zero.
        let zeros: [[Double]] = FaceGroupingMath.unitVectors([[0, 0, 0], [3, 0, 0]])
        XCTAssertEqual(zeros[0], [0, 0, 0])
        XCTAssertEqual(zeros[1], [1, 0, 0])
        XCTAssertEqual(FaceGroupingMath.centre(of: [0], in: zeros), [0, 0, 0])
        // cosineDistance rejects mismatched or empty input.
        XCTAssertEqual(FaceGroupingMath.cosineDistance([1, 0], [0, 1]), 1, accuracy: 1e-12)
        XCTAssertEqual(FaceGroupingMath.cosineDistance([], []), 1, accuracy: 1e-12)
        XCTAssertEqual(FaceGroupingMath.cosineDistance([1, 0], [1, 0, 0]), 1, accuracy: 1e-12)
        // Deliberately asymmetric hand-built lists: 1 names 2 but 2 does not
        // name 1, so (1, 2) is not an edge. The mutual pairs are (0, 2), (1, 3)
        // and (2, 3); only (1, 3) shares a neighbour (2).
        let asymmetricIndices: [[Int]] = [[1, 2], [2, 3], [0, 3], [1, 2]]
        let asymmetricDistances: [[Double]] = [[0.1, 0.2], [0.15, 0.25], [0.2, 0.3], [0.25, 0.3]]
        let asymmetricEdges: [FaceGroupingMath.Edge] = FaceGroupingMath.mutualEdges(
            indices: asymmetricIndices,
            distances: asymmetricDistances
        )
        let asymmetricPairs: [(Int, Int)] = asymmetricEdges.map { (edge: FaceGroupingMath.Edge) -> (Int, Int) in
            (edge.a, edge.b)
        }
        XCTAssertEqual(asymmetricPairs.map { (pair: (Int, Int)) -> Int in pair.0 }, [0, 1, 2])
        XCTAssertEqual(asymmetricPairs.map { (pair: (Int, Int)) -> Int in pair.1 }, [2, 3, 3])
        XCTAssertEqual(asymmetricEdges[0].distance, 0.2, accuracy: 1e-12)
        XCTAssertEqual(asymmetricEdges[0].sharedNeighbours, 0)
        XCTAssertEqual(asymmetricEdges[1].sharedNeighbours, 1)
        XCTAssertTrue(FaceGroupingMath.mutualEdges(indices: [], distances: []).isEmpty)
    }

    func testComponentsLabelsBySmallestNode() {
        let labels: [Int] = FaceGroupingMath.components(count: 6, edges: [(4, 5), (1, 3)])
        XCTAssertEqual(labels, [0, 1, 2, 1, 3, 3])
        XCTAssertEqual(FaceGroupingMath.components(count: 0, edges: []), [Int]())
        XCTAssertEqual(FaceGroupingMath.components(count: 3, edges: []), [0, 1, 2])
        XCTAssertEqual(FaceGroupingMath.components(count: 3, edges: [(0, 1), (1, 2)]), [0, 0, 0])
    }
}
