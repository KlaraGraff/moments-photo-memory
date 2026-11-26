import Foundation
import XCTest
@testable import MomentsCore

final class SharingScopeResolverTests: XCTestCase {
    private func library() -> [SyncRecord] {
        var spot: SyncRecord = SyncFixtures.place("p-spot", name: "Synthetic Spot", parent: "p-city")
        spot["kindRaw"] = .string("spot")
        let city: SyncRecord = SyncFixtures.place("p-city", name: "Synthetic City")
        let otherPlace: SyncRecord = SyncFixtures.place("p-other", name: "Elsewhere")
        let placeNote = SyncRecord(type: .placeNote, id: "pn1", fields: [
            "placeKey": .string("synthetic spot"), "placeName": .string("Synthetic Spot"),
            "text": .string("a quiet corner"), "authorAccountID": .string(SyncAccountMap.localAlias),
            "updatedAt": .date(SyncFixtures.t0)
        ])
        let privateNote = SyncRecord(type: .placeNote, id: "pn2", fields: [
            "placeKey": .string("elsewhere"), "text": .string("not shared"),
            "authorAccountID": .string(SyncAccountMap.localAlias), "updatedAt": .date(SyncFixtures.t0)
        ])
        let dayMemory = SyncRecord(type: .collectionMemory, id: "cm-day", fields: [
            "scopeRaw": .string("day"), "scopeKey": .string("2023-11-14"), "text": .string("a day"),
            "authorAccountID": .string(SyncAccountMap.localAlias), "updatedAt": .date(SyncFixtures.t0)
        ])
        let tripMemory = SyncRecord(type: .collectionMemory, id: "cm-t2", fields: [
            "scopeRaw": .string("trip"), "scopeKey": .string("t2"), "text": .string("other trip"),
            "authorAccountID": .string(SyncAccountMap.localAlias), "updatedAt": .date(SyncFixtures.t0)
        ])
        let revision = SyncRecord(type: .memoryRevision, id: "rev1", fields: [
            "memoryID": .reference("mem1"), "text": .string("older words"), "editedAt": .date(SyncFixtures.t0)
        ])
        let chapter = SyncRecord(type: .userGroup, id: "g1", fields: ["name": .string("Synthetic chapter"), "updatedAt": .date(SyncFixtures.t0)])
        let chapterItem = SyncRecord(type: .userGroupItem, id: "gi1", fields: [
            "groupID": .reference("g1"), "mediaID": .reference("m1"), "addedAt": .date(SyncFixtures.t0)
        ])
        return [
            SyncFixtures.trip("t1"), SyncFixtures.trip("t2"),
            spot, city, otherPlace,
            SyncFixtures.media("m1", trip: "t1", place: "p-spot"),
            SyncFixtures.media("m2", trip: "t2", place: "p-other", day: "2024-01-01"),
            SyncFixtures.media("m3", trip: nil),
            SyncFixtures.memory("mem1", media: "m1", text: "shared words"),
            SyncFixtures.memory("mem2", media: "m2", text: "private words"),
            SyncFixtures.tag("tg1", name: "Beach"), SyncFixtures.tag("tg2", name: "Unused"),
            SyncFixtures.mediaTag(media: "m1", tag: "tg1"), SyncFixtures.mediaTag(media: "m2", tag: "tg2"),
            SyncFixtures.favorite(media: "m1", on: true), SyncFixtures.favorite(media: "m2", on: true),
            placeNote, privateNote, dayMemory, tripMemory, revision, chapter, chapterItem
        ]
    }

    func testOnlyTheChosenTripAndWhatHangsOffItAreShared() {
        let keys: Set<SyncRecordKey> = SharingScopeResolver.includedKeys(scope: .selectedTrips(["t1"]), records: library())
        let names: [String] = keys.sorted().map(\.description)
        XCTAssertEqual(names, [
            "Place/p-city", "Place/p-spot", "Tag/tg1", "UserGroup/g1",
            "Trip/t1",
            "MediaItem/m1",
            "Favorite/m1:local-me", "MediaTag/m1:tg1", "Memory/mem1", "UserGroupItem/gi1",
            "CollectionMemory/cm-day", "MemoryRevision/rev1", "PlaceNote/pn1"
        ])
    }

    func testWholeLibraryIncludesEverything() {
        let records: [SyncRecord] = library()
        XCTAssertEqual(SharingScopeResolver.includedKeys(scope: .wholeLibrary, records: records).count, records.count)
    }

