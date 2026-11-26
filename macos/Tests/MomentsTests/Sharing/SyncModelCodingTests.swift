import Foundation
import MomentsCore
import SwiftData
import XCTest
@testable import Moments

/// The SwiftData side of sync, with synthetic data and in-memory stores only.
@MainActor
final class SyncModelCodingTests: XCTestCase {
    private let ownerAccount = "_owner0000000000000000000000000001"
    private let partnerAccount = "_partner00000000000000000000000002"
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private var containers: [ModelContainer] = []

    override func tearDown() {
        containers.removeAll()
        super.tearDown()
    }

    private func makeContext() throws -> ModelContext {
        let container: ModelContainer = try MomentsPersistence.makeContainer(inMemory: true)
        containers.append(container)
        return container.mainContext
    }

    private func store(_ context: ModelContext, account: String, partner: String) -> SwiftDataSyncStore {
        SwiftDataSyncStore(
            context: context,
            accounts: SyncAccountMap(currentAccountID: account, partnerAccountID: partner),
            orphans: SyncOrphanLinks(file: nil)
        )
    }

    /// One of everything that syncs, plus local-only data that must not.
    private func seedLibrary(_ context: ModelContext) throws {
        let city = Place(id: "p-city", name: "Synthetic City", kind: .city, latitude: 0.01, longitude: 0.02, updatedAt: t0)
        let spot = Place(id: "p-spot", name: "Synthetic Spot", kind: .spot, latitude: 0.011, longitude: 0.021, parent: city, updatedAt: t0)
        let trip = Trip(id: "t1", name: "Synthetic trip", startDate: t0, endDate: t0.addingTimeInterval(86_400), updatedAt: t0)
        trip.overrideName = "Renamed trip"
        let item = MediaItem(
            id: "m1", captureDate: t0, latitude: 0.011, longitude: 0.021, width: 4000, height: 3000,
            title: "Synthetic photo", place: spot, trip: trip, updatedAt: t0,
            originalBookmarkData: Data([0xDE, 0xAD]), originalFileName: "IMG_0001.HEIC", originalContentHash: "hash-1",
            localDayKey: "2023-11-14", photosLocalIdentifier: "local-photos-id"
        )
        let memory = Memory(id: "mem1", text: "Synthetic words", authorAccountID: SyncAccountMap.localAlias, createdAt: t0, updatedAt: t0, mediaItem: item)
        let revision = MemoryRevision(id: "rev1", text: "Older words", editedBy: SyncAccountMap.localAlias, editedAt: t0, baseRevision: 1, reason: "edit", memory: memory)
        let tag = Tag(id: "tg1", displayName: "Beach", updatedAt: t0)
        let join = MediaTag(id: "m1:tg1", updatedAt: t0, mediaItem: item, tag: tag)
        let favorite = Favorite(isFavorite: true, changedAt: t0, mediaItem: item)
        let override = PlaceOverride(nameOverride: "Our spot", updatedAt: t0, mediaItem: item)
        let group = UserGroup(id: "g1", name: "Synthetic chapter", kind: .chapter, createdAt: t0, updatedAt: t0)
        let groupItem = UserGroupItem(id: "gi1", groupID: "g1", mediaID: "m1", addedAt: t0)
        let note = PhotoNote(id: "n1", mediaID: "m1", text: "Synthetic note", createdAt: t0, status: .ready)
        note.suggestionsData = Data("[]".utf8)
        let placeNote = PlaceNote(id: "pn1", placeName: "Synthetic Spot", text: "Quiet corner", updatedAt: t0, sourceNoteID: "n1")
        let dayMemory = CollectionMemory(id: "cm1", scope: .day, scopeKey: "2023-11-14", text: "A whole day", createdAt: t0, sourceNoteID: "n1")
        context.insert(city)
        context.insert(spot)
        context.insert(trip)
        context.insert(item)
        context.insert(memory)
        context.insert(revision)
        context.insert(tag)
        context.insert(join)
        context.insert(favorite)
        context.insert(override)
        context.insert(group)
        context.insert(groupItem)
        context.insert(note)
        context.insert(placeNote)
        context.insert(dayMemory)
        try context.save()
    }

    private func sorted(_ records: [SyncRecord]) -> [SyncRecord] {
        records.map(\.normalized).sorted { $0.key < $1.key }
    }

