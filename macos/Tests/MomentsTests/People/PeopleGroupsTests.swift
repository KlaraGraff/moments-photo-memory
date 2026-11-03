import Foundation
import XCTest
@testable import Moments

/// Groups for named people. Every ID and name here is synthetic.
final class PeopleGroupsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "people-groups-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func makeGroup(named name: String) -> PeopleGroup {
        PeopleGroupStore.create(name: name, defaults: defaults)
    }

    // MARK: Seeding

    func testFirstReadCreatesTheThreeStartingGroupsOnce() {
        let first: [PeopleGroup] = PeopleGroupStore.groups(defaults: defaults)
        XCTAssertEqual(first.count, 3)
        XCTAssertEqual(Set(first.map { (group: PeopleGroup) -> String in group.id }).count, 3)
        XCTAssertTrue(first.allSatisfy { (group: PeopleGroup) -> Bool in !group.name.isEmpty })

        // A second read returns the same groups, not three more.
        let second: [PeopleGroup] = PeopleGroupStore.groups(defaults: defaults)
        XCTAssertEqual(second.map { (group: PeopleGroup) -> String in group.id }, first.map { (group: PeopleGroup) -> String in group.id })
        XCTAssertEqual(second.map { (group: PeopleGroup) -> String in group.name }, first.map { (group: PeopleGroup) -> String in group.name })
    }

    func testDeletingEveryGroupDoesNotSeedAgain() {
        let seeded: [PeopleGroup] = PeopleGroupStore.groups(defaults: defaults)
        XCTAssertEqual(seeded.count, 3)
        for group in seeded {
            PeopleGroupStore.delete(group.id, defaults: defaults)
        }
        let after: [PeopleGroup] = PeopleGroupStore.groups(defaults: defaults)
        XCTAssertTrue(after.isEmpty, "deleted groups came back: \(after.map { (group: PeopleGroup) -> String in group.name })")

        // Creating one by hand after the deletion still does not re-seed.
        _ = makeGroup(named: "Chosen by hand")
        let created: [PeopleGroup] = PeopleGroupStore.groups(defaults: defaults)
        XCTAssertEqual(created.count, 1)
    }

    // MARK: Create and rename

    func testCreateAppendsAndTrimsTheName() {
        _ = PeopleGroupStore.groups(defaults: defaults)
        let created: PeopleGroup = makeGroup(named: "  Hiking  ")
        XCTAssertEqual(created.name, "Hiking")
        let all: [PeopleGroup] = PeopleGroupStore.groups(defaults: defaults)
        XCTAssertEqual(all.count, 4)
        XCTAssertEqual(all.last, created)
    }

    func testRenameKeepsTheMembers() {
        let group: PeopleGroup = makeGroup(named: "Hiking")
        PeopleGroupStore.toggle(personID: "person-1", in: group.id, defaults: defaults)
        PeopleGroupStore.rename(group.id, to: "Trips", defaults: defaults)

        let renamed: [PeopleGroup] = PeopleGroupStore.groups(defaults: defaults)
        let found: PeopleGroup? = renamed.first { (candidate: PeopleGroup) -> Bool in candidate.id == group.id }
        XCTAssertEqual(found?.name, "Trips")
        XCTAssertEqual(PeopleGroupStore.members(of: group.id, defaults: defaults), ["person-1"])
    }

    func testRenameToAnEmptyNameIsIgnored() {
        let group: PeopleGroup = makeGroup(named: "Hiking")
        PeopleGroupStore.rename(group.id, to: "   ", defaults: defaults)
        let all: [PeopleGroup] = PeopleGroupStore.groups(defaults: defaults)
        let found: PeopleGroup? = all.first { (candidate: PeopleGroup) -> Bool in candidate.id == group.id }
        XCTAssertEqual(found?.name, "Hiking")
    }

    // MARK: Membership

    func testToggleAddsThenRemoves() {
        let group: PeopleGroup = makeGroup(named: "Hiking")
        XCTAssertTrue(PeopleGroupStore.members(of: group.id, defaults: defaults).isEmpty)

        PeopleGroupStore.toggle(personID: "person-1", in: group.id, defaults: defaults)
        XCTAssertEqual(PeopleGroupStore.members(of: group.id, defaults: defaults), ["person-1"])
        XCTAssertEqual(PeopleGroupStore.groups(of: "person-1", defaults: defaults), [group.id])

        PeopleGroupStore.toggle(personID: "person-1", in: group.id, defaults: defaults)
        XCTAssertTrue(PeopleGroupStore.members(of: group.id, defaults: defaults).isEmpty)
        XCTAssertTrue(PeopleGroupStore.groups(of: "person-1", defaults: defaults).isEmpty)
        // An empty group stays; taking the last person out does not delete it.
        let all: [PeopleGroup] = PeopleGroupStore.groups(defaults: defaults)
        XCTAssertTrue(all.contains { (candidate: PeopleGroup) -> Bool in candidate.id == group.id })
    }

    func testAPersonCanBeInTwoGroups() {
        let first: PeopleGroup = makeGroup(named: "Hiking")
        let second: PeopleGroup = makeGroup(named: "Coffee")
        PeopleGroupStore.toggle(personID: "person-1", in: first.id, defaults: defaults)
        PeopleGroupStore.toggle(personID: "person-1", in: second.id, defaults: defaults)

        XCTAssertEqual(PeopleGroupStore.groups(of: "person-1", defaults: defaults), [first.id, second.id])
        XCTAssertEqual(PeopleGroupStore.members(of: first.id, defaults: defaults), ["person-1"])
        XCTAssertEqual(PeopleGroupStore.members(of: second.id, defaults: defaults), ["person-1"])
    }

    // MARK: Delete

    func testDeleteRemovesTheGroupAndOnlyItsMemberList() {
        let kept: PeopleGroup = makeGroup(named: "Hiking")
        let removed: PeopleGroup = makeGroup(named: "Coffee")
        PeopleGroupStore.toggle(personID: "person-1", in: kept.id, defaults: defaults)
        PeopleGroupStore.toggle(personID: "person-1", in: removed.id, defaults: defaults)
        PeopleGroupStore.toggle(personID: "person-2", in: removed.id, defaults: defaults)

        PeopleGroupStore.delete(removed.id, defaults: defaults)

        let remaining: [PeopleGroup] = PeopleGroupStore.groups(defaults: defaults)
        XCTAssertFalse(remaining.contains { (candidate: PeopleGroup) -> Bool in candidate.id == removed.id })
        XCTAssertTrue(remaining.contains { (candidate: PeopleGroup) -> Bool in candidate.id == kept.id })

        // The deleted group's members are gone; the other group is untouched,
        // and the people themselves are only stored as IDs, so nothing of
        // theirs is left behind.
        XCTAssertTrue(PeopleGroupStore.members(of: removed.id, defaults: defaults).isEmpty)
        XCTAssertEqual(PeopleGroupStore.members(of: kept.id, defaults: defaults), ["person-1"])
        XCTAssertEqual(PeopleGroupStore.groups(of: "person-1", defaults: defaults), [kept.id])
        XCTAssertTrue(PeopleGroupStore.groups(of: "person-2", defaults: defaults).isEmpty)

        let stored: [String: Set<String>] = PeopleGroupStore.allMembers(defaults: defaults)
        XCTAssertEqual(Set(stored.keys), [kept.id])
    }

    /// Only opaque IDs are written: a person's name never reaches the defaults.
    func testOnlyOpaqueIDsAreStored() throws {
        let group: PeopleGroup = makeGroup(named: "Hiking")
        PeopleGroupStore.toggle(personID: "person-1", in: group.id, defaults: defaults)
        let data: Data = try XCTUnwrap(defaults.data(forKey: PeopleGroupStore.membersKey))
        let json: String = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("person-1"))
        XCTAssertFalse(json.contains("Alice"))
    }
}