    func testNoTripsSharesNothing() {
        XCTAssertTrue(SharingScopeResolver.includedKeys(scope: .selectedTrips([]), records: library()).isEmpty)
    }

    func testScopeEditing() {
        let scope: SharingScope = SharingScope.selectedTrips(["t1"]).adding(tripID: "t2").removing(tripID: "t1")
        XCTAssertEqual(scope, .selectedTrips(["t2"]))
        XCTAssertTrue(SharingScope.wholeLibrary.contains(tripID: "anything"))
    }
}

/// Two people, three Macs (the owner has two), one shared zone.
final class TwoPersonSyncTests: XCTestCase {
    private var server: InMemorySyncServer!
    private var owner: SimulatedDevice!
    private var partner: SimulatedDevice!

    override func setUpWithError() throws {
        server = InMemorySyncServer()
        let records: [SyncRecord] = [
            SyncFixtures.trip("t1", name: "Shared trip"), SyncFixtures.trip("t2", name: "Private trip"),
            SyncFixtures.place("p-city", name: "Synthetic City"),
            SyncFixtures.place("p-spot", name: "Synthetic Spot", parent: "p-city"),
            SyncFixtures.media("m1", trip: "t1", place: "p-spot"),
            SyncFixtures.media("m2", trip: "t2"),
            SyncFixtures.memory("mem1", media: "m1", text: "his words"),
            SyncFixtures.memory("mem2", media: "m2", text: "private words"),
            SyncFixtures.tag("tg1", name: "Beach"),
            SyncFixtures.mediaTag(media: "m1", tag: "tg1"),
            SyncFixtures.favorite(media: "m1", on: true)
        ]
        owner = try SimulatedDevice(account: SyncFixtures.ownerAccount, partner: SyncFixtures.partnerAccount, server: server, database: .privateDatabase, records: records)
        partner = try SimulatedDevice(account: SyncFixtures.partnerAccount, partner: SyncFixtures.ownerAccount, server: server, database: .sharedDatabase)
        owner.coordinator.updateSharedKeys(sharedKeys(of: owner, trips: ["t1"]))
        owner.driver.send()
        partner.driver.fetch()
        partner.coordinator.updateSharedKeys(sharedKeys(of: partner, trips: tripIDs(of: partner)))
    }

    private func sharedKeys(of device: SimulatedDevice, trips: Set<String>) -> Set<SyncRecordKey> {
        SharingScopeResolver.includedKeys(scope: .selectedTrips(trips), records: Array(device.local.records.values))
    }

    private func tripIDs(of device: SimulatedDevice) -> Set<String> {
        Set(device.local.records.keys.filter { $0.type == .trip }.map(\.id))
    }

    func testPartnerReceivesOnlyTheSharedTrip() {
        XCTAssertEqual(server.recordCount, 8)
        let received: [String] = partner.local.records.keys.sorted().map(\.description)
        XCTAssertEqual(received, [
            "Place/p-city", "Place/p-spot", "Tag/tg1", "Trip/t1", "MediaItem/m1",
            "Favorite/m1:" + SyncFixtures.ownerAccount, "MediaTag/m1:tg1", "Memory/mem1"
        ])
        let memory: SyncRecord? = partner.local.record(for: SyncRecordKey(.memory, "mem1"))
        XCTAssertEqual(memory?["authorAccountID"], .string(SyncFixtures.ownerAccount))
        XCTAssertEqual(partner.coordinator.accounts.role(of: memory?["authorAccountID"]?.stringValue), .partner)
        XCTAssertNil(memory?[SyncSchema.idField])
        XCTAssertTrue(partner.coordinator.pending.isEmpty, "receiving must not queue anything to send back")
    }

    func testPartnersNewMemoryReachesTheOwnerUnderHerName() {
        partner.edit(SyncFixtures.memory("her-mem", media: "m1", text: "her words", at: 50))
        XCTAssertEqual(partner.coordinator.pending.count, 1, "a memory on a shared photo is shared at once")
        partner.driver.send()
        owner.driver.fetch()

        let seen: SyncRecord? = owner.local.record(for: SyncRecordKey(.memory, "her-mem"))
        XCTAssertEqual(seen?["text"], .string("her words"))
        XCTAssertEqual(seen?["authorAccountID"], .string(SyncFixtures.partnerAccount))
        XCTAssertEqual(owner.coordinator.accounts.role(of: SyncFixtures.partnerAccount), .partner)
        XCTAssertFalse(owner.coordinator.accounts.canEdit(seen!))
    }

