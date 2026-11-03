import Foundation
import SwiftData
import XCTest
@testable import Moments

/// "Ignore this group": a stranger or a game/cartoon character hides as an
/// unnamed, hidden person, and Restore puts its faces back for the next scan.
/// Every face and ID here is synthetic.
@MainActor
final class PeopleIgnoreTests: XCTestCase {
    private func face(_ id: String, personID: String? = nil, clusterID: String? = nil) -> FaceObservation {
        FaceObservation(
            id: id,
            mediaID: "synthetic-\(id)",
            rect: (0.1, 0.1, 0.2, 0.2),
            embedding: Data(repeating: 0, count: 8 * MemoryLayout<Float>.size),
            cropData: Data([1, 2, 3]),
            quality: 0.8,
            personID: personID,
            clusterID: clusterID,
            confirmed: personID != nil,
            assignmentSource: personID != nil ? "user" : "auto"
        )
    }

    private func allPeople(_ context: ModelContext) throws -> [Person] {
        try context.fetch(FetchDescriptor<Person>(sortBy: [SortDescriptor(\.createdAt)]))
    }

    func testIgnoringAThreeFaceCardCreatesOneHiddenUnnamedPerson() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let faces: [FaceObservation] = [face("a", clusterID: "cluster-a"), face("b", clusterID: "cluster-a"), face("c", clusterID: "cluster-a")]
        for face in faces { context.insert(face) }
        try context.save()

        let person: Person? = PeopleStoreActions.ignore(faces: faces, context: context)
        try context.save()

        let hidden = try XCTUnwrap(person)
        XCTAssertNil(hidden.name, "The hidden person has no name")
        XCTAssertTrue(hidden.hidden, "The hidden person never shows on the page")
        XCTAssertEqual(try allPeople(context).map(\.id), [hidden.id], "Exactly one person is created")

        for face in faces {
            XCTAssertEqual(face.personID, hidden.id)
            XCTAssertNil(face.clusterID, "A face in the ignored group leaves its card")
            XCTAssertTrue(face.confirmed)
            XCTAssertEqual(face.assignmentSource, "user", "The user, not a guess, put the face there")
        }
    }

    func testAFaceThatAlreadyHasAPersonIsUntouched() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let keptPerson = Person(id: "kept", name: "Alice")
        let kept = face("kept", personID: keptPerson.id)
        let freeA = face("free-a", clusterID: "cluster-a")
        let freeB = face("free-b", clusterID: "cluster-a")
        context.insert(keptPerson)
        for face in [kept, freeA, freeB] { context.insert(face) }
        try context.save()

        let person: Person? = PeopleStoreActions.ignore(faces: [kept, freeA, freeB], context: context)
        try context.save()

        let hidden = try XCTUnwrap(person)
        XCTAssertEqual(kept.personID, "kept", "A face with a person stays with them")
        XCTAssertTrue(kept.confirmed)
        XCTAssertEqual(try allPeople(context).map(\.id).sorted(), ["kept", hidden.id].sorted())
        for face in [freeA, freeB] {
            XCTAssertEqual(face.personID, hidden.id)
            XCTAssertNil(face.clusterID)
            XCTAssertEqual(face.assignmentSource, "user")
        }
    }

    func testNothingToIgnoreReturnsNoPerson() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext

        XCTAssertNil(PeopleStoreActions.ignore(faces: [], context: context))
        XCTAssertTrue(try allPeople(context).isEmpty)
    }

    func testRestoreReleasesTheFacesAndDeletesThePerson() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let faces: [FaceObservation] = [face("r-a", clusterID: "cluster-r"), face("r-b", clusterID: "cluster-r"), face("r-c", clusterID: "cluster-r")]
        for face in faces { context.insert(face) }
        try context.save()
        let ignored = try XCTUnwrap(PeopleStoreActions.ignore(faces: faces, context: context))
        try context.save()

        let observations: [FaceObservation] = try context.fetch(FetchDescriptor<FaceObservation>())
        let released: [FaceObservation] = PeopleStoreActions.restoreIgnored(personID: ignored.id, observations: observations, context: context)
        try context.save()

        XCTAssertEqual(released.map(\.id).sorted(), ["r-a", "r-b", "r-c"])
        for face in released {
            XCTAssertNil(face.personID, "A restored face has no person again")
            XCTAssertEqual(face.clusterID, "pending-\(face.id)", "The next scan groups it again")
            XCTAssertFalse(face.confirmed)
            XCTAssertEqual(face.assignmentSource, "auto")
        }
        XCTAssertTrue(try allPeople(context).isEmpty, "The hidden person is deleted")
    }

    func testAnIgnoredPersonIsListedButANamedHiddenPersonIsNot() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let ignored = Person(id: "hidden-unnamed", hidden: true)
        let namedHidden = Person(id: "hidden-named", name: "Synthetic Bob", hidden: true)
        let visible = Person(id: "visible", name: "Synthetic Alice")
        for person in [ignored, namedHidden, visible] { context.insert(person) }
        try context.save()

        let people: [Person] = try allPeople(context)
        XCTAssertEqual(PeopleStoreActions.ignoredPeople(people).map(\.id), [ignored.id])
    }
}
