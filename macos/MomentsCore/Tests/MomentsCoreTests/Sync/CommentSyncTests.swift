import Foundation
import XCTest
@testable import MomentsCore

/// Comments, replies and notifications between two people (issue #28).
/// Synthetic records only.
final class CommentSyncTests: XCTestCase {
    private var server: InMemorySyncServer!
    private var owner: SimulatedDevice!
    private var partner: SimulatedDevice!

    override func setUpWithError() throws {
        server = InMemorySyncServer()
        let records: [SyncRecord] = [
            SyncFixtures.trip("t1", name: "Shared trip"), SyncFixtures.trip("t2", name: "Private trip"),
            SyncFixtures.media("m1", trip: "t1"),
            SyncFixtures.media("m2", trip: "t2"),
            SyncFixtures.memory("mem1", media: "m1", text: "his words"),
            SyncFixtures.memory("mem2", media: "m2", text: "private words"),
            SyncFixtures.comment("c-private", memory: "mem2", text: "not shared")
        ]
        owner = try SimulatedDevice(account: SyncFixtures.ownerAccount, partner: SyncFixtures.partnerAccount, server: server, database: .privateDatabase, records: records)
        partner = try SimulatedDevice(account: SyncFixtures.partnerAccount, partner: SyncFixtures.ownerAccount, server: server, database: .sharedDatabase)
        owner.coordinator.updateSharedKeys(keys(of: owner, trips: ["t1"]))
        owner.driver.send()
        partner.driver.fetch()
        partner.coordinator.updateSharedKeys(keys(of: partner, trips: Set(partner.local.records.keys.filter { $0.type == .trip }.map(\.id))))
    }

    private func keys(of device: SimulatedDevice, trips: Set<String>) -> Set<SyncRecordKey> {
        SharingScopeResolver.includedKeys(scope: .selectedTrips(trips), records: Array(device.local.records.values))
    }

    func testCommentsFollowTheirMemoryIntoTheShare() {
        let shared = keys(of: owner, trips: ["t1"])
        XCTAssertFalse(shared.contains(SyncRecordKey(.comment, "c-private")), "a comment on an unshared photo stays home")
        owner.edit(SyncFixtures.comment("c1", memory: "mem1", text: "a note on my own words", at: 10))
        XCTAssertEqual(owner.coordinator.pending.count, 1, "a comment on a shared memory is shared at once")
        owner.driver.send()
        partner.driver.fetch()
        XCTAssertNotNil(partner.local.record(for: SyncRecordKey(.comment, "c1")))
        XCTAssertNil(partner.local.record(for: SyncRecordKey(.comment, "c-private")))
    }

    func testThePartnerCommentsAndRepliesUnderHerName() {
        owner.edit(SyncFixtures.comment("c-his", memory: "mem1", text: "remember the wind", at: 10))
        owner.driver.send()
        partner.driver.fetch()
        partner.edit(SyncFixtures.comment("c-her", memory: "mem1", parent: "c-his", text: "and the kite", at: 20))
        XCTAssertEqual(partner.coordinator.pending.count, 1)
        partner.driver.send()
        owner.driver.fetch()

        let reply = owner.local.record(for: SyncRecordKey(.comment, "c-her"))
        XCTAssertEqual(reply?["authorAccountID"], .string(SyncFixtures.partnerAccount))
        XCTAssertEqual(reply?["parentCommentID"], .reference("c-his"))
        XCTAssertEqual(reply?["memoryID"], .reference("mem1"))
        XCTAssertFalse(owner.coordinator.accounts.canEdit(reply!), "her reply is hers alone")
    }

    func testNobodyCanChangeOrDeleteTheOtherPersonsComment() {
        owner.edit(SyncFixtures.comment("c-his", memory: "mem1", text: "his comment", at: 10))
        owner.driver.send()
        partner.driver.fetch()

        var tampered = partner.local.record(for: SyncRecordKey(.comment, "c-his"))!
        tampered["text"] = .string("tampered")
        partner.edit(tampered)
        XCTAssertTrue(partner.coordinator.pending.isEmpty)

        partner.coordinator.reconcile(localRecords: Array(partner.local.records.values.filter { $0.key != tampered.key }))
        XCTAssertTrue(partner.coordinator.pending.isEmpty, "her Mac never deletes his comment from the zone")
        partner.driver.send()
        owner.driver.fetch()
        XCTAssertEqual(owner.local.record(for: SyncRecordKey(.comment, "c-his"))?["text"], .string("his comment"))
    }

