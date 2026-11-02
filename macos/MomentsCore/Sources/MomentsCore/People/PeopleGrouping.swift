import Foundation

/// One face the People grouping rule can cluster.
public struct PeopleGroupingFace: Sendable {
    /// Face feature print; any length > 0. It is normalised inside.
    public let embedding: [Float]
    /// Detector capture quality, 0...1.
    public let quality: Double
    /// Faces of one photo share it.
    public let photoID: String
    /// Days since any fixed reference; nil means no date.
    public let day: Double?

    public init(embedding: [Float], quality: Double, photoID: String, day: Double?) {
        self.embedding = embedding
        self.quality = quality
        self.photoID = photoID
        self.day = day
    }
}

/// A "same person?" question, as indices into `PeopleGroupingPlan.groups`.
public struct PeopleGroupingPair: Equatable, Sendable {
    public let first: Int
    public let second: Int

    public init(first: Int, second: Int) {
        self.first = first
        self.second = second
    }
}

/// The People screen's grouping result.
public struct PeopleGroupingPlan: Equatable, Sendable {
    /// Cards, as face indices.
    public let groups: [[Int]]
    /// Asked in this order.
    public let questions: [PeopleGroupingPair]
    /// Loose faces, sorted.
    public let loose: [Int]

    public init(groups: [[Int]], questions: [PeopleGroupingPair], loose: [Int]) {
        self.groups = groups
        self.questions = questions
        self.loose = loose
    }
}

/// Thresholds of the people-grouping rule (route F1a).
///
/// The doc comment on each value keeps the Python key it was ported from, so
/// the two implementations can be compared line by line.
public struct PeopleGroupingParameters: Sendable {
    /// `q_good`: faces at least this good define the groups.
    public var qGood = 0.45
    /// `auto`: average-link cut on the good faces.
    public var auto = 0.62
    /// `attach`: poor face -> group of its nearest good face.
    public var attach = 0.55
    /// `attach_big`: ... or the centre of a big group when that centre is this close.
    public var attachBig = 0.60
    /// `attach_big_size`: a big group means at least this many faces.
    public var attachBigSize = 30
    /// `poor_auto`: poor faces that fit nowhere cluster among themselves at this cut (0 = off).
    public var poorAuto = 0.0
    /// `min_size`: groups this big are cards, smaller ones are loose faces.
    public var minSize = 3
    /// `graph_k`: neighbours per face for the graph evidence.
    public var graphK = 15
    /// `graph_cap`: a mutual kNN edge must be closer than this.
    public var graphCap = 0.55
    /// `snn_min`: ... and share at least this many near neighbours.
    public var snnMin = 4
    /// `merge_dcent`: ... and the two group centres must be closer than this.
    public var mergeDcent = 0.62
    /// `vote_min`: ... and one group's neighbours must land mostly in the other.
    public var voteMin = 0.45
    /// `absorb`: centre this close: attach on one signal alone.
    public var absorb = 0.55
    /// `absorb_wide`: up to here: attach only when two more signals agree.
    public var absorbWide = 0.72
    /// `absorb_time`: (P5) same-year look closer than this.
    public var absorbTime = 0.62
    /// `ab_vote`: (P3) share of the group's neighbours in that big group.
    public var abVote = 0.50
    /// `hint_need`: extra signals needed between `absorb` and `absorb_wide` (9 = off).
    public var hintNeed = 2
    /// `face_close`: every face of the small group this close to the big group attaches it.
    public var faceClose = 0.58
    /// `join_c`: join leftover fragments of one identity (P3 rule).
    public var joinC = 0.62
    /// `join_ds`: ... when their closest faces are this close.
    public var joinDs = 0.58
    /// `join_min`: only a join this big is worth a card.
    public var joinMin = 3
    /// `rescue_min`: loose group this big gets a question instead of being folded (0 = off).
    public var rescueMin = 0
    /// `ask_centre`: questions: P5 rules.
    public var askCentre = 0.70
    /// `ask_event`: questions: P5 rules.
    public var askEvent = 0.78
    /// `ask_time`: questions: P5 rules.
    public var askTime = 0.62
    /// `window`: days per time bucket.
    public var window = 365.0
    /// Chunk size: when there are more good faces than this, the grouping is
    /// built chunk by chunk so memory stays bounded (the Python never hits it).
    public var chunkSize = 3000