    func testNobodyCanSendChangesToTheOtherPersonsMemory() {
        var hers: SyncRecord = partner.local.record(for: SyncRecordKey(.memory, "mem1"))!
        hers["text"] = .string("tampered")
        partner.edit(hers)
        XCTAssertTrue(partner.coordinator.pending.isEmpty)
        partner.driver.send()
        owner.driver.fetch()
        XCTAssertEqual(owner.text(of: "mem1"), "his words")
    }

    func testFavoritesArePerPersonAndNeverConflict() {
        partner.edit(SyncFixtures.favorite(media: "m1", on: true, at: 5))
        owner.edit(SyncFixtures.favorite(media: "m1", on: false, at: 6))
        partner.driver.send()
        let merges: [SyncMergeResult] = owner.driver.sync()
        XCTAssertTrue(merges.allSatisfy { $0.conflictingFields.isEmpty }, "two people's favorites never conflict")
        partner.driver.fetch()

        let hisOnHerMac: SyncRecord? = partner.local.record(for: SyncRecordKey(.favorite, "m1:" + SyncFixtures.ownerAccount))
        let hersOnHisMac: SyncRecord? = owner.local.record(for: SyncRecordKey(.favorite, "m1:" + SyncFixtures.partnerAccount))
        XCTAssertEqual(hisOnHerMac?["isFavorite"], .bool(false))
        XCTAssertEqual(hersOnHisMac?["isFavorite"], .bool(true))
        XCTAssertEqual(owner.local.record(for: SyncRecordKey(.favorite, "m1:local-me"))?["isFavorite"], .bool(false))
    }

    func testOfflineEditsOnTheOwnersTwoMacsKeepBothTexts() throws {
        let laptop = try SimulatedDevice(account: SyncFixtures.ownerAccount, partner: SyncFixtures.partnerAccount, server: server, database: .privateDatabase)
        laptop.driver.fetch()
        XCTAssertEqual(laptop.text(of: "mem1"), "his words")

        var onDesktop: SyncRecord = owner.local.record(for: SyncRecordKey(.memory, "mem1"))!
        onDesktop["text"] = .string("desktop version")
        onDesktop["updatedAt"] = .date(SyncFixtures.at(100))
        owner.edit(onDesktop)
        var onLaptop: SyncRecord = laptop.local.record(for: SyncRecordKey(.memory, "mem1"))!
        onLaptop["text"] = .string("laptop version")
        onLaptop["updatedAt"] = .date(SyncFixtures.at(200))
        laptop.edit(onLaptop)

        owner.driver.send()
        let merges: [SyncMergeResult] = laptop.driver.send()
        XCTAssertEqual(merges.count, 1)
        XCTAssertEqual(merges.first?.conflictingFields, ["text"])
        owner.driver.fetch()
        partner.driver.fetch()

        XCTAssertEqual(owner.text(of: "mem1"), "laptop version")
        XCTAssertEqual(laptop.text(of: "mem1"), "laptop version")
        XCTAssertEqual(partner.text(of: "mem1"), "laptop version")
        let kept: [SyncRecord] = owner.local.records.values.filter { $0.type == .memoryRevision }
        XCTAssertEqual(kept.map { $0["text"] }, [.string("desktop version")])
        XCTAssertTrue(laptop.coordinator.pending.isEmpty)
    }

    func testAnOfflineEditDoesNotBringBackADeletedRecord() throws {
        let laptop = try SimulatedDevice(account: SyncFixtures.ownerAccount, partner: SyncFixtures.partnerAccount, server: server, database: .privateDatabase)
        laptop.driver.fetch()
        var edited: SyncRecord = laptop.local.record(for: SyncRecordKey(.memory, "mem1"))!
        edited["text"] = .string("edited offline")
        edited["updatedAt"] = .date(SyncFixtures.at(300))
        laptop.edit(edited)

        owner.delete(SyncRecordKey(.memory, "mem1"))
        owner.driver.send()
        laptop.driver.send()
        partner.driver.fetch()

        XCTAssertNil(server.record(type: .memory, recordName: SyncRecordName.make(type: .memory, id: "mem1")))
        XCTAssertNil(laptop.text(of: "mem1"))
        XCTAssertNil(partner.text(of: "mem1"))
    }