    func testANewMemoryFromThePartnerIsAnArrivalButAnEditIsNot() {
        partner.edit(SyncFixtures.memory("her-mem", media: "m1", text: "  her words  ", at: 40))
        partner.driver.send()
        owner.driver.fetch()
        XCTAssertEqual(owner.driver.lastArrivals, [
            SyncArrival(kind: .memory, recordID: "her-mem", memoryID: "her-mem", text: "her words")
        ])

        var edited = partner.local.record(for: SyncRecordKey(.memory, "her-mem"))!
        edited["text"] = .string("her words, longer")
        edited["updatedAt"] = .date(SyncFixtures.at(41))
        partner.edit(edited)
        partner.driver.send()
        owner.driver.fetch()
        XCTAssertEqual(owner.local.record(for: SyncRecordKey(.memory, "her-mem"))?["text"], .string("her words, longer"))
        XCTAssertTrue(owner.driver.lastArrivals.isEmpty, "a changed memory is not announced")
    }

    func testCommentsOnHisMemoryAndRepliesToHisCommentsAreArrivals() {
        owner.edit(SyncFixtures.comment("c-his", memory: "mem1", text: "his comment", at: 10))
        owner.driver.send()
        partner.driver.fetch()
        partner.edit(SyncFixtures.memory("her-mem", media: "m1", text: "her memory", at: 20))
        partner.edit(SyncFixtures.comment("c-on-his", memory: "mem1", text: "on his memory", at: 21))
        partner.edit(SyncFixtures.comment("c-reply", memory: "mem1", parent: "c-his", text: "reply to him", at: 22))
        partner.edit(SyncFixtures.comment("c-on-hers", memory: "her-mem", text: "on her own memory", at: 23))
        partner.driver.send()
        owner.driver.fetch()

        let kinds = Dictionary(uniqueKeysWithValues: owner.driver.lastArrivals.map { ($0.recordID, $0.kind) })
        XCTAssertEqual(kinds, ["her-mem": .memory, "c-on-his": .comment, "c-reply": .reply])
    }

    func testWordsFromThisPersonsOtherMacAreNotArrivals() throws {
        let secondMac = try SimulatedDevice(account: SyncFixtures.ownerAccount, partner: SyncFixtures.partnerAccount, server: server, database: .privateDatabase)
        secondMac.driver.fetch()
        owner.edit(SyncFixtures.memory("his-new", media: "m1", text: "written on his first Mac", at: 50))
        owner.edit(SyncFixtures.comment("c-new", memory: "mem1", text: "also his", at: 51))
        owner.driver.send()
        secondMac.driver.fetch()
        XCTAssertNotNil(secondMac.local.record(for: SyncRecordKey(.memory, "his-new")))
        XCTAssertTrue(secondMac.driver.lastArrivals.isEmpty)
    }

    func testAnEmptyMemoryIsNotAnArrival() {
        partner.edit(SyncFixtures.memory("her-empty", media: "m1", text: "   ", at: 60))
        partner.driver.send()
        owner.driver.fetch()
        XCTAssertTrue(owner.driver.lastArrivals.isEmpty)
    }

    func testNoticesAreSingleWhileFewAndOneSummaryWhenMany() {
        let few = (1...3).map { SyncArrival(kind: .memory, recordID: "m\($0)", memoryID: "m\($0)", text: "words") }
        XCTAssertEqual(SyncArrivalNotices.notices(for: few), few.map(SyncArrivalNotices.Notice.single))
        XCTAssertEqual(SyncArrivalNotices.notices(for: few + [few[0]]).count, 3, "the same record is announced once")
        let many = (1...12).map { SyncArrival(kind: .comment, recordID: "c\($0)", memoryID: "m", text: "words") }
        XCTAssertEqual(SyncArrivalNotices.notices(for: many), [.summary(count: 12)])
        XCTAssertEqual(SyncArrivalNotices.notices(for: []), [])
    }
}
