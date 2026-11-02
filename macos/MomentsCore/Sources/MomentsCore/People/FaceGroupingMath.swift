import Foundation

/// Pure vector maths for the People screen's face grouping.
///
/// Face feature prints arrive as `[Float]`, but every distance is computed in
/// `Double` so the grouping matches the numpy reference implementation the rule
/// was designed with. Nothing here touches Apple frameworks, so Linux CI can
/// test it.
public enum FaceGroupingMath {
    // MARK: - Vectors

    /// Unit-length copy of each vector, in Double. A zero vector stays zero.
    public static func unitVectors(_ vectors: [[Float]]) -> [[Double]] {
        var result: [[Double]] = []
        result.reserveCapacity(vectors.count)
        for vector in vectors {
            var sum = 0.0
            for value in vector {
                let doubleValue = Double(value)
                sum += doubleValue * doubleValue
            }
            let norm = sum.squareRoot()
            if norm > 0 {
                var unit: [Double] = []
                unit.reserveCapacity(vector.count)
                for value in vector {
                    unit.append(Double(value) / norm)
                }
                result.append(unit)
            } else {
                result.append(vector.map { (value: Float) -> Double in Double(value) })
            }
        }
        return result
    }

    /// 1 - dot(a, b) for unit vectors.
    public static func cosineDistance(_ a: [Double], _ b: [Double]) -> Double {
        guard !a.isEmpty, a.count == b.count else { return 1 }
        var dot = 0.0
        for index in a.indices {
            dot += a[index] * b[index]
        }
        return 1 - dot
    }

    /// Unit-length mean of the given rows (the "centre" of a group).
    ///
    /// Rows outside `unit` or of a different dimension are ignored; an empty
    /// result means there was nothing to average. Averaging zero vectors gives
    /// the zero vector back.
    public static func centre(of rows: [Int], in unit: [[Double]]) -> [Double] {
        guard let first = rows.first(where: { (row: Int) -> Bool in row >= 0 && row < unit.count }),
              unit[first].count > 0
        else { return [] }
        let dimension = unit[first].count
        var sum = Array(repeating: 0.0, count: dimension)
        var used = 0
        for row in rows where row >= 0 && row < unit.count && unit[row].count == dimension {
            for index in 0..<dimension {
                sum[index] += unit[row][index]
            }
            used += 1
        }
        guard used > 0 else { return [] }
        var squaredLength = 0.0
        for index in 0..<dimension {
            sum[index] /= Double(used)
            squaredLength += sum[index] * sum[index]
        }
        let length = squaredLength.squareRoot()
        guard length > 0 else { return sum }
        for index in 0..<dimension {
            sum[index] /= length
        }
        return sum
    }

    // MARK: - Average-link clustering

    public struct AverageLinkResult: Equatable, Sendable {
        public let clusters: [[Int]]
        public let stopped: Bool

        public init(clusters: [[Int]], stopped: Bool) {
            self.clusters = clusters
            self.stopped = stopped
        }
    }