    func testUnsharingATripRemovesItFromTheZoneButNotFromTheOwnersMac() {
        partner.edit(SyncFixtures.memory("her-mem", media: "m1", text: "her words"))
        partner.coordinator.updateSharedKeys(sharedKeys(of: partner, trips: tripIDs(of: partner)))
        partner.driver.send()
        owner.driver.fetch()
        owner.coordinator.updateSharedKeys(sharedKeys(of: owner, trips: ["t1"]))
        XCTAssertTrue(owner.coordinator.pending.isEmpty, "recomputing an unchanged scope sends nothing")

        owner.coordinator.updateSharedKeys(sharedKeys(of: owner, trips: []))
        owner.driver.send()
        partner.driver.fetch()

        XCTAssertEqual(server.recordCount, 0)
        XCTAssertTrue(partner.local.records.isEmpty)
        XCTAssertEqual(owner.text(of: "mem1"), "his words")
        XCTAssertEqual(owner.text(of: "her-mem"), "her words", "her words stay on his Mac")
        XCTAssertNotNil(owner.local.record(for: SyncRecordKey(.trip, "t1")))
    }

    func testUnsharingATripSticksAcrossARelaunch() throws {
        // He unshares the trip and the app quits before the next sync.
        try owner.coordinator.flush()
        let relaunched = SyncCoordinator(
            accounts: owner.coordinator.accounts,
            state: try SyncStateStore(folder: owner.folder),
            database: .privateDatabase,
            local: owner.local
        )
        relaunched.updateSharedKeys(sharedKeys(of: owner, trips: []))
        InMemorySyncDriver(coordinator: relaunched, server: server).send()
        partner.driver.fetch()

        XCTAssertEqual(server.recordCount, 0)
        XCTAssertTrue(partner.local.records.isEmpty)
        XCTAssertNotNil(owner.local.record(for: SyncRecordKey(.trip, "t1")))
    }

    func testARelaunchKeepsPlacesThePartnersRecordsPointAt() throws {
        let override = SyncRecord(type: .placeOverride, id: "m1:" + SyncAccountMap.localAlias, fields: [
            "mediaID": .reference("m1"), "placeID": .reference("p-spot"), "accountID": .string(SyncAccountMap.localAlias),
            "nameOverride": .string("Our bench"), "updatedAt": .date(SyncFixtures.at(9))
        ])
        partner.edit(override)
        partner.driver.send()
        owner.driver.fetch()
        try owner.coordinator.flush()
        let relaunched = SyncCoordinator(
            accounts: owner.coordinator.accounts,
            state: try SyncStateStore(folder: owner.folder),
            database: .privateDatabase,
            local: owner.local
        )
        relaunched.updateSharedKeys(sharedKeys(of: owner, trips: []))
        InMemorySyncDriver(coordinator: relaunched, server: server).send()

        XCTAssertNotNil(server.record(type: .place, recordName: SyncRecordName.make(type: .place, id: "p-spot")))
        XCTAssertNotNil(server.record(type: .place, recordName: SyncRecordName.make(type: .place, id: "p-city")))
        XCTAssertNil(server.record(type: .trip, recordName: SyncRecordName.make(type: .trip, id: "t1")))
    }

    func testARelaunchWithTheSameScopeSendsNothing() throws {
        try owner.coordinator.flush()
        let relaunched = SyncCoordinator(
            accounts: owner.coordinator.accounts,
            state: try SyncStateStore(folder: owner.folder),
            database: .privateDatabase,
            local: owner.local
        )
        relaunched.updateSharedKeys(sharedKeys(of: owner, trips: ["t1"]))
        XCTAssertTrue(relaunched.pending.isEmpty)
    }

    func testAFavoriteAndAPersonalPlaceNameOnOnePhotoAreTwoRecords() {
        let override = SyncRecord(type: .placeOverride, id: "m1:" + SyncAccountMap.localAlias, fields: [
            "mediaID": .reference("m1"), "accountID": .string(SyncAccountMap.localAlias),
            "nameOverride": .string("Our bench"), "updatedAt": .date(SyncFixtures.at(9))
        ])
        partner.edit(SyncFixtures.favorite(media: "m1", on: true, at: 8))
        partner.edit(override)
        partner.driver.send()
        owner.driver.fetch()

        let wireID = "m1:" + SyncFixtures.partnerAccount
        XCTAssertEqual(owner.local.record(for: SyncRecordKey(.favorite, wireID))?["isFavorite"], .bool(true))
        XCTAssertEqual(owner.local.record(for: SyncRecordKey(.placeOverride, wireID))?["nameOverride"], .string("Our bench"))
        XCTAssertTrue(partner.coordinator.pending.isEmpty)
    }