    public init() {}
}

/// The people-grouping rule chosen on synthetic libraries (route F1a), ported
/// from the Python reference so both produce the same groups, questions and
/// loose faces.
///
/// Quality gating first, then graph evidence merges big groups, small groups
/// attach on agreeing signals, leftover fragments are joined and finally the
/// remaining cards produce the "same person?" questions. The thresholds and
/// comparison operators are ported one to one; see `PeopleGroupingParameters`.
public enum PeopleGrouping {
    // MARK: - Plan

    /// nil when `shouldStop` returned true (checked between steps and inside
    /// `averageLink`).
    public static func plan(
        _ faces: [PeopleGroupingFace],
        parameters: PeopleGroupingParameters = .init(),
        shouldStop: () -> Bool = { false }
    ) -> PeopleGroupingPlan? {
        if shouldStop() { return nil }
        let p = parameters
        let faceCount = faces.count
        guard faceCount > 0 else {
            return PeopleGroupingPlan(groups: [], questions: [], loose: [])
        }
        let unit: [[Double]] = FaceGroupingMath.unitVectors(
            faces.map { (face: PeopleGroupingFace) -> [Float] in face.embedding }
        )
        let quality: [Double] = faces.map { (face: PeopleGroupingFace) -> Double in face.quality }
        let media: [String] = faces.map { (face: PeopleGroupingFace) -> String in face.photoID }
        let outing: [Int?] = faces.map { (face: PeopleGroupingFace) -> Int? in
            guard let day = face.day else { return nil }
            return floorInt(day)
        }
        let yearBucket: [Int?] = faces.map { (face: PeopleGroupingFace) -> Int? in
            guard let day = face.day, p.window > 0 else { return nil }
            return floorInt(day / p.window)
        }
        let k = max(0, min(p.graphK, faceCount - 1))

        // 1. quality gating: only good faces define groups
        var goodIndices: [Int] = []
        var poorIndices: [Int] = []
        for index in 0..<faceCount {
            if quality[index] >= p.qGood {
                goodIndices.append(index)
            } else {
                poorIndices.append(index)
            }
        }
        guard let baseGroups = groupedGoodFaces(
            goodIndices: goodIndices,
            unit: unit,
            threshold: p.auto,
            chunkSize: p.chunkSize,
            shouldStop: shouldStop
        ) else { return nil }
        var base: [[Int]] = baseGroups
        if shouldStop() { return nil }

        var groupOfFace = Array(repeating: -1, count: faceCount)
        for (gi, group) in base.enumerated() {
            for face in group where face >= 0 && face < faceCount {
                groupOfFace[face] = gi
            }
        }

        // 2. poor faces attach to the group of their nearest good face, or stand alone
        if !poorIndices.isEmpty {
            var looseFaces: [Int] = []
            if !base.isEmpty {
                var bestGoodPosition = Array(repeating: -1, count: poorIndices.count)
                var bestDistance = Array(repeating: Double.infinity, count: poorIndices.count)
                for (position, faceIndex) in poorIndices.enumerated() {
                    var nearest = -1
                    var nearestDistance = Double.infinity
                    for (goodPosition, goodIndex) in goodIndices.enumerated() {
                        let distance = FaceGroupingMath.cosineDistance(unit[faceIndex], unit[goodIndex])
                        if distance < nearestDistance {
                            nearestDistance = distance
                            nearest = goodPosition
                        }
                    }
                    bestGoodPosition[position] = nearest
                    bestDistance[position] = nearestDistance
                }
                // a big group has a stable centre, so a poor face may still join one
                let bigBase: [Int] = base.indices.filter { (index: Int) -> Bool in
                    base[index].count >= p.attachBigSize
                }
                var bigBaseCentres: [[Double]] = []
                bigBaseCentres.reserveCapacity(bigBase.count)
                for index in bigBase {
                    bigBaseCentres.append(FaceGroupingMath.centre(of: base[index], in: unit))
                }
                for (position, faceIndex) in poorIndices.enumerated() {
                    if bestDistance[position] < p.attach {
                        let nearestGoodFace = goodIndices[bestGoodPosition[position]]
                        let gi = nearestGoodFace >= 0 && nearestGoodFace < faceCount
                            ? groupOfFace[nearestGoodFace] : -1
                        if gi >= 0 {
                            base[gi].append(faceIndex)
                        } else {
                            looseFaces.append(faceIndex)
                        }
                    } else if !bigBase.isEmpty {
                        var bestGroup = -1
                        var best = Double.infinity
                        for (centreIndex, centre) in bigBaseCentres.enumerated() {
                            let distance = FaceGroupingMath.cosineDistance(centre, unit[faceIndex])
                            if distance < best {
                                best = distance
                                bestGroup = centreIndex
                            }
                        }
                        if bestGroup >= 0 && best < p.attachBig {
                            base[bigBase[bestGroup]].append(faceIndex)
                        } else {
                            looseFaces.append(faceIndex)
                        }
                    } else {
                        looseFaces.append(faceIndex)
                    }
                }
            } else {
                looseFaces = poorIndices
            }
            // `poor_auto` is 0 (off): every loose poor face becomes its own group.
            for face in looseFaces {
                base.append([face])
            }
        }
        if shouldStop() { return nil }

        var big: [[Int]] = base.filter { (group: [Int]) -> Bool in group.count >= p.minSize }
        let small: [[Int]] = base.filter { (group: [Int]) -> Bool in group.count < p.minSize }

        // graph evidence over all faces
        let neighbourResult = FaceGroupingMath.nearestNeighbours(unit, k: k)
        let neighbours = neighbourResult.indices
        let edges = FaceGroupingMath.mutualEdges(
            indices: neighbourResult.indices,
            distances: neighbourResult.distances
        )
        if shouldStop() { return nil }

        // 3. merge two big groups only on several signals at once
        if big.count > 1 {
            let stats = groupPairStats(big: big, edges: edges, cap: p.graphCap, faceCount: faceCount)
            let votes = votes(groups: big, neighbours: neighbours, k: k, faceCount: faceCount)
            var centres: [[Double]] = []
            centres.reserveCapacity(big.count)
            for group in big {
                centres.append(FaceGroupingMath.centre(of: group, in: unit))
            }
            var joinEdges: [(Int, Int)] = []
            if big.count >= 2 {
                for first in 0..<(big.count - 1) {
                    for second in (first + 1)..<big.count {
                        let key = first * big.count + second
                        let count = stats.counts[key] ?? 0
                        let snn = stats.maxSnn[key] ?? 0
                        let centreDistance = FaceGroupingMath.cosineDistance(centres[first], centres[second])
                        let vote = max(votes[first][second], votes[second][first])
                        if count >= 1 && snn >= p.snnMin && centreDistance < p.mergeDcent && vote >= p.voteMin {
                            joinEdges.append((first, second))
                        }
                    }
                }
            }
            let components = FaceGroupingMath.components(count: big.count, edges: joinEdges)
            var mergedGroups: [[Int]] = []
            var mergedIndexByComponent: [Int: Int] = [:]
            for (groupIndex, group) in big.enumerated() {
                let component = components[groupIndex]
                if let mergedIndex = mergedIndexByComponent[component] {
                    mergedGroups[mergedIndex].append(contentsOf: group)
                } else {
                    mergedIndexByComponent[component] = mergedGroups.count
                    mergedGroups.append(group)
                }
            }
            big = mergedGroups
        }
        if shouldStop() { return nil }

        // 4. small groups: attach when the evidence agrees, else fold into loose faces
        var loose: [[Int]] = []
        if !small.isEmpty && !big.isEmpty {
            var centres: [[Double]] = []
            centres.reserveCapacity(big.count)
            for group in big {
                centres.append(FaceGroupingMath.centre(of: group, in: unit))
            }
            var outingsBig: [Set<Int>] = []
            outingsBig.reserveCapacity(big.count)
            for group in big {
                outingsBig.append(outingSet(of: group, outing: outing))
            }
            var bucketsBig: [[Int: TimeBucket]] = []
            bucketsBig.reserveCapacity(big.count)
            for group in big {
                bucketsBig.append(timeBuckets(indices: group, unit: unit, yearBucket: yearBucket))
            }
            let ownerLabels = groupOwnerLabels(groups: big + small, faceCount: faceCount)
            for smallGroup in small {
                let smallCentre = FaceGroupingMath.centre(of: smallGroup, in: unit)
                var distances: [Double] = []
                distances.reserveCapacity(centres.count)
                for centre in centres {
                    distances.append(FaceGroupingMath.cosineDistance(centre, smallCentre))
                }
                let minimumDistance = distances.min() ?? Double.infinity
                if minimumDistance >= p.absorbWide && p.faceClose <= 0 {
                    loose.append(smallGroup)
                    continue
                }
                var bestBig = 0
                var bestDistance = Double.infinity
                for (index, distance) in distances.enumerated() where distance < bestDistance {
                    bestDistance = distance
                    bestBig = index
                }
                let outingsSmall = outingSet(of: smallGroup, outing: outing)
                let share = !outingsSmall.isDisjoint(with: outingsBig[bestBig])
                let timeDistance = self.timeDistance(
                    timeBuckets(indices: smallGroup, unit: unit, yearBucket: yearBucket),
                    bucketsBig[bestBig]
                )
                let vote = voteShare(
                    group: smallGroup,
                    owner: ownerLabels,
                    groupCount: big.count + small.count,
                    neighbours: neighbours,
                    k: k,
                    faceCount: faceCount,
                    column: bestBig
                )
                var hints = 0
                if share { hints += 1 }
                if timeDistance < p.absorbTime { hints += 1 }
                if vote >= p.abVote { hints += 1 }
                // every face of the small group close to the same big group is one more signal
                let perFace = worstNearestDistance(small: smallGroup, big: big[bestBig], unit: unit)
                let ok = distances[bestBig] < p.absorb
                    || timeDistance < p.absorbTime
                    || (distances[bestBig] < p.absorbWide && hints >= p.hintNeed)
                    || perFace < p.faceClose
                if ok && !sharesPhoto(big[bestBig], smallGroup, media: media) {
                    big[bestBig].append(contentsOf: smallGroup)
                } else {
                    loose.append(smallGroup)
                }
            }
        } else {
            loose = small
        }
        if shouldStop() { return nil }

        // 4b. join leftover fragments of one identity, then give the joined
        // fragment one more chance to attach.
        if loose.count > 1 && !big.isEmpty {
            var looseCentres: [[Double]] = []
            looseCentres.reserveCapacity(loose.count)
            for group in loose {
                looseCentres.append(FaceGroupingMath.centre(of: group, in: unit))
            }
            var joinEdges: [(Int, Int)] = []
            for first in 0..<(loose.count - 1) {
                for second in (first + 1)..<loose.count {
                    let centreDistance = FaceGroupingMath.cosineDistance(
                        looseCentres[first],
                        looseCentres[second]
                    )
                    if centreDistance >= p.joinC { continue }
                    var closest = Double.infinity
                    for firstFace in loose[first] {
                        for secondFace in loose[second] {
                            let distance = FaceGroupingMath.cosineDistance(unit[firstFace], unit[secondFace])
                            if distance < closest { closest = distance }
                        }
                    }
                    if closest <= p.joinDs {
                        joinEdges.append((first, second))
                    }
                }
            }
            let components = FaceGroupingMath.components(count: loose.count, edges: joinEdges)
            var joined: [[Int]] = []
            var joinedIndexByComponent: [Int: Int] = [:]
            for (groupIndex, group) in loose.enumerated() {
                let component = components[groupIndex]
                if let joinedIndex = joinedIndexByComponent[component] {
                    joined[joinedIndex].append(contentsOf: group)
                } else {
                    joinedIndexByComponent[component] = joined.count
                    joined.append(group)
                }
            }
            loose = joined
            var centres: [[Double]] = []
            centres.reserveCapacity(big.count)
            for group in big {
                centres.append(FaceGroupingMath.centre(of: group, in: unit))
            }
            let ownerLabels = groupOwnerLabels(groups: big + loose, faceCount: faceCount)
            var keep: [[Int]] = []
            for group in loose {
                let groupCentre = FaceGroupingMath.centre(of: group, in: unit)
                var distances: [Double] = []
                distances.reserveCapacity(centres.count)
                for centre in centres {
                    distances.append(FaceGroupingMath.cosineDistance(centre, groupCentre))
                }
                var bestBig = 0
                var bestDistance = Double.infinity
                for (index, distance) in distances.enumerated() where distance < bestDistance {
                    bestDistance = distance
                    bestBig = index
                }
                let share = !outingSet(of: group, outing: outing)
                    .isDisjoint(with: outingSet(of: big[bestBig], outing: outing))
                let vote = voteShare(
                    group: group,
                    owner: ownerLabels,
                    groupCount: big.count + loose.count,
                    neighbours: neighbours,
                    k: k,
                    faceCount: faceCount,
                    column: bestBig
                )
                var hints = 0
                if share { hints += 1 }
                if vote >= p.abVote { hints += 1 }
                let wantsToAttach = distances[bestBig] < p.absorb
                    || (distances[bestBig] < p.absorbWide && hints >= 2)
                if wantsToAttach && !sharesPhoto(big[bestBig], group, media: media) {
                    big[bestBig].append(contentsOf: group)
                } else {
                    keep.append(group)
                }
            }
            loose = keep
        }
        if shouldStop() { return nil }

        // `rescue_min` is 0 (off): step 4c is skipped.

        // loose groups become the flat "loose faces" list
        var folded: [Int] = []
        for group in loose {
            folded.append(contentsOf: group)
        }
        folded.sort()

        // 5. questions on the remaining cards, closest first (P5 rules)
        let cardCount = big.count
        var scored: [(score: Double, first: Int, second: Int)] = []
        if cardCount > 1 {
            var centres: [[Double]] = []
            centres.reserveCapacity(cardCount)
            for group in big {
                centres.append(FaceGroupingMath.centre(of: group, in: unit))
            }
            var outingsBig: [Set<Int>] = []
            outingsBig.reserveCapacity(cardCount)
            for group in big {
                outingsBig.append(outingSet(of: group, outing: outing))
            }
            var bucketsBig: [[Int: TimeBucket]] = []
            bucketsBig.reserveCapacity(cardCount)
            for group in big {
                bucketsBig.append(timeBuckets(indices: group, unit: unit, yearBucket: yearBucket))
            }
            for first in 0..<(cardCount - 1) {
                for second in (first + 1)..<cardCount {
                    let centreDistance = FaceGroupingMath.cosineDistance(centres[first], centres[second])
                    if centreDistance > max(p.askCentre, p.askEvent) { continue }
                    let share = !outingsBig[first].isDisjoint(with: outingsBig[second])
                    var timeDistance = Double.infinity
                    if centreDistance >= p.askCentre {
                        timeDistance = self.timeDistance(bucketsBig[first], bucketsBig[second])
                    }
                    if centreDistance >= p.askCentre && !share && !(timeDistance < p.askTime) {
                        continue
                    }
                    if centreDistance >= p.askEvent && !(timeDistance < p.askTime) {
                        continue
                    }
                    if sharesPhoto(big[first], big[second], media: media) {
                        continue
                    }
                    scored.append((min(centreDistance, timeDistance), first, second))
                }
            }
            scored.sort { (lhs: (score: Double, first: Int, second: Int),
                           rhs: (score: Double, first: Int, second: Int)) -> Bool in
                if lhs.score != rhs.score { return lhs.score < rhs.score }
                if lhs.first != rhs.first { return lhs.first < rhs.first }
                return lhs.second < rhs.second
            }
        }
        var questions: [PeopleGroupingPair] = []
        questions.reserveCapacity(scored.count)
        for entry in scored {
            questions.append(PeopleGroupingPair(first: entry.first, second: entry.second))
        }
        return PeopleGroupingPlan(groups: big, questions: questions, loose: folded)
    }

