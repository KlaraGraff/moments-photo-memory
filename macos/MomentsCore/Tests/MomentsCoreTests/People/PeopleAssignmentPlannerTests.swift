import Foundation
import XCTest
@testable import MomentsCore

final class PeopleAssignmentPlannerTests: XCTestCase {
    // MARK: - Fixtures

    /// Hand-made 8-d unit vectors keep the tests readable; the planner only
    /// needs cosine geometry, so basis vectors and small rotations are enough.
    private func vector(_ components: [Double]) -> [Float] {
        var values = components
        while values.count < 8 { values.append(0) }
        return values.map { (value: Double) -> Float in Float(value) }
    }

    /// A unit vector in the 0/1 plane, `degrees` away from the first axis.
    private func angled(_ degrees: Double) -> [Float] {
        let radians = degrees * Double.pi / 180
        return vector([cos(radians), sin(radians)])
    }

    /// A unit vector whose first three components are given.
    private func direction(_ first: Double, _ second: Double, _ third: Double) -> [Float] {
        return vector([first, second, third])
    }

    private func makeFace(
        id: String,
        embedding: [Float],
        photoID: String,
        quality: Double = 0.9,
        personID: String? = nil,
        isUserConfirmed: Bool = false,
        rejectedPersonIDs: Set<String> = []
    ) -> PeoplePlannerFace {
        return PeoplePlannerFace(
            id: id,
            embedding: embedding,
            quality: quality,
            photoID: photoID,
            day: nil,
            personID: personID,
            isUserConfirmed: isUserConfirmed,
            rejectedPersonIDs: rejectedPersonIDs
        )
    }

    /// Tight grouping so hand-made vectors make the intended cards; `minSize`
    /// is lowered because these test libraries are tiny (the real default is 3).
    private func tightParameters(minSize: Int = 2) -> PeopleGroupingParameters {
        var parameters = PeopleGroupingParameters()
        parameters.auto = 0.3
        parameters.minSize = minSize
        return parameters
    }

    private func assignmentsByID(_ result: PeoplePlannerResult?) -> [String: PeoplePlannerAssignment] {
        guard let result else { return [:] }
        var byID: [String: PeoplePlannerAssignment] = [:]
        for assignment in result.assignments {
            byID[assignment.faceID] = assignment
        }
        return byID
    }

    /// The raw grouping plan for the same faces, so each test also proves the
    /// card shape it relies on (and that confirmed faces take part in grouping).
    private func groupingPlan(
        _ faces: [PeoplePlannerFace],
        parameters: PeopleGroupingParameters
    ) -> PeopleGroupingPlan? {
        let groupingFaces: [PeopleGroupingFace] = faces.map { (face: PeoplePlannerFace) -> PeopleGroupingFace in
            PeopleGroupingFace(
                embedding: face.embedding,
                quality: face.quality,
                photoID: face.photoID,
                day: face.day
            )
        }
        return PeopleGrouping.plan(groupingFaces, parameters: parameters)
    }

    // MARK: - a) confirmed faces never move

    func testConfirmedFacesNeverMove() {
        // One card holds confirmed p1 and confirmed p2; the unconfirmed face is
        // closer to p2's confirmed face, so |P| >= 2 picks p2.
        let faces: [PeoplePlannerFace] = [
            makeFace(id: "a", embedding: angled(0), photoID: "photo-a", personID: "p1", isUserConfirmed: true),
            makeFace(id: "b", embedding: angled(20), photoID: "photo-b", personID: "p2", isUserConfirmed: true),
            makeFace(id: "c", embedding: angled(15), photoID: "photo-c"),
        ]
        let parameters = tightParameters()
        XCTAssertEqual(groupingPlan(faces, parameters: parameters)?.groups, [[0, 1, 2]])
        let result = PeopleAssignmentPlanner.plan(faces, parameters: parameters)
        XCTAssertNotNil(result)
        let byID = assignmentsByID(result)
        XCTAssertEqual(byID["a"]?.personID, "p1")
        XCTAssertNil(byID["a"]?.clusterID)
        XCTAssertEqual(byID["b"]?.personID, "p2")
        XCTAssertNil(byID["b"]?.clusterID)
        XCTAssertEqual(byID["c"]?.personID, "p2")
        XCTAssertNil(byID["c"]?.clusterID)
    }

    // MARK: - b) a card with one person pulls its faces

