import Foundation

/// One face the People assignment planner maps onto a person, an unnamed card
/// or a loose face.
public struct PeoplePlannerFace: Sendable {
    /// FaceObservation id (unique, opaque).
    public let id: String
    /// Face feature print; any length > 0. It is normalised inside.
    public let embedding: [Float]
    /// Detector capture quality, 0...1.
    public let quality: Double
    /// Faces of one photo share it.
    public let photoID: String
    /// Days since any fixed reference; nil means no date.
    public let day: Double?
    /// Current person, if any.
    public let personID: String?
    /// Confirmed by the owner: never moved.
    public let isUserConfirmed: Bool
    /// Person ids the owner rejected for this face ("not this person").
    public let rejectedPersonIDs: Set<String>

    public init(
        id: String,
        embedding: [Float],
        quality: Double,
        photoID: String,
        day: Double?,
        personID: String?,
        isUserConfirmed: Bool,
        rejectedPersonIDs: Set<String>
    ) {
        self.id = id
        self.embedding = embedding
        self.quality = quality
        self.photoID = photoID
        self.day = day
        self.personID = personID
        self.isUserConfirmed = isUserConfirmed
        self.rejectedPersonIDs = rejectedPersonIDs
    }
}

/// Where one face ends up after the grouping plan is mapped onto people.
public struct PeoplePlannerAssignment: Equatable, Sendable {
    public let faceID: String
    /// nil = not a named person.
    public let personID: String?
    /// "cluster-<id>" unnamed card, "loose-<faceID>" loose face, nil when
    /// `personID != nil`.
    public let clusterID: String?

    public init(faceID: String, personID: String?, clusterID: String?) {
        self.faceID = faceID
        self.personID = personID
        self.clusterID = clusterID
    }
}

/// One side of a "same person?" question: a named person or an unnamed card.
public enum PeoplePlannerSide: Equatable, Hashable, Sendable {
    case person(String)
    case cluster(String)
}

/// A "same person?" question between two cards, mapped to sides.
public struct PeoplePlannerQuestion: Equatable, Sendable {
    public let first: PeoplePlannerSide
    public let second: PeoplePlannerSide

    public init(first: PeoplePlannerSide, second: PeoplePlannerSide) {
        self.first = first
        self.second = second
    }
}

/// The per-face assignments and the remaining questions.
public struct PeoplePlannerResult: Equatable, Sendable {
    /// One per input face, same order.
    public let assignments: [PeoplePlannerAssignment]
    /// In the plan's order, deduplicated.
    public let questions: [PeoplePlannerQuestion]

    public init(assignments: [PeoplePlannerAssignment], questions: [PeoplePlannerQuestion]) {
        self.assignments = assignments
        self.questions = questions
    }
}

/// Maps `PeopleGrouping.plan` onto every face: confirmed faces keep their
/// person, single-person cards pull their faces to that person, unnamed cards
/// become clusters, same-photo faces are split, loose faces may join a nearby
/// confirmed person and card questions become person/cluster questions.
///
/// Pure: Foundation only, so Linux CI can test it.
public enum PeopleAssignmentPlanner {
    // MARK: - Pair keys

    /// The two side keys sorted and joined by "|", e.g.
    /// "cluster:cluster-a|person:p1".
    public static func pairKey(_ a: PeoplePlannerSide, _ b: PeoplePlannerSide) -> String {
        let keys: [String] = [sideKey(a), sideKey(b)].sorted()
        return keys.joined(separator: "|")
    }

    /// "person:<id>" or "cluster:<id>".
    private static func sideKey(_ side: PeoplePlannerSide) -> String {
        switch side {
        case .person(let id):
            return "person:\(id)"
        case .cluster(let id):
            return "cluster:\(id)"
        }
    }

    // MARK: - Plan