    // MARK: - Step 1: good faces into base groups

    /// Clusters the good faces with average linkage at `threshold`.
    ///
    /// More good faces than `chunkSize`: the first chunk is clustered, every
    /// other good face joins the nearest group whose centre is closer than the
    /// threshold, and the leftovers repeat the same treatment. That keeps the
    /// O(chunk^2) distance matrix bounded for 20,000+ faces; the Python
    /// reference never reaches this path.
    private static func groupedGoodFaces(
        goodIndices: [Int],
        unit: [[Double]],
        threshold: Double,
        chunkSize: Int,
        shouldStop: () -> Bool
    ) -> [[Int]]? {
        guard !goodIndices.isEmpty else { return [] }
        let limit = max(chunkSize, 1)
        if goodIndices.count <= limit {
            return clusterChunk(goodIndices, unit: unit, threshold: threshold, shouldStop: shouldStop)
        }
        let dimension = unit.first?.count ?? 0
        var groups: [[Int]] = []
        var pending = goodIndices
        while pending.count > limit {
            if shouldStop() { return nil }
            let chunk = Array(pending.prefix(limit))
            let rest = Array(pending.dropFirst(limit))
            guard let newGroups = clusterChunk(
                chunk,
                unit: unit,
                threshold: threshold,
                shouldStop: shouldStop
            ) else { return nil }
            groups.append(contentsOf: newGroups)
            // Running sums per new group keep the centre cheap while assigning.
            var sums: [[Double]] = []
            var sizes: [Int] = []
            sums.reserveCapacity(newGroups.count)
            sizes.reserveCapacity(newGroups.count)
            for group in newGroups {
                var sum = Array(repeating: 0.0, count: dimension)
                for face in group where face >= 0 && face < unit.count {
                    let row = unit[face]
                    for index in 0..<min(dimension, row.count) {
                        sum[index] += row[index]
                    }
                }
                sums.append(sum)
                sizes.append(group.count)
            }
            var leftovers: [Int] = []
            for face in rest {
                let row = unit[face]
                var bestGroup = -1
                var bestDistance = Double.infinity
                for groupIndex in newGroups.indices {
                    let centre = meanOfUnitVectors(sums[groupIndex], count: sizes[groupIndex])
                    let distance = FaceGroupingMath.cosineDistance(row, centre)
                    if distance < bestDistance {
                        bestDistance = distance
                        bestGroup = groupIndex
                    }
                }
                if bestGroup >= 0 && bestDistance < threshold {
                    let groupIndex = groups.count - newGroups.count + bestGroup
                    groups[groupIndex].append(face)
                    sizes[bestGroup] += 1
                    for index in 0..<min(dimension, row.count) {
                        sums[bestGroup][index] += row[index]
                    }
                } else {
                    leftovers.append(face)
                }
            }
            pending = leftovers
            if pending.isEmpty { break }
        }
        if !pending.isEmpty {
            guard let clusters = clusterChunk(pending, unit: unit, threshold: threshold, shouldStop: shouldStop) else {
                return nil
            }
            groups.append(contentsOf: clusters)
        }
        return groups
    }