    func testCardWithOnePersonPullsItsFaces() {
        let faces: [PeoplePlannerFace] = [
            makeFace(id: "anchor", embedding: angled(0), photoID: "photo-1", personID: "p1", isUserConfirmed: true),
            makeFace(id: "second", embedding: angled(0), photoID: "photo-2"),
            makeFace(id: "third", embedding: angled(0), photoID: "photo-3"),
        ]
        let parameters = tightParameters()
        XCTAssertEqual(groupingPlan(faces, parameters: parameters)?.groups, [[0, 1, 2]])
        let result = PeopleAssignmentPlanner.plan(faces, parameters: parameters)
        let assignments = result?.assignments ?? []
        // Rule 7: one assignment per input face, same order.
        XCTAssertEqual(assignments.count, 3)
        XCTAssertEqual(assignments.map { (assignment: PeoplePlannerAssignment) -> String in assignment.faceID },
                       ["anchor", "second", "third"])
        let byID = assignmentsByID(result)
        XCTAssertEqual(byID["anchor"]?.personID, "p1")
        XCTAssertEqual(byID["second"]?.personID, "p1")
        XCTAssertNil(byID["second"]?.clusterID)
        XCTAssertEqual(byID["third"]?.personID, "p1")
        XCTAssertNil(byID["third"]?.clusterID)
    }

    // MARK: - c) a rejected person is respected

    func testRejectedPersonIsRespected() {
        // The second face is pulled to p1 by its card but rejected p1, so it
        // must become loose instead of coming back to p1.
        let faces: [PeoplePlannerFace] = [
            makeFace(id: "anchor", embedding: angled(0), photoID: "photo-1", personID: "p1", isUserConfirmed: true),
            makeFace(id: "rejector", embedding: angled(0), photoID: "photo-2", rejectedPersonIDs: ["p1"]),
        ]
        let parameters = tightParameters()
        XCTAssertEqual(groupingPlan(faces, parameters: parameters)?.groups, [[0, 1]])
        let result = PeopleAssignmentPlanner.plan(faces, parameters: parameters)
        let byID = assignmentsByID(result)
        XCTAssertEqual(byID["anchor"]?.personID, "p1")
        XCTAssertNil(byID["rejector"]?.personID)
        XCTAssertEqual(byID["rejector"]?.clusterID, "loose-rejector")
    }

    // MARK: - d) an unnamed cluster's id

    func testUnnamedClusterIDIsSmallestFaceID() {
        let firstFaces: [PeoplePlannerFace] = [
            makeFace(id: "b", embedding: angled(0), photoID: "photo-b"),
            makeFace(id: "c", embedding: angled(0), photoID: "photo-c"),
        ]
        let parameters = tightParameters()
        XCTAssertEqual(groupingPlan(firstFaces, parameters: parameters)?.groups, [[0, 1]])
        let first = PeopleAssignmentPlanner.plan(firstFaces, parameters: parameters)
        let firstByID = assignmentsByID(first)
        XCTAssertEqual(firstByID["b"]?.clusterID, "cluster-b")
        XCTAssertEqual(firstByID["c"]?.clusterID, "cluster-b")

        // A new face with a larger id joins the same card: the id stays put.
        var secondFaces = firstFaces
        secondFaces.append(makeFace(id: "z", embedding: angled(0), photoID: "photo-z"))
        XCTAssertEqual(groupingPlan(secondFaces, parameters: parameters)?.groups, [[0, 1, 2]])
        let second = PeopleAssignmentPlanner.plan(secondFaces, parameters: parameters)
        let secondByID = assignmentsByID(second)
        XCTAssertEqual(secondByID["b"]?.clusterID, "cluster-b")
        XCTAssertEqual(secondByID["c"]?.clusterID, "cluster-b")
        XCTAssertEqual(secondByID["z"]?.clusterID, "cluster-b")
        XCTAssertNil(secondByID["z"]?.personID)
    }

    // MARK: - e) same-photo faces split