    func testAFetchDoesNotOverwriteAnEditNotYetQueued() {
        var hers: SyncRecord = partner.local.record(for: SyncRecordKey(.trip, "t1"))!
        hers["overrideName"] = .string("Her name")
        hers["updatedAt"] = .date(SyncFixtures.at(20))
        partner.edit(hers)
        partner.driver.send()

        // He renames it too; the change is saved but reconcile hasn't run.
        var his: SyncRecord = owner.local.record(for: SyncRecordKey(.trip, "t1"))!
        his["overrideName"] = .string("His later name")
        his["updatedAt"] = .date(SyncFixtures.at(30))
        owner.local.apply(his)
        owner.driver.fetch()

        XCTAssertEqual(owner.local.record(for: SyncRecordKey(.trip, "t1"))?["overrideName"], .string("His later name"))
        owner.driver.send()
        partner.driver.fetch()
        XCTAssertEqual(partner.local.record(for: SyncRecordKey(.trip, "t1"))?["overrideName"], .string("His later name"))
    }

    func testSharingASecondTripLaterUploadsIt() {
        owner.coordinator.updateSharedKeys(sharedKeys(of: owner, trips: ["t1", "t2"]))
        owner.driver.send()
        partner.driver.fetch()
        XCTAssertEqual(partner.text(of: "mem2"), "private words")
        XCTAssertNotNil(partner.local.record(for: SyncRecordKey(.trip, "t2")))
    }

    func testOfflineChangesWaitAndSurviveARelaunch() throws {
        server.isReachable = false
        var renamed: SyncRecord = owner.local.record(for: SyncRecordKey(.trip, "t1"))!
        renamed["overrideName"] = .string("Renamed offline")
        renamed["updatedAt"] = .date(SyncFixtures.at(40))
        owner.edit(renamed)
        owner.driver.send()
        XCTAssertEqual(owner.coordinator.pending.count, 1)
        try owner.coordinator.flush()

        let relaunched = SyncCoordinator(
            accounts: owner.coordinator.accounts,
            state: try SyncStateStore(folder: owner.folder),
            database: .privateDatabase,
            local: owner.local
        )
        XCTAssertEqual(relaunched.pending.count, 1)
        server.isReachable = true
        InMemorySyncDriver(coordinator: relaunched, server: server).send()
        partner.driver.fetch()
        XCTAssertEqual(partner.local.record(for: SyncRecordKey(.trip, "t1"))?["overrideName"], .string("Renamed offline"))
    }

    func testADayMemoryWaitsForTheSharedSetToBeRecomputed() {
        let day = SyncRecord(type: .collectionMemory, id: "cm-day", fields: [
            "scopeRaw": .string("day"), "scopeKey": .string("2023-11-14"), "text": .string("a whole day"),
            "authorAccountID": .string(SyncAccountMap.localAlias), "createdAt": .date(SyncFixtures.t0),
            "updatedAt": .date(SyncFixtures.at(1))
        ])
        owner.edit(day)
        XCTAssertTrue(owner.coordinator.pending.isEmpty)
        owner.coordinator.updateSharedKeys(sharedKeys(of: owner, trips: ["t1"]))
        XCTAssertEqual(owner.coordinator.pending.pending(day.key)?.operation, .save)
    }

    func testATagAddedToASharedPhotoBringsTheTagAlong() {
        owner.edit(SyncFixtures.tag("tg-new", name: "Sunset"))
        XCTAssertTrue(owner.coordinator.pending.isEmpty, "a tag on its own is not shared")
        owner.edit(SyncFixtures.mediaTag(media: "m1", tag: "tg-new"))
        owner.driver.send()
        partner.driver.fetch()
        XCTAssertEqual(partner.local.record(for: SyncRecordKey(.tag, "tg-new"))?["displayName"], .string("Sunset"))
        XCTAssertNotNil(partner.local.record(for: SyncRecordKey(.mediaTag, "m1:tg-new")))
    }

    func testThePartnerNeverRemovesRecordsFromTheZoneByScope() {
        partner.coordinator.updateSharedKeys([])
        XCTAssertTrue(partner.coordinator.pending.isEmpty)
    }

