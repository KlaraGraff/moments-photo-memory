import Foundation
import SwiftData
import XCTest
@testable import Moments

/// Same-name merging for People. Every name, face and ID here is synthetic.
@MainActor
final class PeopleNamingTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "PeopleNamingTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func face(_ id: String, personID: String? = nil, clusterID: String? = nil, rejected: String = "") -> FaceObservation {
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
            rejectedPersonIDs: rejected,
            assignmentSource: personID != nil ? "user" : "auto"
        )
    }

    private func livePeople(_ context: ModelContext) throws -> [Person] {
        try context.fetch(FetchDescriptor<Person>(sortBy: [SortDescriptor(\.createdAt)]))
    }

    func testNameEqualityIgnoresCaseWhitespaceAndWidth() {
        XCTAssertTrue(PeopleStoreActions.namesMatch("Alice", "alice"))
        XCTAssertTrue(PeopleStoreActions.namesMatch("  Alice \n", "ALICE"))
        XCTAssertTrue(PeopleStoreActions.namesMatch("Ａｌｉｃｅ", "alice"))
        XCTAssertTrue(PeopleStoreActions.namesMatch("\u{3000}小明\u{3000}", "小明"))
        XCTAssertFalse(PeopleStoreActions.namesMatch("Alice", "Alicia"))
        XCTAssertFalse(PeopleStoreActions.namesMatch("  ", ""))
        XCTAssertFalse(PeopleStoreActions.namesMatch(nil, "Alice"))
    }

    func testNamingIntoAnExistingNameMergesFacesAndRemapsRejections() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let existing = Person(id: "existing", name: "Alice", createdAt: Date(timeIntervalSince1970: 100))
        let kept = face("kept", personID: existing.id)
        let named = face("named", clusterID: "cluster-a", rejected: existing.id)
        let other = face("other", clusterID: "cluster-a")
        let bystander = face("bystander", rejected: existing.id)
        context.insert(existing)
        [kept, named, other, bystander].forEach(context.insert)
        let all = [kept, named, other, bystander]

        let target = PeopleStoreActions.mergeCandidate(forName: " alice ", people: [existing], defaults: defaults)
        XCTAssertEqual(target?.id, existing.id)
        let result = PeopleStoreActions.name(faces: [named, other], as: " alice ", mergingInto: target, keepSeparate: false,
                                             people: [existing], observations: all, context: context, defaults: defaults)
        try context.save()

        XCTAssertEqual(result, existing.id)
        XCTAssertEqual(try livePeople(context).map(\.id), [existing.id], "No second Alice is left behind")
        for face in [named, other] {
            XCTAssertEqual(face.personID, existing.id)
            XCTAssertTrue(face.confirmed)
            XCTAssertEqual(face.assignmentSource, "user")
            XCTAssertNil(face.clusterID)
        }
        XCTAssertFalse(named.rejectedPersonIDSet.contains(existing.id), "Naming overrides an old rejection of the same person")
        XCTAssertEqual(bystander.rejectedPersonIDs, existing.id, "Faces outside the group keep their rejections")
        XCTAssertEqual(kept.personID, existing.id)
    }

    func testKeepSeparateBlocksNamingMergeAndLoadTimeMerge() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let existing = Person(id: "existing", name: "Alice", createdAt: Date(timeIntervalSince1970: 100))
        let first = face("first", clusterID: "cluster-b")
        context.insert(existing)
        context.insert(first)

        let separateID = try XCTUnwrap(PeopleStoreActions.name(faces: [first], as: "ALICE", mergingInto: nil, keepSeparate: true,
                                                               people: [existing], observations: [first], context: context, defaults: defaults))
        try context.save()
        XCTAssertNotEqual(separateID, existing.id)
        XCTAssertEqual(first.personID, separateID)
        XCTAssertTrue(PeopleStoreActions.keepSeparateIDs(defaults).contains(separateID))

        let people = try livePeople(context)
        XCTAssertEqual(people.count, 2)
        XCTAssertNil(PeopleStoreActions.mergeCandidate(forName: "alice", people: people, excluding: existing.id, defaults: defaults),
                     "A kept-separate person is never offered as a merge target")

        let merged = PeopleStoreActions.mergeDuplicateNames(people: people, observations: [first], context: context, defaults: defaults)
        try context.save()
        XCTAssertEqual(merged, 0)
        XCTAssertEqual(try livePeople(context).count, 2)
        XCTAssertEqual(first.personID, separateID)
    }

    func testLoadTimeDedupeMergesSameNamedPeopleIntoTheOldest() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let oldest = Person(id: "oldest", name: "Bob", createdAt: Date(timeIntervalSince1970: 100))
        let newer = Person(id: "newer", name: " bob", createdAt: Date(timeIntervalSince1970: 200))
        let newest = Person(id: "newest", name: "ＢＯＢ", createdAt: Date(timeIntervalSince1970: 300))
        let hidden = Person(id: "hidden", name: "Bob", hidden: true, createdAt: Date(timeIntervalSince1970: 50))
        let unrelated = Person(id: "unrelated", name: "Carol", createdAt: Date(timeIntervalSince1970: 10))
        let people = [newest, unrelated, newer, hidden, oldest]
        people.forEach(context.insert)
        let onNewer = face("on-newer", personID: newer.id)
        let onNewest = face("on-newest", personID: newest.id)
        let rejectsNewer = face("rejects-newer", rejected: newer.id)
        let observations = [onNewer, onNewest, rejectsNewer]
        observations.forEach(context.insert)
        let group = UserGroup(name: "Synthetic group", kind: .smart, rules: UserGroupRuleSet(rules: [UserGroupRule(field: .person, value: newest.id)]))
        context.insert(group)

        let merged = PeopleStoreActions.mergeDuplicateNames(people: people, observations: observations, context: context, defaults: defaults)
        try context.save()

        XCTAssertEqual(merged, 2)
        XCTAssertEqual(Set(try livePeople(context).map(\.id)), [oldest.id, hidden.id, unrelated.id])
        XCTAssertEqual(onNewer.personID, oldest.id)
        XCTAssertEqual(onNewest.personID, oldest.id)
        XCTAssertEqual(rejectsNewer.rejectedPersonIDs, oldest.id)
        XCTAssertEqual(group.rules.rules.first?.value, oldest.id)
    }

    /// The key photo the user picks wins over confirmed and sharper faces,
    /// and a merge drops the merged-away person's choice.
    func testKeyPhotoOverridesTheAutomaticCover() throws {
        let sharp = face("sharp", personID: "alice")
        sharp.quality = 0.95
        let chosen = face("chosen", personID: "alice")
        chosen.quality = 0.2
        XCTAssertEqual(PeopleFacePicker.cover([sharp, chosen])?.id, "sharp")
        let initialSummary = PeoplePersonFacesSnapshot(faces: [sharp, chosen], keyFaceID: nil)
        XCTAssertEqual(initialSummary.cover?.id, "sharp")
        XCTAssertEqual(initialSummary.photoCount, 2)

        PeopleStoreActions.setKeyFace("chosen", for: "alice", defaults: defaults)
        let key = PeopleStoreActions.keyFaceID(for: "alice", defaults: defaults)
        XCTAssertEqual(key, "chosen")
        XCTAssertEqual(PeopleFacePicker.cover([sharp, chosen], keyFaceID: key)?.id, "chosen")
        XCTAssertEqual(PeoplePersonFacesSnapshot(faces: [sharp, chosen], keyFaceID: key).cover?.id, "chosen")
        // A key face that no longer belongs to the person falls back.
        XCTAssertEqual(PeopleFacePicker.cover([sharp], keyFaceID: key)?.id, "sharp")

        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let alice = Person(id: "alice", name: "Alice")
        let bob = Person(id: "bob", name: "Bob")
        [alice, bob].forEach(context.insert)
        [sharp, chosen].forEach(context.insert)
        PeopleStoreActions.merge(sourceID: "alice", into: "bob", people: [alice, bob], observations: [sharp, chosen], context: context, defaults: defaults)
        XCTAssertNil(PeopleStoreActions.keyFaceID(for: "alice", defaults: defaults))
    }
}
