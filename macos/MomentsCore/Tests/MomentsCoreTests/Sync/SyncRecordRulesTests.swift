import Foundation
import XCTest
@testable import MomentsCore

final class SyncSchemaTests: XCTestCase {
    func testEverySpecIsConsistent() {
        for type in SyncRecordType.allCases {
            let spec: SyncTypeSpec = type.spec
            let names: [String] = spec.fields.map(\.name)
            XCTAssertEqual(Set(names).count, names.count, "\(type) lists a field twice")
            XCTAssertNotNil(spec.field(spec.stampField), "\(type) has no stamp field")
            XCTAssertEqual(spec.field(spec.stampField)?.kind, .date)
            if let editor = spec.editorField {
                XCTAssertNotNil(spec.field(editor), "\(type) editor field missing")
            }
            for reference in spec.references {
                XCTAssertNotNil(reference.target, "\(type).\(reference.name) has no target")
            }
            switch spec.ownership {
            case .perAccount(let field), .authored(let field):
                XCTAssertEqual(spec.field(field)?.isAccount, true, "\(type).\(field) must be an account field")
            case .shared, .appendOnly:
                break
            }
            XCTAssertFalse(names.contains(SyncSchema.idField))
        }
    }

    func testLocalOnlyMediaFieldsAreNotInTheSchema() {
        let names: Set<String> = SyncRecordType.mediaItem.spec.fieldNames
        let localOnly: [String] = [
            "originalBookmarkData", "originalFileName", "photosLocalIdentifier", "photosCloudIdentifier",
            "photosAlbumIdentifiersRaw", "pairedVideoBookmarkData", "sourceReferencesRaw", "importSourceIDsRaw",
            "reviewMemoryDraft", "importReviewReasonsRaw"
        ]
        for field in localOnly {
            XCTAssertFalse(names.contains(field), "\(field) must stay on this Mac")
        }
        XCTAssertFalse(SyncRecordType.memory.spec.fieldNames.contains("authorRaw"))
        XCTAssertFalse(SyncRecordType.photoNote.spec.fieldNames.contains("suggestionsData"))
        XCTAssertFalse(SyncRecordType.photoNote.spec.fieldNames.contains("undoData"))
    }

    func testFaceDataHasNoRecordType() {
        let raw: Set<String> = Set(SyncRecordType.allCases.map(\.rawValue))
        for type in ["Person", "FaceObservation", "FaceScanRecord", "ImportSource"] {
            XCTAssertFalse(raw.contains(type))
        }
    }

    func testSanitizedDropsUnknownAndMistypedFields() {
        var record = SyncFixtures.media("m1", trip: "t1")
        record["originalBookmarkData"] = .data(Data([1, 2, 3]))
        record["width"] = .string("wide")
        let clean: SyncRecord = SyncSchema.sanitized(record)
        XCTAssertNil(clean["originalBookmarkData"])
        XCTAssertNil(clean["width"])
        XCTAssertEqual(clean["height"], .int(3000))
        XCTAssertEqual(SyncSchema.unknownFields(in: record), ["originalBookmarkData"])
    }

    func testRecordNamesAreSafeOrHashed() throws {
        XCTAssertEqual(SyncRecordName.make(type: .trip, id: "5D0C6F0E-1A2B-4C3D-8E9F-001122334455"), "Trip-5D0C6F0E-1A2B-4C3D-8E9F-001122334455")
        XCTAssertEqual(SyncRecordName.id(fromPlain: "Trip-t1", type: .trip), "t1")
        XCTAssertNil(SyncRecordName.id(fromPlain: "Trip-t1", type: .tag))
        // Two types with the same ID never share a CloudKit record name.
        XCTAssertNotEqual(SyncRecordName.make(type: .favorite, id: "m1:_u1"), SyncRecordName.make(type: .placeOverride, id: "m1:_u1"))
        // A safe ID too long once its type is added is hashed, and its
        // mapping is kept so the name leads back to it.
        let long = String(repeating: "a", count: 198)
        let longName: String = SyncRecordName.make(type: .trip, id: long)
        XCTAssertTrue(SyncRecordName.isHashed(longName))
        let store = try SyncStateStore(folder: SyncFixtures.temporaryFolder())
        store.setBase(SyncFixtures.trip(long), recordName: longName, systemFields: nil)
        XCTAssertEqual(store.key(type: .trip, hashedRecordName: longName), SyncRecordKey(.trip, long))
        let unsafe: String = "trip-Zürich 2023/11"
        let name: String = SyncRecordName.make(type: .trip, id: unsafe)
        XCTAssertTrue(name.hasPrefix("h-Trip-"))
        XCTAssertTrue(name.unicodeScalars.allSatisfy { $0.isASCII })
        XCTAssertEqual(name, SyncRecordName.make(type: .trip, id: unsafe))
        XCTAssertNotEqual(name, SyncRecordName.make(type: .trip, id: unsafe + "x"))
        XCTAssertFalse(SyncRecordName.isSafe("_starts-with-underscore"))
        XCTAssertFalse(SyncRecordName.isSafe(String(repeating: "a", count: 201)))
    }