    /// Clusters one chunk of face indices; cluster members map back to the
    /// original face indices and stay ascending.
    private static func clusterChunk(
        _ indices: [Int],
        unit: [[Double]],
        threshold: Double,
        shouldStop: () -> Bool
    ) -> [[Int]]? {
        if indices.count >= 2 {
            let rows: [[Double]] = indices.map { (index: Int) -> [Double] in unit[index] }
            let result = FaceGroupingMath.averageLink(rows, threshold: threshold, shouldStop: shouldStop)
            if result.stopped { return nil }
            return result.clusters.map { (cluster: [Int]) -> [Int] in
                cluster.map { (position: Int) -> Int in indices[position] }
            }
        } else if indices.count == 1 {
            return [indices]
        }
        return []
    }

    /// Arithmetic mean of unit vectors, not re-normalised: `1 - v·mean` is the
    /// average distance from `v` to every member of the group.
    private static func meanOfUnitVectors(_ sum: [Double], count: Int) -> [Double] {
        guard count > 0, !sum.isEmpty else { return [] }
        var mean = sum
        for index in mean.indices {
            mean[index] /= Double(count)
        }
        return mean
    }

    // MARK: - Evidence

    /// Per pair of big groups: number of mutual edges and the highest SNN, for
    /// edges closer than `cap`.
    private static func groupPairStats(
        big: [[Int]],
        edges: [FaceGroupingMath.Edge],
        cap: Double,
        faceCount: Int
    ) -> (counts: [Int: Int], maxSnn: [Int: Int]) {
        let groupCount = big.count
        var owner = Array(repeating: -1, count: faceCount)
        for (groupIndex, group) in big.enumerated() {
            for face in group where face >= 0 && face < faceCount {
                owner[face] = groupIndex
            }
        }
        var counts: [Int: Int] = [:]
        var maxSnn: [Int: Int] = [:]
        for edge in edges {
            guard edge.a >= 0, edge.a < faceCount, edge.b >= 0, edge.b < faceCount else { continue }
            let first = owner[edge.a]
            let second = owner[edge.b]
            guard first >= 0, second >= 0, first != second, edge.distance <= cap else { continue }
            let low = min(first, second)
            let high = max(first, second)
            let key = low * groupCount + high
            counts[key, default: 0] += 1
            let previous = maxSnn[key] ?? 0
            if edge.sharedNeighbours > previous {
                maxSnn[key] = edge.sharedNeighbours
            }
        }
        return (counts, maxSnn)
    }