    func testSamePhotoFacesSplit() {
        // Within a named person: only the confirmed face stays, the other face
        // from the same photo has to stay loose (p1 already has that photo).
        let personFaces: [PeoplePlannerFace] = [
            makeFace(id: "anchor", embedding: angled(0), photoID: "shared-1", personID: "p1", isUserConfirmed: true),
            makeFace(id: "extra", embedding: angled(0), photoID: "shared-1"),
        ]
        let parameters = tightParameters()
        XCTAssertEqual(groupingPlan(personFaces, parameters: parameters)?.groups, [[0, 1]])
        let personResult = PeopleAssignmentPlanner.plan(personFaces, parameters: parameters)
        let personByID = assignmentsByID(personResult)
        XCTAssertEqual(personByID["anchor"]?.personID, "p1")
        XCTAssertNil(personByID["extra"]?.personID)
        XCTAssertEqual(personByID["extra"]?.clusterID, "loose-extra")

        // Within an unnamed group: the face closest to the centre stays
        // (`ee`, exactly at the centre), `dd` and `ff` become loose.
        let clusterFaces: [PeoplePlannerFace] = [
            makeFace(id: "dd", embedding: angled(0), photoID: "shared-2"),
            makeFace(id: "ee", embedding: angled(10), photoID: "shared-2"),
            makeFace(id: "ff", embedding: angled(20), photoID: "shared-2"),
        ]
        XCTAssertEqual(groupingPlan(clusterFaces, parameters: parameters)?.groups, [[0, 1, 2]])
        let clusterResult = PeopleAssignmentPlanner.plan(clusterFaces, parameters: parameters)
        let clusterByID = assignmentsByID(clusterResult)
        XCTAssertEqual(clusterByID["ee"]?.clusterID, "cluster-dd")
        XCTAssertEqual(clusterByID["dd"]?.clusterID, "loose-dd")
        XCTAssertEqual(clusterByID["ff"]?.clusterID, "loose-ff")
        XCTAssertNil(clusterByID["ff"]?.personID)
    }

    // MARK: - f) a loose face joins a close named person

    func testLooseFaceJoinsCloseNamedPerson() {
        // `attach`, `absorb`, `absorbWide` are tightened so the grouping plan
        // leaves the low-quality faces loose; `personAttach` (0.55) is the
        // planner's own threshold that rule 5 tests.
        var parameters = tightParameters()
        parameters.attach = 0.01
        parameters.absorb = 0.0001
        parameters.absorbWide = 0.0001
        parameters.faceClose = 0.0
        let faces: [PeoplePlannerFace] = [
            makeFace(id: "anchor", embedding: angled(0), photoID: "photo-1", personID: "p1", isUserConfirmed: true),
            makeFace(id: "companion", embedding: angled(5), photoID: "photo-2"),
            // Close to p1's centre (20 degrees) and from another photo: joins.
            makeFace(id: "close", embedding: angled(20), photoID: "photo-3", quality: 0.2),
            // Orthogonal to p1: too far, stays loose.
            makeFace(id: "far", embedding: vector([0, 0, 0, 1]), photoID: "photo-4", quality: 0.2),
            // Close to p1 but from the same photo as p1's confirmed face.
            makeFace(id: "sibling", embedding: angled(20), photoID: "photo-1", quality: 0.2),
        ]
        let grouped = groupingPlan(faces, parameters: parameters)
        XCTAssertEqual(grouped?.groups, [[0, 1]])
        XCTAssertEqual(grouped?.loose, [2, 3, 4])
        let result = PeopleAssignmentPlanner.plan(faces, parameters: parameters)
        XCTAssertNotNil(result)
        let byID = assignmentsByID(result)
        XCTAssertEqual(byID["anchor"]?.personID, "p1")
        XCTAssertEqual(byID["companion"]?.personID, "p1")
        XCTAssertEqual(byID["close"]?.personID, "p1")
        XCTAssertNil(byID["close"]?.clusterID)
        XCTAssertNil(byID["far"]?.personID)
        XCTAssertEqual(byID["far"]?.clusterID, "loose-far")
        XCTAssertNil(byID["sibling"]?.personID)
        XCTAssertEqual(byID["sibling"]?.clusterID, "loose-sibling")
    }

    // MARK: - g) questions map to sides