    func testDigestIgnoresFieldOrder() {
        let a = SyncRecord(type: .tag, id: "x", fields: ["displayName": .string("A"), "normalizedName": .string("a")])
        var b = SyncRecord(type: .tag, id: "x")
        b["normalizedName"] = .string("a")
        b["displayName"] = .string("A")
        XCTAssertEqual(a.digest, b.digest)
        b["displayName"] = .string("B")
        XCTAssertNotEqual(a.digest, b.digest)
    }
}

final class SyncAccountMapTests: XCTestCase {
    private let map = SyncAccountMap(currentAccountID: SyncFixtures.ownerAccount, partnerAccountID: SyncFixtures.partnerAccount)

    func testLocalAliasBecomesTheRealAccountOnTheWireAndBack() {
        let favorite: SyncRecord = SyncFixtures.favorite(media: "m1", on: true)
        let wire: SyncRecord = map.toWire(favorite)
        XCTAssertEqual(wire.id, "m1:" + SyncFixtures.ownerAccount)
        XCTAssertEqual(wire["accountID"], .string(SyncFixtures.ownerAccount))
        XCTAssertEqual(wire["mediaID"], .reference("m1"))
        XCTAssertEqual(map.fromWire(wire), favorite)
    }

    func testPartnerAccountIsKeptLocally() {
        let partnerSide = SyncAccountMap(currentAccountID: SyncFixtures.partnerAccount, partnerAccountID: SyncFixtures.ownerAccount)
        let mine: SyncRecord = partnerSide.toWire(SyncFixtures.memory("x", media: "m1", text: "hi"))
        let seenByOwner: SyncRecord = map.fromWire(mine)
        XCTAssertEqual(seenByOwner["authorAccountID"], .string(SyncFixtures.partnerAccount))
        XCTAssertEqual(map.role(of: SyncFixtures.partnerAccount), .partner)
        XCTAssertEqual(map.role(of: SyncAccountMap.localAlias), .me)
        XCTAssertEqual(map.role(of: "_someoneElse"), .unresolved)
        XCTAssertFalse(map.canEdit(seenByOwner))
    }

    func testNilAuthorMeansThisDevicesPerson() {
        var memory: SyncRecord = SyncFixtures.memory("x", media: "m1", text: "before sharing")
        memory["authorAccountID"] = nil
        XCTAssertTrue(map.canEdit(memory))
        XCTAssertEqual(map.toWire(memory)["authorAccountID"], .string(SyncFixtures.ownerAccount))
    }

    func testCanEditFollowsOwnership() {
        XCTAssertTrue(map.canEdit(SyncFixtures.trip("t1")))
        XCTAssertTrue(map.canEdit(SyncFixtures.favorite(media: "m1", on: true)))
        XCTAssertFalse(map.canEdit(SyncFixtures.favorite(media: "m1", account: SyncFixtures.partnerAccount, on: true)))
        let partnerRevision = SyncRecord(type: .memoryRevision, id: "r", fields: [
            "editedBy": .string(SyncFixtures.partnerAccount), "editedAt": .date(SyncFixtures.t0)
        ])
        XCTAssertFalse(map.canEdit(partnerRevision))
    }
}

final class SyncMergerTests: XCTestCase {
    func testDisjointFieldChangesBothSurvive() {
        let base: SyncRecord = SyncFixtures.trip("t1", name: "Old", at: 0)
        var local = base
        local["name"] = .string("Renamed here")
        local["updatedAt"] = .date(SyncFixtures.at(10))
        var server = base
        server["confirmedAt"] = .date(SyncFixtures.at(5))
        server["updatedAt"] = .date(SyncFixtures.at(5))

        let result: SyncMergeResult = SyncMerger.merge(base: base, local: local, server: server)
        XCTAssertEqual(result.merged["name"], .string("Renamed here"))
        XCTAssertEqual(result.merged["confirmedAt"], .date(SyncFixtures.at(5)))
        XCTAssertEqual(result.merged["updatedAt"], .date(SyncFixtures.at(10)))
        XCTAssertTrue(result.conflictingFields.isEmpty)
        XCTAssertTrue(result.needsUpload)
    }