    /// Face index -> index of the group that owns it, or -1.
    private static func groupOwnerLabels(groups: [[Int]], faceCount: Int) -> [Int] {
        var owner = Array(repeating: -1, count: faceCount)
        for (groupIndex, group) in groups.enumerated() {
            for face in group where face >= 0 && face < faceCount {
                owner[face] = groupIndex
            }
        }
        return owner
    }

    /// Share of one group's k nearest neighbours that land in every other group
    /// (a row of the Python's `_votes`, summed over the group and divided by
    /// `max(count * k, 1)`). Only the rows the rule asks for are computed, so a
    /// 20,000-face library does not build a square matrix of group counts.
    private static func voteShare(
        group: [Int],
        owner: [Int],
        groupCount: Int,
        neighbours: [[Int]],
        k: Int,
        faceCount: Int,
        column: Int
    ) -> Double {
        guard column >= 0, column < groupCount else { return 0 }
        var landed = 0
        for face in group {
            guard face >= 0, face < neighbours.count else { continue }
            for neighbour in neighbours[face] {
                guard neighbour >= 0, neighbour < faceCount else { continue }
                if owner[neighbour] == column {
                    landed += 1
                }
            }
        }
        let denominator = max(group.count * k, 1)
        return Double(landed) / Double(denominator)
    }