    /// Average-link agglomerative clustering on cosine distance; two clusters
    /// merge while their average distance is < `threshold` (same result as
    /// scipy `linkage(method: "average")` + `fcluster(t, "distance")` up to
    /// exact ties).
    ///
    /// Uses the same nearest-neighbour-chain algorithm as the app's
    /// `FaceClustering`, but with a `Double` triangular matrix. Average linkage
    /// is reducible, so merging reciprocal nearest neighbours in any order gives
    /// the textbook result, and a cluster whose nearest neighbour is at or above
    /// the threshold can never merge again.
    ///
    /// Clusters are canonical: each cluster's members are sorted ascending and
    /// the clusters are ordered by their smallest member (the same order scipy's
    /// `fcluster` produces after relabelling).
    ///
    /// `shouldStop` is checked every 64 steps (the app's version reads power
    /// state there); when it returns true the result has `stopped == true` and
    /// `clusters == []`.
    public static func averageLink(
        _ unit: [[Double]],
        threshold: Double,
        shouldStop: () -> Bool = { false }
    ) -> AverageLinkResult {
        guard !unit.isEmpty else { return AverageLinkResult(clusters: [], stopped: false) }
        let count = unit.count
        var clusters: [[Int]] = unit.indices.map { (index: Int) -> [Int] in [index] }
        var sizes = Array(repeating: 1, count: count)
        var active = Array(repeating: true, count: count)
        var finished = Array(repeating: false, count: count)
        var distances = Array(repeating: Double.infinity, count: count * max(count - 1, 0) / 2)
        func offset(_ a: Int, _ b: Int) -> Int {
            let i = min(a, b)
            let j = max(a, b)
            return i * count - i * (i + 1) / 2 + j - i - 1
        }
        for i in 0..<count {
            for j in (i + 1)..<count {
                distances[offset(i, j)] = cosineDistance(unit[i], unit[j])
            }
        }
        var chain: [Int] = []
        var nextStart = 0
        var steps = 0
        var stopped = false
        while true {
            if chain.isEmpty {
                while nextStart < count && (!active[nextStart] || finished[nextStart]) { nextStart += 1 }
                guard nextStart < count else { break }
                chain.append(nextStart)
            }
            steps += 1
            // The stop check is a power-state read in the app, so every 64 steps.
            if steps % 64 == 1 && shouldStop() {
                stopped = true
                break
            }
            let current = chain[chain.count - 1]
            let previous = chain.count >= 2 ? chain[chain.count - 2] : -1
            var nearest = -1
            var nearestDistance = Double.infinity
            for k in 0..<count where active[k] && k != current {
                let d = distances[offset(current, k)]
                if d < nearestDistance {
                    nearestDistance = d
                    nearest = k
                }
            }
            // Prefer the previous chain element on ties so the chain always terminates.
            if previous >= 0, distances[offset(current, previous)] <= nearestDistance {
                nearest = previous
                nearestDistance = distances[offset(current, previous)]
            }
            guard nearest >= 0, nearestDistance < threshold else {
                finished[current] = true
                chain.removeLast()
                continue
            }
            guard nearest == previous else {
                chain.append(nearest)
                continue
            }
            chain.removeLast(2)
            let keep = min(current, previous)
            let drop = max(current, previous)
            let keepSize = sizes[keep]
            let dropSize = sizes[drop]
            for k in 0..<count where active[k] && k != keep && k != drop {
                // Lance–Williams update for average linkage.
                let merged = (Double(keepSize) * distances[offset(keep, k)]
                    + Double(dropSize) * distances[offset(drop, k)]) / Double(keepSize + dropSize)
                distances[offset(keep, k)] = merged
            }
            clusters[keep].append(contentsOf: clusters[drop])
            clusters[drop] = []
            sizes[keep] += dropSize
            active[drop] = false
            if keep < nextStart { nextStart = keep }
        }
        // A stopped run has no result: the caller asked to abandon the work.
        if stopped { return AverageLinkResult(clusters: [], stopped: true) }
        let result: [[Int]] = clusters.indices.compactMap { (index: Int) -> [Int]? in
            guard active[index] else { return nil }
            return clusters[index].sorted()
        }
        let ordered = result.sorted { (lhs: [Int], rhs: [Int]) -> Bool in
            (lhs.first ?? 0) < (rhs.first ?? 0)
        }
        return AverageLinkResult(clusters: ordered, stopped: stopped)
    }

    // MARK: - Nearest neighbours

    /// The k nearest other rows of every row by cosine distance, nearest first
    /// (self excluded). `k` is clamped to `count - 1` (and to at least zero).
    /// Returns indices and distances with the same shape.
    public static func nearestNeighbours(_ unit: [[Double]], k: Int) -> (indices: [[Int]], distances: [[Double]]) {
        let count = unit.count
        let limit = max(0, min(k, count - 1))
        var indices = Array(repeating: [Int](), count: count)
        var distances = Array(repeating: [Double](), count: count)
        guard limit > 0 else { return (indices, distances) }
        for row in 0..<count {
            var pairs: [(distance: Double, index: Int)] = []
            pairs.reserveCapacity(count - 1)
            for other in 0..<count where other != row {
                pairs.append((distance: cosineDistance(unit[row], unit[other]), index: other))
            }
            pairs.sort { (lhs: (distance: Double, index: Int), rhs: (distance: Double, index: Int)) -> Bool in
                if lhs.distance == rhs.distance { return lhs.index < rhs.index }
                return lhs.distance < rhs.distance
            }
            let take = min(limit, pairs.count)
            var rowIndices: [Int] = []
            var rowDistances: [Double] = []
            rowIndices.reserveCapacity(take)
            rowDistances.reserveCapacity(take)
            for position in 0..<take {
                rowIndices.append(pairs[position].index)
                rowDistances.append(pairs[position].distance)
            }
            indices[row] = rowIndices
            distances[row] = rowDistances
        }
        return (indices, distances)
    }

