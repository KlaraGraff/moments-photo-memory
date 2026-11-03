import Foundation
import MomentsCore
import SwiftData
import XCTest
@testable import Moments

/// The stored "same person?" questions: what a yes, a no and a skip do to the
/// keys and to the faces. Every name, face and ID here is synthetic.
@MainActor
final class PeopleQuestionTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "people-questions-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func face(
        _ id: String,
        personID: String? = nil,
        clusterID: String? = nil,
        confirmed: Bool = false,
        source: String = "auto",
        rejected: String = ""
    ) -> FaceObservation {
        FaceObservation(
            id: id,
            mediaID: "synthetic-\(id)",
            rect: (0.1, 0.1, 0.2, 0.2),
            embedding: Data(repeating: 0, count: 8 * MemoryLayout<Float>.size),
            cropData: Data([1, 2, 3]),
            quality: 0.8,
            personID: personID,
            clusterID: clusterID,
            confirmed: confirmed,
            rejectedPersonIDs: rejected,
            assignmentSource: source
        )
    }

    private func question(_ first: PeoplePlannerSide, _ second: PeoplePlannerSide) -> PeoplePlannerQuestion {
        PeoplePlannerQuestion(first: first, second: second)
    }

    private func key(_ first: PeoplePlannerSide, _ second: PeoplePlannerSide) -> String {
        PeopleAssignmentPlanner.pairKey(first, second)
    }

    func testPairKeyRoundTrip() {
        let person = PeoplePlannerSide.person("synthetic-person")
        let cluster = PeoplePlannerSide.cluster("cluster-a")
        let key = PeopleAssignmentPlanner.pairKey(person, cluster)
        // The key is the same whichever side is passed first.
        XCTAssertEqual(key, PeopleAssignmentPlanner.pairKey(cluster, person))

        guard let sides = PeopleStoreActions.sides(of: key) else {
            return XCTFail("A pair key of two sides should split back into them")
        }
        XCTAssertEqual(Set([sides.0, sides.1]), Set([person, cluster]))
        guard let reversed = PeopleStoreActions.sides(of: PeopleAssignmentPlanner.pairKey(cluster, person)) else {
            return XCTFail("The reversed pair key should split back into its sides")
        }
        XCTAssertEqual(Set([reversed.0, reversed.1]), Set([person, cluster]))

        XCTAssertNil(PeopleStoreActions.sides(of: "person:only-one-side"))
        XCTAssertNil(PeopleStoreActions.sides(of: "person:|cluster:a"))
        XCTAssertNil(PeopleStoreActions.sides(of: "unknown:x|person:a"))
        XCTAssertNil(PeopleStoreActions.sides(of: ""))
    }

    func testYesMovesAClusterToThePersonAsConfirmed() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let person = Person(id: "synthetic-person", name: "Synthetic Alice")
        let named = face("named", personID: person.id, confirmed: true, source: "user")
        let moved = face("moved", clusterID: "cluster-a", rejected: "other-person,\(person.id)")
        let other = face("other", clusterID: "cluster-a")
        context.insert(person)
        let observations: [FaceObservation] = [named, moved, other]
        observations.forEach(context.insert)
        PeopleStoreActions.storeQuestions(
            [question(.person(person.id), .cluster("cluster-a"))],
            defaults: defaults
        )

        let pairKey = key(.person(person.id), .cluster("cluster-a"))
        PeopleStoreActions.answerSame(pairKey, observations: observations, context: context, defaults: defaults)

        XCTAssertEqual(moved.personID, person.id)
        XCTAssertNil(moved.clusterID)
        XCTAssertTrue(moved.confirmed)
        XCTAssertEqual(moved.assignmentSource, "user")
        XCTAssertFalse(moved.rejectedPersonIDSet.contains(person.id))
        XCTAssertTrue(moved.rejectedPersonIDSet.contains("other-person"))
        XCTAssertEqual(other.personID, person.id)
        XCTAssertTrue(other.confirmed)
        XCTAssertEqual(other.assignmentSource, "user")
        // The face that already had the person stays as it was.
        XCTAssertEqual(named.personID, person.id)
        XCTAssertTrue(named.confirmed)
        // The answered key leaves the stored questions.
        XCTAssertTrue(PeopleStoreActions.storedQuestions(defaults).isEmpty)
        XCTAssertTrue(PeopleStoreActions.declinedPairs(defaults).isEmpty)
    }

    func testYesJoinsTwoUnnamedClusters() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let first = face("first", clusterID: "cluster-a")
        let second = face("second", clusterID: "cluster-b")
        let third = face("third", clusterID: "cluster-b")
        let observations: [FaceObservation] = [first, second, third]
        observations.forEach(context.insert)
        PeopleStoreActions.storeQuestions(
            [question(.cluster("cluster-a"), .cluster("cluster-b"))],
            defaults: defaults
        )

        let pairKey = key(.cluster("cluster-a"), .cluster("cluster-b"))
        PeopleStoreActions.answerSame(pairKey, observations: observations, context: context, defaults: defaults)

        // The pair key is sorted, so cluster-a is the first side: the faces of
        // cluster-b take its cluster ID and stay unconfirmed.
        XCTAssertEqual(first.clusterID, "cluster-a")
        XCTAssertEqual(second.clusterID, "cluster-a")
        XCTAssertEqual(third.clusterID, "cluster-a")
        for moved in [second, third] {
            XCTAssertNil(moved.personID)
            XCTAssertFalse(moved.confirmed)
            XCTAssertEqual(moved.assignmentSource, "auto")
        }
        XCTAssertTrue(PeopleStoreActions.storedQuestions(defaults).isEmpty)
    }

    func testNoIsRememberedAndRemoved() {
        let kept: String = key(.person("person-1"), .cluster("cluster-1"))
        let answered: String = key(.person("person-2"), .cluster("cluster-2"))
        PeopleStoreActions.storeQuestions(
            [
                question(.person("person-1"), .cluster("cluster-1")),
                question(.person("person-2"), .cluster("cluster-2"))
            ],
            defaults: defaults
        )

        PeopleStoreActions.answerDifferent(answered, defaults: defaults)

        XCTAssertTrue(PeopleStoreActions.declinedPairs(defaults).contains(answered))
        XCTAssertFalse(PeopleStoreActions.declinedPairs(defaults).contains(kept))
        XCTAssertEqual(PeopleStoreActions.storedQuestions(defaults), [kept])

        // A second "no" is added without losing the first one.
        PeopleStoreActions.answerDifferent(kept, defaults: defaults)
        XCTAssertEqual(PeopleStoreActions.declinedPairs(defaults), Set([kept, answered]))
        XCTAssertTrue(PeopleStoreActions.storedQuestions(defaults).isEmpty)
    }

    func testSkipMovesToTheEnd() {
        let first: String = key(.person("person-1"), .cluster("cluster-1"))
        let second: String = key(.person("person-2"), .cluster("cluster-2"))
        let third: String = key(.person("person-3"), .cluster("cluster-3"))
        PeopleStoreActions.storeQuestions(
            [
                question(.person("person-1"), .cluster("cluster-1")),
                question(.person("person-2"), .cluster("cluster-2")),
                question(.person("person-3"), .cluster("cluster-3"))
            ],
            defaults: defaults
        )

        PeopleStoreActions.skip(first, defaults: defaults)
        XCTAssertEqual(PeopleStoreActions.storedQuestions(defaults), [second, third, first])

        // Skipping it again keeps it at the end exactly once.
        PeopleStoreActions.skip(first, defaults: defaults)
        XCTAssertEqual(PeopleStoreActions.storedQuestions(defaults), [second, third, first])
        XCTAssertTrue(PeopleStoreActions.declinedPairs(defaults).isEmpty)
    }

    func testLiveQuestionsDropGoneSides() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let visible = Person(id: "visible-person", name: "Synthetic Visible")
        let hidden = Person(id: "hidden-person", name: "Synthetic Hidden", hidden: true)
        context.insert(visible)
        context.insert(hidden)
        let visibleFace = face("visible-face", personID: visible.id, confirmed: true, source: "user")
        let hiddenFace = face("hidden-face", personID: hidden.id, confirmed: true, source: "user")
        let clusterFace = face("cluster-face", clusterID: "cluster-live")
        // A cluster side needs at least three unnamed faces to be live.
        let clusterFace2 = face("cluster-face-2", clusterID: "cluster-live")
        let clusterFace3 = face("cluster-face-3", clusterID: "cluster-live")
        // This face used to be in cluster-empty and now belongs to a person, so
        // nothing is left in that cluster.
        let emptiedFace = face("emptied-face", personID: visible.id, confirmed: true, source: "user")
        let observations: [FaceObservation] = [visibleFace, hiddenFace, clusterFace, clusterFace2, clusterFace3, emptiedFace]
        observations.forEach(context.insert)
        let people: [Person] = [visible, hidden]

        let live: String = key(.person(visible.id), .cluster("cluster-live"))
        let withHidden: String = key(.person(hidden.id), .cluster("cluster-live"))
        let withEmptied: String = key(.person(visible.id), .cluster("cluster-empty"))
        let twoPeople: String = key(.person(visible.id), .person(hidden.id))
        PeopleStoreActions.storeQuestions(
            [
                question(.person(visible.id), .cluster("cluster-live")),
                question(.person(hidden.id), .cluster("cluster-live")),
                question(.person(visible.id), .cluster("cluster-empty")),
                question(.person(visible.id), .person(hidden.id))
            ],
            defaults: defaults
        )

        let result: [String] = PeopleStoreActions.liveQuestions(observations: observations, people: people, defaults: defaults)
        XCTAssertEqual(result, [live])
        XCTAssertFalse(result.contains(withHidden))
        XCTAssertFalse(result.contains(withEmptied))
        XCTAssertFalse(result.contains(twoPeople))
        // Nothing was rewritten: the stored keys stay, only the screen filters.
        XCTAssertEqual(PeopleStoreActions.storedQuestions(defaults).count, 4)
    }

    func testStoreQuestionsKeepsOrderAndDropsDuplicates() {
        let first: String = key(.person("person-1"), .cluster("cluster-1"))
        let second: String = key(.person("person-2"), .cluster("cluster-2"))
        PeopleStoreActions.storeQuestions(
            [
                question(.person("person-2"), .cluster("cluster-2")),
                question(.person("person-1"), .cluster("cluster-1")),
                question(.cluster("cluster-1"), .person("person-1")),
                question(.person("person-1"), .cluster("cluster-1"))
            ],
            defaults: defaults
        )

        XCTAssertEqual(PeopleStoreActions.storedQuestions(defaults), [second, first])

        PeopleStoreActions.storeQuestions([], defaults: defaults)
        XCTAssertTrue(PeopleStoreActions.storedQuestions(defaults).isEmpty)
    }
}
