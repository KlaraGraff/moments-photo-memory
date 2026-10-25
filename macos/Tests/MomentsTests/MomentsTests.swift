import Foundation
import SwiftData
import XCTest
import SQLite3
@testable import Moments

@MainActor
final class MomentsTests: XCTestCase {
    func testMediaMemoryRelationship() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let item = MediaItem(id: "relationship-demo", title: "Relationship demo")
        let memory = Memory(text: "A shared synthetic memory", author: .partner, mediaItem: item)
        context.insert(item)
        context.insert(memory)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<MediaItem>())
        XCTAssertEqual(fetched.first?.memories.first?.text, "A shared synthetic memory")
        XCTAssertEqual(fetched.first?.memories.first?.author, .partner)
        XCTAssertTrue(fetched.first?.memories.first?.mediaItem === fetched.first)
    }

    func testDemoSeedingCreatesSyntheticItemsAndRelationships() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let url = repositoryRoot().appendingPathComponent("demo/sample-data.json")
        try DemoSeeder.seedIfNeeded(context: context, data: Data(contentsOf: url))

        let items = try context.fetch(FetchDescriptor<MediaItem>())
        let trips = try context.fetch(FetchDescriptor<Trip>())
        let tags = try context.fetch(FetchDescriptor<Tag>())
        let memories = try context.fetch(FetchDescriptor<Memory>())
        XCTAssertEqual(items.count, 27)
        XCTAssertEqual(trips.count, 2)
        XCTAssertGreaterThan(tags.count, 0)
        XCTAssertTrue(tags.allSatisfy { !$0.items.isEmpty })
        XCTAssertEqual(items.first?.source, .demo)
        XCTAssertEqual(memories.count, 1)
        XCTAssertFalse(trips.allSatisfy { $0.items.isEmpty })
        XCTAssertTrue(items.allSatisfy { $0.place != nil })
        XCTAssertTrue(try context.fetch(FetchDescriptor<Place>()).allSatisfy { !$0.items.isEmpty })
        XCTAssertTrue(items.allSatisfy { $0.latitude == nil || (0...0.02).contains($0.latitude!) })
    }

    func testPlaceOverridesKeepOriginalPlaceAndGPS() throws {
        let storeURL = temporaryStoreURL("place")
        defer { removeStore(at: storeURL) }
        let container = try MomentsPersistence.makeContainer(url: storeURL)
        let context = container.mainContext
        let place = Place(id: "original-place", name: "Original place", latitude: 0.001, longitude: 0.002)
        let item = MediaItem(id: "override-demo", latitude: 0.003, longitude: 0.004, place: place)
        context.insert(place)
        context.insert(item)
        context.insert(PlaceOverride(
            placeID: place.id,
            mediaID: item.id,
            nameOverride: "Edited place",
            mapLinkOverride: "https://maps.example.invalid/edited",
            latitude: 0.005,
            longitude: 0.006,
            place: place,
            mediaItem: item
        ))
        try context.save()

        let reopened = try MomentsPersistence.makeContainer(url: storeURL)
        let fetched = try reopened.mainContext.fetch(FetchDescriptor<MediaItem>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.place?.name, "Original place")
        XCTAssertEqual(fetched.first?.effectivePlaceName, "Edited place")
        XCTAssertEqual(fetched.first?.effectiveMapLink, "https://maps.example.invalid/edited")
        XCTAssertEqual(fetched.first?.effectiveCoordinate?.latitude, 0.005)
        XCTAssertEqual(fetched.first?.latitude, 0.003)
    }

    func testLibraryFiltersHideOnlyExplicitScreenshotsByDefault() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let ordinary = MediaItem(id: "ordinary", width: 2_000, height: 1_500)
        let possible = MediaItem(id: "possible", width: 1_170, height: 2_532)
        let named = MediaItem(id: "named", width: 2_000, height: 1_500, title: "Screenshot 2026-01-01")
        let explicit = MediaItem(id: "explicit", width: 2_000, height: 1_500, isScreenshot: true)
        [ordinary, possible, named, explicit].forEach(context.insert)

        let all = LibraryFilterEngine.filteredItems([ordinary, possible, named, explicit], by: .default)
        XCTAssertEqual(Set(all.map { $0.id }), ["ordinary", "possible", "named"])
        XCTAssertTrue(LibraryFilterEngine.isPossibleScreenshot(possible))
        XCTAssertTrue(LibraryFilterEngine.isPossibleScreenshot(named))
        XCTAssertFalse(LibraryFilterEngine.isPossibleScreenshot(explicit))

        var possibleOnly = LibraryFilterCriteria.default
        possibleOnly.screenshotFilter = .possibleOnly
        let candidates = LibraryFilterEngine.filteredItems([ordinary, possible, named, explicit], by: possibleOnly)
        XCTAssertEqual(Set(candidates.map { $0.id }), ["possible", "named"])
    }

    /// Measures the work Library redoes when its inputs change (filter + group) on
    /// the 5,000-item debug library. Scrolling itself does not regroup.
    func testFiveThousandItemFilterAndGroupStaysUnderFrameBudgetTimesTen() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        XCTAssertEqual(try DemoSeeder.generateSyntheticLibrary(count: 5_000, context: context), 5_000)
        let items = try context.fetch(FetchDescriptor<MediaItem>())

        let start = Date()
        let visible = LibraryFilterEngine.filteredItems(items, by: .default)
        let groups = LibraryFilterEngine.groupedItems(visible, by: .default, sortOrder: .oldestFirst)
        let elapsed = Date().timeIntervalSince(start)
        print("Library 5k filter+group: \(Int(elapsed * 1_000)) ms, \(groups.count) collections")

        XCTAssertFalse(groups.isEmpty)
        XCTAssertLessThan(elapsed, 0.5)
    }

    func testLibraryFilterLogicCombinesDatePlaceTypeFavoriteAndTrip() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let place = Place(id: "filter-place", name: "Filter place")
        let first = MediaItem(id: "first", captureDate: Date(timeIntervalSince1970: 1_700_000_000), kind: .photo, tripID: "trip-a", place: place)
        let second = MediaItem(id: "second", captureDate: Date(timeIntervalSince1970: 1_700_100_000), kind: .video, tripID: "trip-b", place: place)
        context.insert(place)
        [first, second].forEach(context.insert)
        first.setFavorite(true, context: context)
        try context.save()

        var criteria = LibraryFilterCriteria.default
        criteria.placeID = place.id
        criteria.mediaType = .photo
        criteria.favoritesOnly = true
        criteria.tripKey = "trip-a"
        criteria.fromDate = Date(timeIntervalSince1970: 1_699_999_000)
        criteria.toDate = Date(timeIntervalSince1970: 1_700_010_000)
        XCTAssertEqual(LibraryFilterEngine.filteredItems([first, second], by: criteria).map(\.id), ["first"])

        context.insert(PlaceOverride(mediaID: first.id, nameOverride: "Edited filter place", mediaItem: first))
        try context.save()
        criteria.placeID = "override:Edited filter place"
        criteria.mediaType = .all
        criteria.favoritesOnly = false
        criteria.tripKey = nil
        criteria.fromDate = nil
        criteria.toDate = nil
        XCTAssertEqual(LibraryFilterEngine.filteredItems([first, second], by: criteria).map(\.id), ["first"])
    }

    func testSelectionModelSharesFocusedSelection() {
        let selection = SelectionModel()
        selection.select(["b", "a"], focus: "b")
        XCTAssertEqual(selection.selectedItemIDs, ["a", "b"])
        XCTAssertEqual(selection.focusedItemID, "b")
        selection.toggle("b")
        XCTAssertEqual(selection.selectedItemIDs, ["a"])
        XCTAssertEqual(selection.focusedItemID, "a")
        selection.clear()
        XCTAssertTrue(selection.selectedItemIDs.isEmpty)
    }

    func testMemorySurvivesModelContainerReopen() throws {
        let storeURL = temporaryStoreURL("model")
        defer { removeStore(at: storeURL) }
        do {
            let container = try MomentsPersistence.makeContainer(url: storeURL)
            let context = container.mainContext
            let item = MediaItem(id: "reopen-demo", title: "Reopen demo")
            context.insert(item)
            context.insert(Memory(text: "Persisted across a reopen", mediaItem: item))
            try context.save()
        }
        do {
            let reopened = try MomentsPersistence.makeContainer(url: storeURL)
            let memories = try reopened.mainContext.fetch(FetchDescriptor<Memory>())
            XCTAssertEqual(memories.count, 1)
            XCTAssertEqual(memories.first?.id.count, 36)
            XCTAssertEqual(memories.first?.text, "Persisted across a reopen")
            XCTAssertEqual(memories.first?.author, .me)
            XCTAssertEqual(memories.first?.mediaItem?.id, "reopen-demo")
        }
    }

    func testStableIDsAndRevisionSurviveReopen() throws {
        let storeURL = temporaryStoreURL("stable-ids")
        defer { removeStore(at: storeURL) }
        let memoryID = "memory-stable"
        let revisionID = "revision-stable"
        do {
            let container = try MomentsPersistence.makeContainer(url: storeURL)
            let context = container.mainContext
            let item = MediaItem(id: "media-stable")
            let memory = Memory(id: memoryID, text: "first", revision: 2, mediaItem: item)
            let revision = MemoryRevision(id: revisionID, text: "losing text", baseRevision: 1, memory: memory)
            context.insert(item)
            context.insert(memory)
            context.insert(revision)
            try context.save()
        }
        let reopened = try MomentsPersistence.makeContainer(url: storeURL)
        let memory = try reopened.mainContext.fetch(FetchDescriptor<Memory>()).first
        let revision = try reopened.mainContext.fetch(FetchDescriptor<MemoryRevision>()).first
        XCTAssertEqual(memory?.id, memoryID)
        XCTAssertEqual(memory?.revision, 2)
        XCTAssertEqual(revision?.id, revisionID)
        XCTAssertEqual(revision?.memoryID, memoryID)
    }

    func testTagNormalizationDeduplicatesDisplayVariants() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let first = try Tag.lookupOrCreate(displayName: "Beach", in: context)
        let second = try Tag.lookupOrCreate(displayName: " beach ", in: context)
        XCTAssertTrue(first === second)
        XCTAssertEqual(first.displayName, "Beach")
        XCTAssertEqual(first.normalizedName, "beach")
    }

    func testFavoriteIDsArePerPersonAndDoNotCollide() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let item = MediaItem(id: "shared-media")
        let me = Favorite(mediaID: item.id, accountID: "local-me", isFavorite: true, mediaItem: item)
        let partner = Favorite(mediaID: item.id, accountID: "partner-account", isFavorite: false, mediaItem: item)
        context.insert(item)
        context.insert(me)
        context.insert(partner)
        try context.save()
        XCTAssertEqual(me.id, "shared-media:local-me")
        XCTAssertEqual(partner.id, "shared-media:partner-account")
        XCTAssertNotEqual(me.id, partner.id)
        XCTAssertTrue(item.isFavorite)
    }

    func testDemoOnlyV1StoreIsReplaced() throws {
        let storeURL = temporaryStoreURL("legacy-demo")
        defer { removeStore(at: storeURL) }
        do {
            let legacy = try MomentsPersistence.makeV1Container(url: storeURL)
            let context = legacy.mainContext
            context.insert(SchemaV1.MediaItem(id: "legacy-demo", source: .demo))
            try context.save()
        }
        let container = try MomentsPersistence.makeContainer(url: storeURL)
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<MediaItem>()).isEmpty)
        let sampleData = try Data(contentsOf: repositoryRoot().appendingPathComponent("demo/sample-data.json"))
        try DemoSeeder.seedIfNeeded(context: container.mainContext, data: sampleData)
        XCTAssertFalse(try container.mainContext.fetch(FetchDescriptor<MediaItem>()).isEmpty)
    }

    /// Guards against the v1 probe misreading a current store: a v2 store that
    /// holds only demo items must survive relaunches instead of being wiped.
    func testDemoOnlyV2StoreIsNotWipedOnRelaunch() throws {
        let storeURL = temporaryStoreURL("current-demo")
        defer { removeStore(at: storeURL) }
        do {
            let container = try MomentsPersistence.makeContainer(url: storeURL)
            let context = container.mainContext
            let item = MediaItem(id: "current-demo", source: .demo)
            context.insert(item)
            context.insert(Memory(text: "Written after the schema change", mediaItem: item))
            try context.save()
        }
        for _ in 0..<2 {
            let reopened = try MomentsPersistence.makeContainer(url: storeURL)
            XCTAssertEqual(try reopened.mainContext.fetch(FetchDescriptor<Memory>()).first?.text, "Written after the schema change")
        }
    }

    func testNonDemoV1StoreIsUntouchedAndRejected() throws {
        let storeURL = temporaryStoreURL("legacy-real")
        defer { removeStore(at: storeURL) }
        do {
            let legacy = try MomentsPersistence.makeV1Container(url: storeURL)
            let context = legacy.mainContext
            context.insert(SchemaV1.MediaItem(id: "legacy-real", source: .file))
            try context.save()
        }
        // The v1 container is released on its own schedule and may still checkpoint
        // into `storeURL` later. Fold its WAL into the main file, then probe a private
        // copy that no other connection can touch, so any change is the probe's fault.
        Self.checkpoint(storeURL)
        let probeURL = temporaryStoreURL("legacy-real-copy")
        defer { removeStore(at: probeURL) }
        try FileManager.default.createDirectory(at: probeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: storeURL, to: probeURL)
        let before = try Data(contentsOf: probeURL)
        let beforeDate = try FileManager.default.attributesOfItem(atPath: probeURL.path)[.modificationDate] as? Date
        XCTAssertThrowsError(try MomentsPersistence.makeContainer(url: probeURL)) { error in
            XCTAssertEqual(error as? MomentsStoreError, MomentsStoreError.protectedLegacyStore)
        }
        XCTAssertEqual(try Data(contentsOf: probeURL), before)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: probeURL.path)[.modificationDate] as? Date, beforeDate)
        XCTAssertFalse(FileManager.default.fileExists(atPath: probeURL.path + "-wal"))
    }

    private static func checkpoint(_ url: URL) {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return }
        sqlite3_exec(database, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
        sqlite3_close(database)
    }

    private func repositoryRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url
    }

    private func temporaryStoreURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("moments-\(name)-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Moments.store")
    }

    private func removeStore(at url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(atPath: url.path + "-shm")
        try? FileManager.default.removeItem(atPath: url.path + "-wal")
    }
}