    func testSameFieldTakesTheLaterChange() {
        let base: SyncRecord = SyncFixtures.trip("t1", name: "Old", at: 0)
        var local = base
        local["name"] = .string("Earlier")
        local["updatedAt"] = .date(SyncFixtures.at(5))
        var server = base
        server["name"] = .string("Later")
        server["updatedAt"] = .date(SyncFixtures.at(9))

        let result: SyncMergeResult = SyncMerger.merge(base: base, local: local, server: server)
        XCTAssertEqual(result.merged["name"], .string("Later"))
        XCTAssertEqual(result.conflictingFields, ["name"])
        XCTAssertFalse(result.needsUpload)
    }

    func testLosingMemoryTextIsKeptAsARevision() {
        let base: SyncRecord = SyncFixtures.memory("mem", media: "m1", text: "first", at: 0)
        var local = base
        local["text"] = .string("written on the laptop")
        local["updatedAt"] = .date(SyncFixtures.at(20))
        var server = base
        server["text"] = .string("written on the desktop")
        server["updatedAt"] = .date(SyncFixtures.at(10))
        server["revision"] = .int(2)

        let result: SyncMergeResult = SyncMerger.merge(base: base, local: local, server: server)
        XCTAssertEqual(result.merged["text"], .string("written on the laptop"))
        XCTAssertEqual(result.merged["revision"], .int(2))
        XCTAssertEqual(result.keptRevisions.count, 1)
        let kept: SyncRecord = result.keptRevisions[0]
        XCTAssertEqual(kept.type, .memoryRevision)
        XCTAssertEqual(kept["text"], .string("written on the desktop"))
        XCTAssertEqual(kept["memoryID"], .reference("mem"))
        XCTAssertEqual(kept["reason"], .string(SyncMerger.conflictReason))
        let again: SyncMergeResult = SyncMerger.merge(base: base, local: local, server: server)
        XCTAssertEqual(again.keptRevisions.first?.id, kept.id, "retrying must not add a second copy")
    }

    func testImmutableFieldsKeepTheServerValue() {
        let server: SyncRecord = SyncFixtures.memory("mem", media: "m1", text: "a", at: 0)
        var local = server
        local["createdAt"] = .date(SyncFixtures.at(999))
        local["text"] = .string("b")
        local["updatedAt"] = .date(SyncFixtures.at(1))
        let result: SyncMergeResult = SyncMerger.merge(base: server, local: local, server: server)
        XCTAssertEqual(result.merged["createdAt"], .date(SyncFixtures.t0))
        XCTAssertEqual(result.merged["text"], .string("b"))
    }

    func testBothDevicesConvergeOnTies() {
        var a: SyncRecord = SyncFixtures.trip("t1", name: "A", at: 5)
        a["updatedBy"] = .string("_acct-a")
        var b: SyncRecord = SyncFixtures.trip("t1", name: "B", at: 5)
        b["updatedBy"] = .string("_acct-b")
        let one: SyncRecord = SyncMerger.merge(base: nil, local: a, server: b).merged
        let two: SyncRecord = SyncMerger.merge(base: nil, local: b, server: a).merged
        XCTAssertEqual(one, two)
        XCTAssertEqual(one["name"], .string("A"))
    }

    func testDeletionFieldMergesLikeAnyOther() {
        let base: SyncRecord = SyncFixtures.media("m1", trip: "t1")
        var deletedThere = base
        deletedThere["deletedAt"] = .date(SyncFixtures.at(30))
        deletedThere["updatedAt"] = .date(SyncFixtures.at(30))
        var correctedHere = base
        correctedHere["timeZoneIdentifier"] = .string("Etc/GMT-2")
        correctedHere["updatedAt"] = .date(SyncFixtures.at(10))
        let result: SyncMergeResult = SyncMerger.merge(base: base, local: correctedHere, server: deletedThere)
        XCTAssertEqual(result.merged["deletedAt"], .date(SyncFixtures.at(30)))
        XCTAssertEqual(result.merged["timeZoneIdentifier"], .string("Etc/GMT-2"))
    }
}