    /// Share of each group's k nearest neighbours that land in every other
    /// group (rows sum to <= 1). Used for the big-group merge, where the matrix
    /// is at most the number of cards squared.
    private static func votes(
        groups: [[Int]],
        neighbours: [[Int]],
        k: Int,
        faceCount: Int
    ) -> [[Double]] {
        let owner = groupOwnerLabels(groups: groups, faceCount: faceCount)
        var result: [[Double]] = []
        result.reserveCapacity(groups.count)
        for group in groups {
            var row: [Double] = []
            row.reserveCapacity(groups.count)
            for column in 0..<groups.count {
                row.append(
                    voteShare(
                        group: group,
                        owner: owner,
                        groupCount: groups.count,
                        neighbours: neighbours,
                        k: k,
                        faceCount: faceCount,
                        column: column
                    )
                )
            }
            result.append(row)
        }
        return result
    }

    private struct TimeBucket {
        let centre: [Double]
        let count: Int
    }

    /// Unit centre and size of every year bucket of a group. Faces without a
    /// date belong to no bucket.
    private static func timeBuckets(
        indices: [Int],
        unit: [[Double]],
        yearBucket: [Int?]
    ) -> [Int: TimeBucket] {
        var membersByBucket: [Int: [Int]] = [:]
        for face in indices {
            guard face >= 0, face < yearBucket.count, let bucket = yearBucket[face] else { continue }
            membersByBucket[bucket, default: []].append(face)
        }
        var result: [Int: TimeBucket] = [:]
        for (bucket, members) in membersByBucket {
            result[bucket] = TimeBucket(
                centre: FaceGroupingMath.centre(of: members, in: unit),
                count: members.count
            )
        }
        return result
    }