    /// nil when the grouping plan was stopped.
    public static func plan(
        _ faces: [PeoplePlannerFace],
        declinedPairs: Set<String> = [],
        parameters: PeopleGroupingParameters = .init(),
        personAttach: Double = 0.55,
        shouldStop: () -> Bool = { false }
    ) -> PeoplePlannerResult? {
        if shouldStop() { return nil }
        let groupingFaces: [PeopleGroupingFace] = faces.map { (face: PeoplePlannerFace) -> PeopleGroupingFace in
            PeopleGroupingFace(
                embedding: face.embedding,
                quality: face.quality,
                photoID: face.photoID,
                day: face.day
            )
        }
        guard let groupingPlan = PeopleGrouping.plan(
            groupingFaces,
            parameters: parameters,
            shouldStop: shouldStop
        ) else { return nil }
        if shouldStop() { return nil }

        let unit: [[Double]] = FaceGroupingMath.unitVectors(
            faces.map { (face: PeoplePlannerFace) -> [Float] in face.embedding }
        )
        let personCentres: [String: [Double]] = confirmedPersonCentres(faces: faces, unit: unit)
        let personIDs: [String] = personCentres.keys.sorted()

        // Rule 2: confirmed faces keep their person from the start.
        var outputPerson: [String?] = faces.map { (face: PeoplePlannerFace) -> String? in
            face.isUserConfirmed ? face.personID : nil
        }
        var outputCluster: [String?] = Array(repeating: nil, count: faces.count)
        var settled: [Bool] = faces.map { (face: PeoplePlannerFace) -> Bool in face.isUserConfirmed }

        let cards: [CardFacts] = groupingPlan.groups.map { (group: [Int]) -> CardFacts in
            cardFacts(group: group, faces: faces)
        }

        // Rule 3: each card pulls or hands out its people.
        for (cardIndex, group) in groupingPlan.groups.enumerated() {
            let card = cards[cardIndex]
            if card.personIDs.count == 1 {
                let person = card.personIDs[0]
                for index in group where !faces[index].isUserConfirmed {
                    // A rejected person never comes back; the face stays loose
                    // for rule 5.
                    guard !faces[index].rejectedPersonIDs.contains(person) else { continue }
                    outputPerson[index] = person
                    outputCluster[index] = nil
                    settled[index] = true
                }
            } else if card.personIDs.isEmpty {
                guard let clusterID = card.clusterID else { continue }
                for index in group where !faces[index].isUserConfirmed {
                    outputPerson[index] = nil
                    outputCluster[index] = clusterID
                    settled[index] = true
                }
            } else {
                for index in group where !faces[index].isUserConfirmed {
                    var bestPerson: String? = nil
                    var bestDistance = Double.infinity
                    for person in card.personIDs where !faces[index].rejectedPersonIDs.contains(person) {
                        guard let centre = personCentres[person] else { continue }
                        let distance = FaceGroupingMath.cosineDistance(centre, unit[index])
                        if distance < bestDistance {
                            bestDistance = distance
                            bestPerson = person
                        }
                    }
                    // Every person rejected: the face becomes loose (rule 5).
                    guard let person = bestPerson else { continue }
                    outputPerson[index] = person
                    outputCluster[index] = nil
                    settled[index] = true
                }
            }
        }
        if shouldStop() { return nil }

        // Rule 4: one person (or one unnamed card) appears at most once per
        // photo. Confirmed faces stay; otherwise the face closest to the
        // group's centre stays (ties: smaller face id).
        var personMembers: [String: [Int]] = [:]
        var clusterMembers: [String: [Int]] = [:]
        for index in faces.indices {
            if let person = outputPerson[index] {
                personMembers[person, default: []].append(index)
            } else if let cluster = outputCluster[index] {
                clusterMembers[cluster, default: []].append(index)
            }
        }
        let memberGroups: [[Int]] = personMembers.keys.sorted().map { (key: String) -> [Int] in
            personMembers[key] ?? []
        } + clusterMembers.keys.sorted().map { (key: String) -> [Int] in
            clusterMembers[key] ?? []
        }
        for members in memberGroups {
            // The centre is the one `separateSamePhotoFaces` uses: the
            // confirmed faces when the group has any, all members otherwise.
            let anchors: [Int] = members.filter { (index: Int) -> Bool in faces[index].isUserConfirmed }
            let centreRows: [Int] = anchors.isEmpty ? members : anchors
            let groupCentre: [Double] = FaceGroupingMath.centre(of: centreRows, in: unit)
            let photoGroups: [String: [Int]] = Dictionary(
                grouping: members.filter { (index: Int) -> Bool in !faces[index].photoID.isEmpty },
                by: { (index: Int) -> String in faces[index].photoID }
            )
            for photoID in photoGroups.keys.sorted() {
                let photoFaces: [Int] = photoGroups[photoID] ?? []
                guard photoFaces.count > 1 else { continue }
                let confirmed: [Int] = photoFaces.filter { (index: Int) -> Bool in faces[index].isUserConfirmed }
                var keep: Set<Int> = []
                if !confirmed.isEmpty {
                    keep = Set(confirmed)
                } else if let first = photoFaces.first {
                    var bestIndex = first
                    var bestDistance = FaceGroupingMath.cosineDistance(groupCentre, unit[bestIndex])
                    for index in photoFaces.dropFirst() {
                        let distance = FaceGroupingMath.cosineDistance(groupCentre, unit[index])
                        if distance < bestDistance
                            || (distance == bestDistance && faces[index].id < faces[bestIndex].id) {
                            bestDistance = distance
                            bestIndex = index
                        }
                    }
                    keep = [bestIndex]
                }
                for index in photoFaces where !keep.contains(index) {
                    outputPerson[index] = nil
                    outputCluster[index] = nil
                    settled[index] = false
                }
            }
        }
        if shouldStop() { return nil }

        // Rule 4b: rule 4 can leave an unnamed card with fewer faces than a
        // card needs (`minSize`, the same number the grouping used to make
        // cards). Such a card is not a card: its faces go back to rule 5, which
        // places each one on a nearby person or as its own loose face. Named
        // people and confirmed faces are not touched.
        var clusterCounts: [String: Int] = [:]
        for index in faces.indices {
            guard outputPerson[index] == nil,
                  let clusterID = outputCluster[index],
                  clusterID.hasPrefix("cluster-")
            else { continue }
            clusterCounts[clusterID, default: 0] += 1
        }
        var shrunkenClusters: Set<String> = []
        for (clusterID, count) in clusterCounts where count < parameters.minSize {
            shrunkenClusters.insert(clusterID)
        }
        if !shrunkenClusters.isEmpty {
            for index in faces.indices {
                guard outputPerson[index] == nil,
                      let clusterID = outputCluster[index],
                      shrunkenClusters.contains(clusterID)
                else { continue }
                outputCluster[index] = nil
                settled[index] = false
            }
        }
        if shouldStop() { return nil }

        // Rule 5: a loose face may join the nearest confirmed person when that
        // person is close enough, was not rejected and has no face from the
        // same photo. Otherwise it is its own loose cluster.
        var photosByPerson: [String: Set<String>] = [:]
        for index in faces.indices {
            guard let person = outputPerson[index], !faces[index].photoID.isEmpty else { continue }
            photosByPerson[person, default: []].insert(faces[index].photoID)
        }
        for index in faces.indices where !faces[index].isUserConfirmed && !settled[index] {
            var bestPerson: String? = nil
            var bestDistance = Double.infinity
            // Rule 5 takes the nearest centre first and then checks it: a
            // rejected nearest person sends the face loose, it does not fall
            // through to the second-nearest person.
            for person in personIDs {
                guard let centre = personCentres[person] else { continue }
                let distance = FaceGroupingMath.cosineDistance(centre, unit[index])
                if distance < bestDistance {
                    bestDistance = distance
                    bestPerson = person
                }
            }
            let photo = faces[index].photoID
            var photoFree = true
            if let person = bestPerson, !photo.isEmpty {
                photoFree = !(photosByPerson[person]?.contains(photo) ?? false)
            }
            let accepted = bestPerson.map { (person: String) -> Bool in
                !faces[index].rejectedPersonIDs.contains(person)
            } ?? false
            if let person = bestPerson, bestDistance < personAttach, photoFree, accepted {
                outputPerson[index] = person
                outputCluster[index] = nil
                settled[index] = true
                if !photo.isEmpty {
                    photosByPerson[person, default: []].insert(photo)
                }
            } else {
                outputPerson[index] = nil
                outputCluster[index] = "loose-\(faces[index].id)"
                settled[index] = true
            }
        }
        if shouldStop() { return nil }

        // Rule 6: the plan's card questions, mapped to person/cluster sides.
        // A cluster side only exists while at least one face still carries it
        // (rule 4b can have emptied the card), so questions about a card that
        // is no longer in the output are dropped. Person sides need no check:
        // a person's card always keeps its confirmed face.
        var liveClusters: Set<String> = []
        for index in faces.indices where outputPerson[index] == nil {
            if let cluster = outputCluster[index] {
                liveClusters.insert(cluster)
            }
        }
        var questions: [PeoplePlannerQuestion] = []
        var seenPairs: Set<String> = []
        for pair in groupingPlan.questions {
            guard pair.first >= 0, pair.first < cards.count,
                  pair.second >= 0, pair.second < cards.count
            else { continue }
            guard let first = side(of: cards[pair.first]),
                  let second = side(of: cards[pair.second])
            else { continue }
            if first == second { continue }
            let isPersonPair: Bool
            if case .person = first, case .person = second {
                isPersonPair = true
            } else {
                isPersonPair = false
            }
            // Merging two named people stays a manual action.
            if isPersonPair { continue }
            // A side that no face carries any more is not a card.
            guard isLive(first, liveClusters: liveClusters),
                  isLive(second, liveClusters: liveClusters)
            else { continue }
            let key = pairKey(first, second)
            if declinedPairs.contains(key) { continue }
            if seenPairs.contains(key) { continue }
            seenPairs.insert(key)
            questions.append(PeoplePlannerQuestion(first: first, second: second))
        }

        // Rule 7: one assignment per face, same order, also when unchanged.
        var assignments: [PeoplePlannerAssignment] = []
        assignments.reserveCapacity(faces.count)
        for index in faces.indices {
            assignments.append(
                PeoplePlannerAssignment(
                    faceID: faces[index].id,
                    personID: outputPerson[index],
                    clusterID: outputCluster[index]
                )
            )
        }
        return PeoplePlannerResult(assignments: assignments, questions: questions)
    }