final class SyncPendingQueueTests: XCTestCase {
    func testLaterChangeReplacesEarlierOne() {
        var queue = SyncPendingQueue()
        let key = SyncRecordKey(.memory, "a")
        queue.enqueueSave(key)
        queue.enqueueDelete(key)
        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.pending(key)?.operation, .delete)
        queue.enqueueSave(key)
        XCTAssertEqual(queue.pending(key)?.operation, .save)
    }

    func testBatchesSendParentsFirstAndDeleteChildrenFirst() {
        var queue = SyncPendingQueue()
        queue.enqueueSave(SyncRecordKey(.memory, "mem"))
        queue.enqueueSave(SyncRecordKey(.mediaItem, "m"))
        queue.enqueueSave(SyncRecordKey(.trip, "t"))
        queue.enqueueDelete(SyncRecordKey(.trip, "old-t"))
        queue.enqueueDelete(SyncRecordKey(.memory, "old-mem"))
        let order: [String] = queue.nextBatch().map { "\($0.operation.rawValue) \($0.key)" }
        XCTAssertEqual(order, [
            "save Trip/t", "save MediaItem/m", "save Memory/mem",
            "delete Memory/old-mem", "delete Trip/old-t"
        ])
        XCTAssertEqual(queue.nextBatch(limit: 2).count, 2)
    }

    func testAnEditDuringASendIsNotLost() {
        var queue = SyncPendingQueue()
        let key = SyncRecordKey(.trip, "t")
        queue.enqueueSave(key)
        let inFlight: SyncPendingChange = queue.nextBatch()[0]
        queue.enqueueSave(key)
        XCTAssertFalse(queue.markSent(inFlight))
        XCTAssertEqual(queue.count, 1)
        let second: SyncPendingChange = queue.nextBatch()[0]
        XCTAssertTrue(queue.markSent(second))
        XCTAssertTrue(queue.isEmpty)
    }

    func testQueueSurvivesEncoding() throws {
        var queue = SyncPendingQueue()
        queue.enqueueSave(SyncRecordKey(.trip, "t"))
        queue.enqueueDelete(SyncRecordKey(.memory, "m"))
        let data: Data = try JSONEncoder().encode(queue)
        let decoded: SyncPendingQueue = try JSONDecoder().decode(SyncPendingQueue.self, from: data)
        XCTAssertEqual(decoded, queue)
    }
}

final class SyncStateStoreTests: XCTestCase {
    func testEverythingSurvivesReopening() throws {
        let folder: URL = SyncFixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try SyncStateStore(folder: folder)
        try first.saveEngineState(Data("engine".utf8), for: .privateDatabase)
        var queue = SyncPendingQueue()
        queue.enqueueSave(SyncRecordKey(.trip, "t1"))
        try first.savePending(queue)
        try first.saveSettings(SyncStateStore.Settings(scope: .selectedTrips(["t1"]), partnerAccountID: SyncFixtures.partnerAccount))
        let trip: SyncRecord = SyncFixtures.trip("t1")
        first.setBase(trip, recordName: "t1", systemFields: Data("tag-1".utf8))
        let unsafe: SyncRecord = SyncFixtures.trip("Zürich trip")
        let hashed: String = SyncRecordName.make(type: .trip, id: unsafe.id)
        first.setBase(unsafe, recordName: hashed, systemFields: nil)
        try first.flushBases()

        let second = try SyncStateStore(folder: folder)
        XCTAssertEqual(second.engineState(for: .privateDatabase), Data("engine".utf8))
        XCTAssertNil(second.engineState(for: .sharedDatabase))
        XCTAssertEqual(second.loadPending(), queue)
        XCTAssertEqual(second.loadSettings().scope, .selectedTrips(["t1"]))
        XCTAssertNil(second.loadSettings().role)
        var settings: SyncStateStore.Settings = second.loadSettings()
        settings.role = .participant
        settings.zoneOwnerName = SyncFixtures.ownerAccount
        try second.saveSettings(settings)
        XCTAssertEqual(try SyncStateStore(folder: folder).loadSettings(), settings)
        XCTAssertEqual(second.base(for: trip.key), trip)
        XCTAssertEqual(second.baseEntry(for: trip.key)?.systemFields, Data("tag-1".utf8))
        XCTAssertEqual(second.key(type: .trip, hashedRecordName: hashed), unsafe.key)

        second.removeBase(trip.key)
        try second.flushBases()
        XCTAssertNil(try SyncStateStore(folder: folder).base(for: trip.key))
    }

    func testResetForgetsSyncStateOnly() throws {
        let folder: URL = SyncFixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try SyncStateStore(folder: folder)
        try store.saveEngineState(Data([1]), for: .sharedDatabase)
        store.setBase(SyncFixtures.trip("t1"), recordName: "t1", systemFields: nil)
        try store.flushBases()
        try store.reset()
        XCTAssertNil(store.engineState(for: .sharedDatabase))
        XCTAssertNil(store.base(for: SyncRecordKey(.trip, "t1")))
    }

    func testAccountFolderDoesNotContainTheAccountID() {
        let root = URL(fileURLWithPath: "/tmp/root")
        let folder: URL = SyncStateStore.accountFolder(root: root, accountID: SyncFixtures.ownerAccount)
        XCTAssertFalse(folder.path.contains(SyncFixtures.ownerAccount))
        XCTAssertNotEqual(folder, SyncStateStore.accountFolder(root: root, accountID: SyncFixtures.partnerAccount))
    }
}