    // MARK: - Mutual edges and components

    public struct Edge: Equatable, Sendable {
        public let a: Int
        public let b: Int
        public let distance: Double
        public let sharedNeighbours: Int

        public init(a: Int, b: Int, distance: Double, sharedNeighbours: Int) {
            self.a = a
            self.b = b
            self.distance = distance
            self.sharedNeighbours = sharedNeighbours
        }
    }

    /// Mutual k-nearest-neighbour edges, `a < b`: `b` is in `a`'s list AND `a`
    /// is in `b`'s list. `sharedNeighbours` is how many of `a`'s k neighbours
    /// also appear in `b`'s k neighbours. Sorted by `(a, b)`.
    ///
    /// `distance` comes from `a`'s list, matching the numpy reference
    /// (`dd = nd.ravel()`, kept where `src < dst`). Rows are read defensively:
    /// a `distances` row shorter than its `indices` row yields `+infinity`, and
    /// out-of-range neighbour indices are skipped.
    public static func mutualEdges(indices: [[Int]], distances: [[Double]]) -> [Edge] {
        let count = indices.count
        var neighbourSets: [Set<Int>] = []
        neighbourSets.reserveCapacity(count)
        for row in indices {
            neighbourSets.append(Set(row))
        }
        var edges: [Edge] = []
        for a in 0..<count {
            let row = indices[a]
            let rowDistances = a < distances.count ? distances[a] : []
            for position in 0..<row.count {
                let b = row[position]
                guard b > a, b < count, neighbourSets[b].contains(a) else { continue }
                let distance = position < rowDistances.count ? rowDistances[position] : Double.infinity
                // Counted over a's own list, like the numpy reference
                // (`sum over t of (A == B[t]).any()`, where B is a's list), so a
                // repeated entry in a hand-built row would count more than once.
                var shared = 0
                for candidate in row where neighbourSets[b].contains(candidate) {
                    shared += 1
                }
                edges.append(Edge(a: a, b: b, distance: distance, sharedNeighbours: shared))
            }
        }
        edges.sort { (lhs: Edge, rhs: Edge) -> Bool in
            if lhs.a == rhs.a { return lhs.b < rhs.b }
            return lhs.a < rhs.a
        }
        return edges
    }

    /// Connected components of `count` nodes under undirected edges. Returns one
    /// label per node, labels `0..<count`, numbered in order of each component's
    /// smallest node.
    public static func components(count: Int, edges: [(Int, Int)]) -> [Int] {
        guard count > 0 else { return [] }
        var parent = Array(0..<count)
        func find(_ node: Int) -> Int {
            var root = node
            while parent[root] != root { root = parent[root] }
            var current = node
            while parent[current] != current {
                let next = parent[current]
                parent[current] = root
                current = next
            }
            return root
        }
        for edge in edges {
            let a = edge.0
            let b = edge.1
            guard a >= 0, a < count, b >= 0, b < count else { continue }
            let rootA = find(a)
            let rootB = find(b)
            if rootA != rootB {
                if rootA < rootB {
                    parent[rootB] = rootA
                } else {
                    parent[rootA] = rootB
                }
            }
        }
        var labelByRoot: [Int: Int] = [:]
        var labels = Array(repeating: -1, count: count)
        var nextLabel = 0
        for node in 0..<count {
            let root = find(node)
            if let label = labelByRoot[root] {
                labels[node] = label
            } else {
                labelByRoot[root] = nextLabel
                labels[node] = nextLabel
                nextLabel += 1
            }
        }
        return labels
    }
}
