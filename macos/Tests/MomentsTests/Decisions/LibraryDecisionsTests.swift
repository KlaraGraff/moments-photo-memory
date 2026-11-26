import SwiftData
import XCTest
@testable import Moments

/// Schema V9: the choices that lived in user defaults move into the store.
/// Temp folders, throwaway defaults suites and synthetic IDs only.
@MainActor
final class LibraryDecisionsTests: XCTestCase {
    private var folder: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "moments-decisions-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        suiteName = "moments-decisions-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: folder)
    }

    private var storeURL: URL { folder.appending(path: "Moments.store") }

    /// A V8 store with synthetic data opens with the V9 schema: nothing is
    /// lost and the new table works.
    func testV8StoreWithDataOpensAsV9() throws {
        do {
            let old: ModelContainer = try MomentsPersistence.makeV8Container(url: storeURL)
            let item = MediaItem(id: "synthetic-v8-photo")
            old.mainContext.insert(item)
            old.mainContext.insert(Memory(text: "synthetic v8 memory", mediaItem: item))
            old.mainContext.insert(Trip(id: "synthetic-v8-trip", name: "Synthetic trip"))
            try old.mainContext.save()
        }
        let container: ModelContainer = try MomentsPersistence.makeContainer(url: storeURL)
        let context = container.mainContext
        let items: [MediaItem] = try context.fetch(FetchDescriptor<MediaItem>())
        let memories: [Memory] = try context.fetch(FetchDescriptor<Memory>())
        let trips: [Trip] = try context.fetch(FetchDescriptor<Trip>())
        XCTAssertEqual(items.map(\.id), ["synthetic-v8-photo"])
        XCTAssertEqual(memories.map(\.text), ["synthetic v8 memory"])
        XCTAssertEqual(trips.map(\.id), ["synthetic-v8-trip"])
        let empty: [LocalDecision] = try context.fetch(FetchDescriptor<LocalDecision>())
        XCTAssertTrue(empty.isEmpty)
        context.insert(LocalDecision(key: "synthetic.key", value: Data([1])))
        XCTAssertNoThrow(try context.save())
    }

    /// The first open copies every moved key from user defaults, once, and
    /// leaves user defaults as they were (a way back).
    func testFirstOpenCopiesDecisionsFromDefaultsOnce() async throws {
        let container: ModelContainer = try MomentsPersistence.makeContainer(url: storeURL)
        defaults.set(["synthetic-photo-1", "synthetic-photo-2"], forKey: TripAssignmentLocks.defaultsKey)
        defaults.set(TripCoverChoice.encode(["synthetic-trip": "synthetic-photo-1"]), forKey: TripCoverChoice.defaultsKey)
        defaults.set(["synthetic-person"], forKey: PeopleStoreActions.keepSeparateKey)
        defaults.set(["synthetic-person": "synthetic-face"], forKey: PeopleStoreActions.keyFacesKey)
        defaults.set(Data("[]".utf8), forKey: PeopleGroupStore.groupsKey)
        defaults.set(true, forKey: PeopleGroupStore.seededKey)
        defaults.set(2, forKey: PeopleScanStore.groupingVersionKey)
        defaults.set("Synthetic editor", forKey: TripCorrectionLog.editorKey)

        let decisions = LibraryDecisions()
        decisions.configure(container: container, importingFrom: defaults)

        XCTAssertEqual(TripAssignmentLocks.lockedIDs(defaults: decisions), ["synthetic-photo-1", "synthetic-photo-2"])
        XCTAssertEqual(TripCoverChoice.decode(decisions.string(forKey: TripCoverChoice.defaultsKey) ?? ""), ["synthetic-trip": "synthetic-photo-1"])
        XCTAssertEqual(PeopleStoreActions.keepSeparateIDs(decisions), ["synthetic-person"])
        XCTAssertEqual(PeopleStoreActions.keyFaceID(for: "synthetic-person", defaults: decisions), "synthetic-face")
        XCTAssertEqual(decisions.data(forKey: PeopleGroupStore.groupsKey), Data("[]".utf8))
        XCTAssertTrue(decisions.bool(forKey: PeopleGroupStore.seededKey))
        XCTAssertEqual(decisions.integer(forKey: PeopleScanStore.groupingVersionKey), 2)
        XCTAssertNil(decisions.object(forKey: TripCorrectionLog.editorKey), "the editor name is a setting and stays in user defaults")
        XCTAssertEqual(defaults.stringArray(forKey: TripAssignmentLocks.defaultsKey), ["synthetic-photo-1", "synthetic-photo-2"], "user defaults keep their copy")

        // A second open does not copy again: a later change in user defaults
        // (for example an older build still running) is not pulled in.
        defaults.set(["synthetic-other"], forKey: TripAssignmentLocks.defaultsKey)
        let reopened = LibraryDecisions()
        reopened.configure(container: container, importingFrom: defaults)
        XCTAssertEqual(TripAssignmentLocks.lockedIDs(defaults: reopened), ["synthetic-photo-1", "synthetic-photo-2"])
    }

    /// Writes reach the store, in order, and survive closing and reopening it.
    func testWritesPersistAcrossReopen() async throws {
        do {
            let container: ModelContainer = try MomentsPersistence.makeContainer(url: storeURL)
            let decisions = LibraryDecisions()
            decisions.configure(container: container, importingFrom: nil)
            TripAssignmentLocks.lock("synthetic-a", defaults: decisions)
            TripAssignmentLocks.lock("synthetic-b", defaults: decisions)
            PeopleStoreActions.setKeepSeparate("synthetic-person", true, defaults: decisions)
            PeopleStoreActions.setKeepSeparate("synthetic-person", false, defaults: decisions)
            decisions.set(3, forKey: PeopleScanStore.groupingVersionKey)
            await decisions.flush()
            let rows: [LocalDecision] = try container.mainContext.fetch(FetchDescriptor<LocalDecision>())
            let keys: [String] = rows.map(\.key).sorted()
            XCTAssertEqual(keys, [PeopleScanStore.groupingVersionKey, TripAssignmentLocks.defaultsKey].sorted())
        }
        let container: ModelContainer = try MomentsPersistence.makeContainer(url: storeURL)
        let reopened = LibraryDecisions()
        reopened.configure(container: container, importingFrom: nil)
        XCTAssertEqual(TripAssignmentLocks.lockedIDs(defaults: reopened), ["synthetic-a", "synthetic-b"])
        XCTAssertTrue(PeopleStoreActions.keepSeparateIDs(reopened).isEmpty)
        XCTAssertEqual(reopened.integer(forKey: PeopleScanStore.groupingVersionKey), 3)
    }

    /// A decision never saves an edit someone hasn't finished: it writes
    /// through a context of its own.
    func testADecisionDoesNotSaveTheMainContext() async throws {
        let container: ModelContainer = try MomentsPersistence.makeContainer(url: storeURL)
        let decisions = LibraryDecisions()
        decisions.configure(container: container, importingFrom: nil)
        container.mainContext.insert(MediaItem(id: "synthetic-unsaved"))
        TripAssignmentLocks.lock("synthetic-a", defaults: decisions)
        await decisions.flush()
        XCTAssertTrue(container.mainContext.hasChanges, "the main context's own edit is still unsaved")
        let other = ModelContext(container)
        let saved: [MediaItem] = try other.fetch(FetchDescriptor<MediaItem>())
        XCTAssertTrue(saved.isEmpty)
    }

    /// Without a store (unit tests) values live in memory only.
    func testUnconfiguredStoreKeepsValuesInMemory() {
        let decisions = LibraryDecisions()
        decisions.set(["synthetic"], forKey: EventSuggestions.suggestedDaysKey)
        XCTAssertEqual(decisions.stringArray(forKey: EventSuggestions.suggestedDaysKey), ["synthetic"])
        decisions.removeObject(forKey: EventSuggestions.suggestedDaysKey)
        XCTAssertNil(decisions.object(forKey: EventSuggestions.suggestedDaysKey))
    }

    /// A restored backup from before V9 brings its choices back through user
    /// defaults; the restored store copies them in when it opens.
    func testRestoredOlderBackupCopiesItsDecisionsIn() async throws {
        let location = LibraryLocation(storeURL: storeURL, correctionLogURL: folder.appending(path: "trip-corrections.jsonl"))
        do {
            let container: ModelContainer = try MomentsPersistence.makeContainer(url: storeURL)
            container.mainContext.insert(MediaItem(id: "synthetic-a"))
            try container.mainContext.save()
        }
        defaults.set(["synthetic-a"], forKey: TripAssignmentLocks.defaultsKey)
        // Labelled as a V8 backup, as one made before this build would be.
        let backup = try LibraryBackup.makeBackup(.daily, location: location, defaults: defaults, now: Date(timeIntervalSince1970: 1_790_000_000), schemaVersion: "8.0.0")
        defaults.set(["synthetic-a", "synthetic-later"], forKey: TripAssignmentLocks.defaultsKey)

        try LibraryBackup.scheduleRestore(from: backup, location: location)
        let notice = LibraryBackup.performPendingRestore(location: location, defaults: defaults)
        XCTAssertNil(notice?.failure)
        XCTAssertEqual(defaults.stringArray(forKey: TripAssignmentLocks.defaultsKey), ["synthetic-a"])

        let container: ModelContainer = try MomentsPersistence.makeContainer(url: storeURL)
        let decisions = LibraryDecisions()
        decisions.configure(container: container, importingFrom: defaults)
        XCTAssertEqual(TripAssignmentLocks.lockedIDs(defaults: decisions), ["synthetic-a"])
    }

    /// A V9 backup carries the decisions in its store.
    func testV9BackupRestoresDecisionsFromItsStore() async throws {
        let location = LibraryLocation(storeURL: storeURL, correctionLogURL: folder.appending(path: "trip-corrections.jsonl"))
        let backup: URL
        do {
            let container: ModelContainer = try MomentsPersistence.makeContainer(url: storeURL)
            let decisions = LibraryDecisions()
            decisions.configure(container: container, importingFrom: nil)
            TripAssignmentLocks.lock("synthetic-a", defaults: decisions)
            await decisions.flush()
            backup = try LibraryBackup.makeBackup(.daily, location: location, defaults: defaults, now: Date(timeIntervalSince1970: 1_790_000_000))
            TripAssignmentLocks.lock("synthetic-later", defaults: decisions)
            await decisions.flush()
        }
        try LibraryBackup.scheduleRestore(from: backup, location: location)
        XCTAssertNil(LibraryBackup.performPendingRestore(location: location, defaults: defaults)?.failure)

        let container: ModelContainer = try MomentsPersistence.makeContainer(url: storeURL)
        let restored = LibraryDecisions()
        restored.configure(container: container, importingFrom: defaults)
        XCTAssertEqual(TripAssignmentLocks.lockedIDs(defaults: restored), ["synthetic-a"])
    }
}