    func testEveryRecordRoundTripsThroughAnotherStore() throws {
        let source: ModelContext = try makeContext()
        try seedLibrary(source)
        let sent: [SyncRecord] = try store(source, account: ownerAccount, partner: partnerAccount).allRecords()
        XCTAssertEqual(Set(sent.map(\.type)).count, SyncRecordType.allCases.count - 1, "every type but previews")

        let target: ModelContext = try makeContext()
        let receiver: SwiftDataSyncStore = store(target, account: ownerAccount, partner: partnerAccount)
        for record in sent.reversed() { receiver.apply(record) }
        try receiver.save()
        XCTAssertNil(receiver.lastApplyError)

        let received: [SyncRecord] = try receiver.allRecords()
        XCTAssertEqual(sorted(received), sorted(sent))
    }

    func testOnlySchemaFieldsAreEncoded() throws {
        let context: ModelContext = try makeContext()
        try seedLibrary(context)
        for record in try store(context, account: ownerAccount, partner: partnerAccount).allRecords() {
            XCTAssertEqual(SyncSchema.unknownFields(in: record), [], "\(record.key)")
            for value in record.fields.values {
                XCTAssertNotEqual(value, .data(Data([0xDE, 0xAD])), "bookmarks never leave the Mac")
                XCTAssertNotEqual(value, .string("local-photos-id"))
                XCTAssertNotEqual(value, .string("IMG_0001.HEIC"))
                XCTAssertNotEqual(value, .string("Synthetic photo"), "titles are file names and stay on this Mac")
            }
        }
    }

    func testChildrenArrivingFirstAreLinkedWhenTheParentArrives() throws {
        let source: ModelContext = try makeContext()
        try seedLibrary(source)
        let sent: [SyncRecord] = try store(source, account: ownerAccount, partner: partnerAccount).allRecords()
        func one(_ type: SyncRecordType, _ id: String) -> SyncRecord { sent.first { $0.key == SyncRecordKey(type, id) }! }

        let target: ModelContext = try makeContext()
        let receiver: SwiftDataSyncStore = store(target, account: ownerAccount, partner: partnerAccount)
        receiver.apply(one(.memory, "mem1"))
        receiver.apply(one(.mediaItem, "m1"))
        receiver.apply(one(.place, "p-spot"))
        XCTAssertEqual(receiver.record(for: SyncRecordKey(.place, "p-spot"))?["parentID"], .reference("p-city"), "a missing parent is still reported")
        receiver.apply(one(.place, "p-city"))
        receiver.apply(one(.trip, "t1"))
        try receiver.save()

        let item: MediaItem? = try target.fetch(FetchDescriptor<MediaItem>()).first
        XCTAssertEqual(item?.trip?.id, "t1")
        XCTAssertEqual(item?.place?.id, "p-spot")
        XCTAssertEqual(item?.place?.parent?.id, "p-city")
        XCTAssertEqual(item?.memories.map(\.id), ["mem1"])
        XCTAssertEqual(receiver.orphans.waiting(.placeParent, on: "p-city"), [])
    }

    func testThePartnersWordsArriveAsTheirsAndAreNotReorganized() throws {
        let context: ModelContext = try makeContext()
        let receiver: SwiftDataSyncStore = store(context, account: ownerAccount, partner: partnerAccount)
        receiver.apply(SyncRecord(type: .memory, id: "her-mem", fields: [
            "text": .string("Her words"), "authorAccountID": .string(partnerAccount),
            "createdAt": .date(t0), "updatedAt": .date(t0), "revision": .int(1)
        ]))
        receiver.apply(SyncRecord(type: .photoNote, id: "her-note", fields: [
            "mediaID": .reference("m1"), "text": .string("Her note"), "authorAccountID": .string(partnerAccount),
            "createdAt": .date(t0), "updatedAt": .date(t0)
        ]))
        try receiver.save()

        let memory: Memory? = try context.fetch(FetchDescriptor<Memory>()).first
        XCTAssertEqual(memory?.author, .partner)
        XCTAssertEqual(memory?.authorAccountID, partnerAccount)
        let note: PhotoNote? = try context.fetch(FetchDescriptor<PhotoNote>()).first
        XCTAssertEqual(note?.status, .done)
        XCTAssertEqual(note?.authorAccountID, partnerAccount)
    }