    func testQuestionsMapToSidesAndSkipDeclinedAndPersonPairs() {
        // Pair keys are canonical (sorted side keys).
        let key = PeopleAssignmentPlanner.pairKey(.person("p1"), .cluster("cluster-a"))
        XCTAssertEqual(key, "cluster:cluster-a|person:p1")
        XCTAssertEqual(PeopleAssignmentPlanner.pairKey(.cluster("cluster-a"), .person("p1")), key)
        XCTAssertEqual(PeopleAssignmentPlanner.pairKey(.cluster("b"), .cluster("a")), "cluster:a|cluster:b")

        // Three singleton cards, pairwise 60 degrees apart, so the plan asks
        // all three pairs. The card with p1 and the card with p2 are both
        // persons: that question is skipped. The other two are kept.
        let clusterFace = makeFace(id: "c1", embedding: angled(0), photoID: "photo-c1")
        let personOne = makeFace(
            id: "f1",
            embedding: direction(0.5, 0.8660254, 0),
            photoID: "photo-f1",
            personID: "p1",
            isUserConfirmed: true
        )
        let personTwo = makeFace(
            id: "f2",
            embedding: direction(0.5, 0.2886751, 0.8164966),
            photoID: "photo-f2",
            personID: "p2",
            isUserConfirmed: true
        )
        let threeFaces: [PeoplePlannerFace] = [clusterFace, personOne, personTwo]
        let wideParameters = tightParameters(minSize: 1)
        XCTAssertEqual(groupingPlan(threeFaces, parameters: wideParameters)?.groups, [[0], [1], [2]])
        let threePlan = PeopleAssignmentPlanner.plan(threeFaces, parameters: wideParameters)
        XCTAssertNotNil(threePlan)
        XCTAssertEqual(threePlan?.questions.count, 2)
        XCTAssertEqual(
            threePlan?.questions.map { (question: PeoplePlannerQuestion) -> String in
                PeopleAssignmentPlanner.pairKey(question.first, question.second)
            },
            ["cluster:cluster-c1|person:p1", "cluster:cluster-c1|person:p2"]
        )

        // Declining the first pair drops exactly that question.
        let declinedKey = PeopleAssignmentPlanner.pairKey(.cluster("cluster-c1"), .person("p1"))
        let declinedPlan = PeopleAssignmentPlanner.plan(
            threeFaces,
            declinedPairs: [declinedKey],
            parameters: wideParameters
        )
        XCTAssertEqual(declinedPlan?.questions.count, 1)
        XCTAssertEqual(
            declinedPlan?.questions.first.map { (question: PeoplePlannerQuestion) -> String in
                PeopleAssignmentPlanner.pairKey(question.first, question.second)
            },
            "cluster:cluster-c1|person:p2"
        )

        // Two cards of the same person both ask about the cluster: the pair
        // key repeats, so only the first occurrence stays.
        let samePersonOne = makeFace(
            id: "f1",
            embedding: direction(0.5, 0.8660254, 0),
            photoID: "photo-f1",
            personID: "p1",
            isUserConfirmed: true
        )
        let samePersonTwo = makeFace(
            id: "f2",
            embedding: direction(0.5, 0.2886751, 0.8164966),
            photoID: "photo-f2",
            personID: "p1",
            isUserConfirmed: true
        )
        let dedupFaces: [PeoplePlannerFace] = [clusterFace, samePersonOne, samePersonTwo]
        XCTAssertEqual(groupingPlan(dedupFaces, parameters: wideParameters)?.groups, [[0], [1], [2]])
        let dedupPlan = PeopleAssignmentPlanner.plan(dedupFaces, parameters: wideParameters)
        XCTAssertEqual(dedupPlan?.questions.count, 1)
        XCTAssertEqual(
            dedupPlan?.questions.first.map { (question: PeoplePlannerQuestion) -> String in
                PeopleAssignmentPlanner.pairKey(question.first, question.second)
            },
            "cluster:cluster-c1|person:p1"
        )

        // A card with two confirmed persons (|P| >= 2) has no side: the
        // question the plan asks about it is dropped. m1 and m2 are 1 degree
        // apart (one card) at 50 degrees; the cluster card sits at 0 degrees:
        // close enough for a question, far enough not to group with them.
        let mixedClusterFace = makeFace(id: "m3", embedding: angled(0), photoID: "photo-m3")
        let mixedOne = makeFace(
            id: "m1",
            embedding: angled(50),
            photoID: "photo-m1",
            personID: "p3",
            isUserConfirmed: true
        )
        let mixedTwo = makeFace(
            id: "m2",
            embedding: angled(51),
            photoID: "photo-m2",
            personID: "p4",
            isUserConfirmed: true
        )
        let mixedFaces: [PeoplePlannerFace] = [mixedClusterFace, mixedOne, mixedTwo]
        let mixedGrouped = groupingPlan(mixedFaces, parameters: wideParameters)
        XCTAssertEqual(mixedGrouped?.groups, [[0], [1, 2]])
        XCTAssertEqual(mixedGrouped?.questions, [PeopleGroupingPair(first: 0, second: 1)])
        let mixedPlan = PeopleAssignmentPlanner.plan(mixedFaces, parameters: wideParameters)
        XCTAssertEqual(mixedPlan?.questions.count, 0)
        XCTAssertEqual(assignmentsByID(mixedPlan)["m3"]?.clusterID, "cluster-m3")
    }

    // MARK: - h) stop returns nil

    func testStopReturnsNil() {
        let faces: [PeoplePlannerFace] = [
            makeFace(id: "a", embedding: angled(0), photoID: "photo-a"),
        ]
        let result = PeopleAssignmentPlanner.plan(faces, shouldStop: { true })
        XCTAssertNil(result)
    }
}