    /// Weighted distance over the year buckets both groups share; infinity when
    /// they share none.
    private static func timeDistance(_ first: [Int: TimeBucket], _ second: [Int: TimeBucket]) -> Double {
        var sum = 0.0
        var weightSum = 0
        for key in first.keys.sorted() {
            guard let bucketA = first[key], let bucketB = second[key] else { continue }
            let weight = min(bucketA.count, bucketB.count)
            sum += Double(weight) * FaceGroupingMath.cosineDistance(bucketA.centre, bucketB.centre)
            weightSum += weight
        }
        return weightSum > 0 ? sum / Double(weightSum) : Double.infinity
    }

    private static func outingSet(of group: [Int], outing: [Int?]) -> Set<Int> {
        var result: Set<Int> = []
        for face in group {
            guard face >= 0, face < outing.count, let value = outing[face] else { continue }
            result.insert(value)
        }
        return result
    }

    /// True when a face of `first` and a face of `second` come from the same photo.
    private static func sharesPhoto(_ first: [Int], _ second: [Int], media: [String]) -> Bool {
        var photos: Set<String> = []
        for face in first where face >= 0 && face < media.count {
            photos.insert(media[face])
        }
        for face in second where face >= 0 && face < media.count {
            if photos.contains(media[face]) {
                return true
            }
        }
        return false
    }

    /// The worst face of `small`: its distance to the nearest face of `big`.
    private static func worstNearestDistance(small: [Int], big: [Int], unit: [[Double]]) -> Double {
        var worst = Double.infinity
        var hasFace = false
        for smallFace in small where smallFace >= 0 && smallFace < unit.count {
            var nearest = Double.infinity
            for bigFace in big where bigFace >= 0 && bigFace < unit.count {
                let distance = FaceGroupingMath.cosineDistance(unit[smallFace], unit[bigFace])
                if distance < nearest { nearest = distance }
            }
            if !hasFace {
                worst = nearest
                hasFace = true
            } else if nearest > worst {
                worst = nearest
            }
        }
        return worst
    }

    private static func floorInt(_ value: Double) -> Int? {
        guard value.isFinite else { return nil }
        let rounded = value.rounded(.down)
        guard rounded >= Double(Int.min), rounded <= Double(Int.max) else { return nil }
        return Int(rounded)
    }
}
