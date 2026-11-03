import Foundation
import SwiftData
import XCTest
@testable import Moments

/// "Not a real person": a game or cartoon character hides as an unnamed,
/// hidden person. Every face and ID here is synthetic.
@MainActor
final class PeopleNotAPersonTests: XCTestCase {
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

    func testMarkingAThreeFaceCardCreatesOneHiddenUnnamedPerson() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let faces: [FaceObservation] = [face("a", clusterID: "cluster-a"), face("b", clusterID: "cluster-a"), face("c", clusterID: "cluster-a")]
        for face in faces { context.insert(face) }
        try context.save()

        let person: Person? = PeopleStoreActions.markNotAPerson(faces: faces, context: context)
        try context.save()

        let hidden = try XCTUnwrap(person)
        XCTAssertNil(hidden.name, "The hidden person has no name")
        XCTAssertTrue(hidden.hidden, "The hidden person never shows on the page")
        XCTAssertEqual(try allPeople(context).map(\.id), [hidden.id], "Exactly one person is created")

        for face in faces {
            XCTAssertEqual(face.personID, hidden.id)
            XCTAssertNil(face.clusterID, "A face in the hidden person leaves its card")
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

        let person: Person? = PeopleStoreActions.markNotAPerson(faces: [kept, freeA, freeB], context: context)
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

    func testNothingToHideReturnsNoPerson() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext

        XCTAssertNil(PeopleStoreActions.markNotAPerson(faces: [], context: context))
        XCTAssertTrue(try allPeople(context).isEmpty)
    }
}
