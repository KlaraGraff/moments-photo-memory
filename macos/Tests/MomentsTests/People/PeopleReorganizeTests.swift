import Foundation
import MomentsCore
import SwiftData
import XCTest
@testable import Moments

/// The People "reorganize" reset: what the owner confirmed stays, everything
/// else goes back to pending so the next scan groups it again. Every name, face
/// and ID here is synthetic.
@MainActor
final class PeopleReorganizeTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "people-reorganize-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    /// A synthetic face with a small, meaningless embedding.
    private func face(
        _ id: String,
        personID: String? = nil,
        clusterID: String? = nil,
        confirmed: Bool = false,
        source: String = "auto",
        rejected: String = ""
    ) -> FaceObservation {
        let embedding: Data = Data(repeating: 0, count: 8 * MemoryLayout<Float>.size)
        let crop: Data = Data([1, 2, 3])
        let rect: (x: Double, y: Double, w: Double, h: Double) = (0.1, 0.1, 0.2, 0.2)
        return FaceObservation(
            id: id,
            mediaID: "synthetic-\(id)",
            rect: rect,
            embedding: embedding,
            cropData: crop,
            quality: 0.8,
            personID: personID,
            clusterID: clusterID,
            confirmed: confirmed,
            rejectedPersonIDs: rejected,
            assignmentSource: source
        )
    }

    private func people(_ context: ModelContext) throws -> [Person] {
        let sort: [SortDescriptor<Person>] = [SortDescriptor(\Person.id)]
        return try context.fetch(FetchDescriptor<Person>(sortBy: sort))
    }

    private func faces(_ context: ModelContext) throws -> [FaceObservation] {
        let sort: [SortDescriptor<FaceObservation>] = [SortDescriptor(\FaceObservation.id)]
        return try context.fetch(FetchDescriptor<FaceObservation>(sortBy: sort))
    }

    private func makeContext() throws -> ModelContext {
        let container: ModelContainer = try MomentsPersistence.makeContainer(inMemory: true)
        return container.mainContext
    }

    /// (a) A named person and its faces keep everything, hidden or not.
    func testNamedPersonAndItsFacesStayUntouched() throws {
        let context: ModelContext = try makeContext()
        let named: Person = Person(id: "synthetic-named", name: "Synthetic Alice")
        let hiddenNamed: Person = Person(id: "synthetic-hidden-named", name: "Synthetic Beh", hidden: true)
        context.insert(named)
        context.insert(hiddenNamed)
        let first: FaceObservation = face("first", personID: named.id, confirmed: true, source: "user")
        let second: FaceObservation = face("second", personID: named.id, confirmed: true, source: "user", rejected: "synthetic-other")
        let hiddenFace: FaceObservation = face("hidden", personID: hiddenNamed.id, confirmed: true, source: "user")
        context.insert(first)
        context.insert(second)
        context.insert(hiddenFace)
        try context.save()

        let released: Int = try PeopleReorganize.reset(context: context, defaults: defaults)

        XCTAssertEqual(released, 0)
        XCTAssertEqual(first.personID, named.id)
        XCTAssertNil(first.clusterID)
        XCTAssertTrue(first.confirmed)
        XCTAssertEqual(first.assignmentSource, "user")
        XCTAssertEqual(second.personID, named.id)
        XCTAssertEqual(second.rejectedPersonIDs, "synthetic-other")
        XCTAssertTrue(second.confirmed)
        XCTAssertEqual(hiddenFace.personID, hiddenNamed.id)
        XCTAssertTrue(hiddenFace.confirmed)
        XCTAssertEqual(try people(context).map(\.id).sorted(), ["synthetic-hidden-named", "synthetic-named"])
    }

    /// (b) An unnamed group's faces go back to pending and the person record goes.
    func testUnnamedClusterFacesAreReleasedAndThePersonDeleted() throws {
        let context: ModelContext = try makeContext()
        let unnamed: Person = Person(id: "synthetic-unnamed", name: nil)
        let blank: Person = Person(id: "synthetic-blank", name: "   ")
        context.insert(unnamed)
        context.insert(blank)
        let grouped: FaceObservation = face("grouped", personID: unnamed.id, confirmed: true, source: "user")
        let blankNamed: FaceObservation = face("blank-named", personID: blank.id, confirmed: true, source: "user")
        let loose: FaceObservation = face("loose", rejected: "synthetic-unnamed")
        // Already waiting for the next scan: it is reset and counted like any
        // other loose face, and keeps its own pending group.
        let pending: FaceObservation = face("already", clusterID: "pending-already")
        let inCluster: FaceObservation = face("in-cluster", clusterID: "cluster-a")
        let all: [FaceObservation] = [grouped, blankNamed, loose, pending, inCluster]
        all.forEach(context.insert)
        try context.save()

        let released: Int = try PeopleReorganize.reset(context: context, defaults: defaults)

        XCTAssertEqual(released, 5)
        for releasedFace in [grouped, blankNamed, loose, pending, inCluster] {
            XCTAssertNil(releasedFace.personID)
            XCTAssertEqual(releasedFace.clusterID, "pending-\(releasedFace.id)")
            XCTAssertFalse(releasedFace.confirmed)
            XCTAssertEqual(releasedFace.assignmentSource, "auto")
        }
        XCTAssertEqual(loose.rejectedPersonIDs, "synthetic-unnamed", "A \"no\" answer stays")
        XCTAssertTrue(try people(context).isEmpty, "Both unnamed people owned nothing after the release")
    }

    /// (c) A hidden, unnamed person with faces the owner confirmed is reset too.
    func testHiddenUnnamedPersonWithConfirmedFacesIsReleasedAndDeleted() throws {
        let context: ModelContext = try makeContext()
        let hidden: Person = Person(id: "synthetic-hidden", name: nil, hidden: true)
        context.insert(hidden)
        let confirmed: FaceObservation = face("confirmed", personID: hidden.id, confirmed: true, source: "user")
        let auto: FaceObservation = face("auto", personID: hidden.id, confirmed: false, source: "auto")
        context.insert(confirmed)
        context.insert(auto)
        try context.save()

        let released: Int = try PeopleReorganize.reset(context: context, defaults: defaults)

        XCTAssertEqual(released, 2)
        for releasedFace in [confirmed, auto] {
            XCTAssertNil(releasedFace.personID)
            XCTAssertEqual(releasedFace.clusterID, "pending-\(releasedFace.id)")
            XCTAssertFalse(releasedFace.confirmed)
            XCTAssertEqual(releasedFace.assignmentSource, "auto")
        }
        XCTAssertTrue(try people(context).isEmpty)
        XCTAssertEqual(try faces(context).count, 2, "The faces themselves stay, the group does not")
    }

    /// (d) "No" answers and key faces stay, questions are cleared, the grouping
    /// version drops to 0.
    func testDeclinedPairsAndKeyFacesStayWhileQuestionsAndVersionReset() throws {
        let keptPair: String = PeopleAssignmentPlanner.pairKey(.person("synthetic-person"), .cluster("synthetic-cluster"))
        let openPair: String = PeopleAssignmentPlanner.pairKey(.cluster("synthetic-a"), .cluster("synthetic-b"))
        defaults.set([openPair, keptPair], forKey: PeopleStoreActions.questionsKey)
        defaults.set([keptPair], forKey: PeopleStoreActions.declinedPairsKey)
        PeopleStoreActions.setKeyFace("synthetic-face", for: "synthetic-person", defaults: defaults)
        defaults.set(2, forKey: PeopleScanStore.groupingVersionKey)

        let container: ModelContainer = try MomentsPersistence.makeContainer(inMemory: true)
        let context: ModelContext = container.mainContext
        let released: Int = try PeopleReorganize.reset(context: context, defaults: defaults)

        XCTAssertEqual(released, 0)
        XCTAssertTrue(PeopleStoreActions.storedQuestions(defaults).isEmpty, "Skipped and open questions are gone")
        XCTAssertEqual(PeopleStoreActions.declinedPairs(defaults), Set([keptPair]), "A \"no\" is never asked again")
        XCTAssertEqual(PeopleStoreActions.keyFaceID(for: "synthetic-person", defaults: defaults), "synthetic-face")
        XCTAssertEqual(defaults.integer(forKey: PeopleScanStore.groupingVersionKey), 0)
    }
}