    // MARK: - Helpers

    /// What one card means for people.
    private struct CardFacts {
        /// Person ids of the card's confirmed faces, sorted and distinct.
        let personIDs: [String]
        /// "cluster-<smallest non-confirmed face id>" for an unnamed card.
        let clusterID: String?
    }

    private static func cardFacts(group: [Int], faces: [PeoplePlannerFace]) -> CardFacts {
        var confirmedPeople: Set<String> = []
        var nonConfirmedIDs: [String] = []
        for index in group {
            let face = faces[index]
            if face.isUserConfirmed {
                if let personID = face.personID {
                    confirmedPeople.insert(personID)
                }
            } else {
                nonConfirmedIDs.append(face.id)
            }
        }
        let personIDs: [String] = confirmedPeople.sorted()
        var clusterID: String? = nil
        if personIDs.isEmpty, let smallest = nonConfirmedIDs.min() {
            clusterID = "cluster-\(smallest)"
        }
        return CardFacts(personIDs: personIDs, clusterID: clusterID)
    }

    /// Centre of every person's confirmed faces, keyed by person id.
    private static func confirmedPersonCentres(
        faces: [PeoplePlannerFace],
        unit: [[Double]]
    ) -> [String: [Double]] {
        var indicesByPerson: [String: [Int]] = [:]
        for index in faces.indices {
            let face = faces[index]
            guard face.isUserConfirmed, let personID = face.personID else { continue }
            indicesByPerson[personID, default: []].append(index)
        }
        var centres: [String: [Double]] = [:]
        for (personID, indices) in indicesByPerson {
            centres[personID] = FaceGroupingMath.centre(of: indices, in: unit)
        }
        return centres
    }

    /// True while a question side still exists in the output: a person always
    /// does (its card keeps the confirmed face), a cluster only while at least
    /// one face still carries it.
    private static func isLive(_ side: PeoplePlannerSide, liveClusters: Set<String>) -> Bool {
        switch side {
        case .person: return true
        case .cluster(let id): return liveClusters.contains(id)
        }
    }

    private static func side(of card: CardFacts) -> PeoplePlannerSide? {
        if card.personIDs.count == 1 {
            return .person(card.personIDs[0])
        }
        if card.personIDs.isEmpty, let clusterID = card.clusterID {
            return .cluster(clusterID)
        }
        return nil
    }
}