    func testARecordDeletedBeforeItWasSentIsForgotten() {
        let memory: SyncRecord = SyncFixtures.memory("draft", media: "m1", text: "typo")
        owner.edit(memory)
        owner.delete(memory.key)
        XCTAssertTrue(owner.coordinator.pending.isEmpty)
    }

    func testOwnFetchedDeletesDoNotRemoveLocalRecords() {
        owner.coordinator.updateSharedKeys(sharedKeys(of: owner, trips: []))
        owner.driver.send()
        owner.driver.fetch()
        XCTAssertEqual(owner.text(of: "mem1"), "his words")
    }

    func testReconcileFindsEditsAndDeletesWithoutPerEditHooks() {
        var renamed: SyncRecord = owner.local.record(for: SyncRecordKey(.trip, "t1"))!
        renamed["overrideName"] = .string("Renamed quietly")
        owner.local.write(renamed)
        owner.local.remove(SyncRecordKey(.mediaTag, "m1:tg1"))
        owner.local.write(SyncFixtures.memory("new-mem", media: "m1", text: "new words"))
        owner.local.write(SyncFixtures.memory("private-new", media: "m2", text: "stays here"))

        owner.coordinator.reconcile(localRecords: Array(owner.local.records.values))
        let queued: [String] = owner.coordinator.pending.nextBatch().map { "\($0.operation.rawValue) \($0.key)" }
        XCTAssertEqual(queued, ["save Trip/t1", "save Memory/new-mem", "delete MediaTag/m1:tg1"])

        owner.driver.send()
        owner.coordinator.reconcile(localRecords: Array(owner.local.records.values))
        XCTAssertTrue(owner.coordinator.pending.isEmpty, "a second pass finds nothing new")
    }

    func testReconcileIgnoresSubMillisecondDateNoise() {
        var trip: SyncRecord = owner.local.record(for: SyncRecordKey(.trip, "t1"))!
        trip["updatedAt"] = .date(SyncFixtures.t0.addingTimeInterval(0.0001))
        owner.local.write(trip)
        owner.coordinator.reconcile(localRecords: Array(owner.local.records.values))
        XCTAssertTrue(owner.coordinator.pending.isEmpty)
    }

    func testReconcileTreatsAnEmptyOwnerAsThisDevicesPerson() {
        var item: SyncRecord = owner.local.record(for: SyncRecordKey(.mediaItem, "m1"))!
        XCTAssertNil(item["ownerAccountID"])
        owner.driver.fetch()
        item["ownerAccountID"] = nil
        owner.local.write(item)
        owner.coordinator.reconcile(localRecords: Array(owner.local.records.values))
        XCTAssertNil(owner.coordinator.pending.pending(item.key))
    }

    func testReconcileNeverDeletesThePartnersRecords() {
        partner.local.remove(SyncRecordKey(.memory, "mem1"))
        partner.coordinator.reconcile(localRecords: Array(partner.local.records.values))
        XCTAssertTrue(partner.coordinator.pending.isEmpty)
    }

    func testBothPeopleRenamingTheSameTripConverge() {
        var his: SyncRecord = owner.local.record(for: SyncRecordKey(.trip, "t1"))!
        his["overrideName"] = .string("His name")
        his["updatedAt"] = .date(SyncFixtures.at(10))
        his["updatedBy"] = .string(SyncAccountMap.localAlias)
        owner.edit(his)
        var hers: SyncRecord = partner.local.record(for: SyncRecordKey(.trip, "t1"))!
        hers["overrideName"] = .string("Her name")
        hers["updatedAt"] = .date(SyncFixtures.at(20))
        hers["updatedBy"] = .string(SyncAccountMap.localAlias)
        partner.edit(hers)

        owner.driver.send()
        partner.driver.sync()
        owner.driver.fetch()
        let onHis: SyncValue? = owner.local.record(for: SyncRecordKey(.trip, "t1"))?["overrideName"]
        let onHers: SyncValue? = partner.local.record(for: SyncRecordKey(.trip, "t1"))?["overrideName"]
        XCTAssertEqual(onHis, .string("Her name"))
        XCTAssertEqual(onHers, .string("Her name"))
        XCTAssertEqual(owner.local.record(for: SyncRecordKey(.trip, "t1"))?["updatedBy"], .string(SyncFixtures.partnerAccount))
    }
}