    func testDeletionFromTheZoneNeverRemovesThisMacsOwnPhoto() throws {
        let context: ModelContext = try makeContext()
        try seedLibrary(context)
        let receiver: SwiftDataSyncStore = store(context, account: ownerAccount, partner: partnerAccount)
        receiver.applyDeletion(SyncRecordKey(.mediaItem, "m1"))
        try receiver.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<MediaItem>()).count, 1)

        receiver.apply(SyncRecord(type: .mediaItem, id: "shared-1", fields: ["updatedAt": .date(t0), "kindRaw": .string("photo")]))
        try receiver.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<MediaItem>()).count, 2)
        receiver.applyDeletion(SyncRecordKey(.mediaItem, "shared-1"))
        try receiver.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<MediaItem>()).map(\.id), ["m1"])
    }

    /// The whole path on SwiftData: his Mac shares one trip, hers receives
    /// it, she writes a memory, he receives it under her name.
    func testTwoMacsShareATripThroughSwiftData() throws {
        let server = InMemorySyncServer()
        let hisContext: ModelContext = try makeContext()
        try seedLibrary(hisContext)
        hisContext.insert(Trip(id: "t-private", name: "Private trip", updatedAt: t0))
        hisContext.insert(MediaItem(id: "m-private", title: "Private photo", tripID: "t-private", updatedAt: t0))
        try hisContext.save()
        let herContext: ModelContext = try makeContext()

        let folder = FileManager.default.temporaryDirectory.appending(path: "moments-sync-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let his: SwiftDataSyncStore = store(hisContext, account: ownerAccount, partner: partnerAccount)
        let hers: SwiftDataSyncStore = store(herContext, account: partnerAccount, partner: ownerAccount)
        let hisSync = SyncCoordinator(
            accounts: his.accounts,
            state: try SyncStateStore(folder: folder.appending(path: "his")),
            database: .privateDatabase,
            local: his
        )
        let herSync = SyncCoordinator(
            accounts: hers.accounts,
            state: try SyncStateStore(folder: folder.appending(path: "hers")),
            database: .sharedDatabase,
            local: hers
        )
        let hisDriver = InMemorySyncDriver(coordinator: hisSync, server: server)
        let herDriver = InMemorySyncDriver(coordinator: herSync, server: server)

        let hisRecords: [SyncRecord] = try his.allRecords()
        hisSync.updateSharedKeys(SharingScopeResolver.includedKeys(scope: .selectedTrips(["t1"]), records: hisRecords))
        hisDriver.send()
        herDriver.fetch()
        try hers.save()

        let herTrips: [String] = try herContext.fetch(FetchDescriptor<Trip>()).map(\.id)
        XCTAssertEqual(herTrips, ["t1"])
        let herPhotos: [MediaItem] = try herContext.fetch(FetchDescriptor<MediaItem>())
        XCTAssertEqual(herPhotos.map(\.id), ["m1"])
        XCTAssertEqual(herPhotos.first?.sourceRaw, SyncModelCoding.sharedSourceRaw)
        XCTAssertNil(herPhotos.first?.originalBookmarkData)
        XCTAssertEqual(herPhotos.first?.trip?.id, "t1")
        XCTAssertEqual(herPhotos.first?.memories.first?.author, .partner)
        XCTAssertFalse(herPhotos.first?.isFavorite ?? true, "his favorite is not hers")

        let photo: MediaItem = herPhotos[0]
        herContext.insert(Memory(id: "her-mem", text: "Her words", authorAccountID: SyncAccountMap.localAlias, createdAt: t0, updatedAt: t0.addingTimeInterval(60), mediaItem: photo))
        try herContext.save()
        herSync.reconcile(localRecords: try hers.allRecords())
        XCTAssertEqual(herSync.pending.count, 1, "only her new memory goes out")
        herDriver.send()
        hisDriver.fetch()
        try his.save()

        let hisView: Memory? = try hisContext.fetch(FetchDescriptor<Memory>(predicate: #Predicate { $0.id == "her-mem" })).first
        XCTAssertEqual(hisView?.text, "Her words")
        XCTAssertEqual(hisView?.author, .partner)
        XCTAssertEqual(hisView?.mediaItem?.id, "m1")

        hisSync.reconcile(localRecords: try his.allRecords())
        herSync.reconcile(localRecords: try hers.allRecords())
        XCTAssertTrue(hisSync.pending.isEmpty, "received records are not sent back")
        XCTAssertTrue(herSync.pending.isEmpty)
    }
}
