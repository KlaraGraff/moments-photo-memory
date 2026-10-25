import Foundation
import SwiftData
import XCTest
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
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("moments-place-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let container = try MomentsPersistence.makeContainer(url: storeURL)
        let context = container.mainContext
        let place = Place(id: "original-place", name: "Original place", latitude: 0.001, longitude: 0.002)
        let item = MediaItem(id: "override-demo", latitude: 0.003, longitude: 0.004, place: place)
        context.insert(place)
        context.insert(item)
        item.placeOverrideName = "Edited place"
        item.placeOverrideMapLink = "https://maps.example.invalid/edited"
        item.placeOverrideLatitude = 0.005
        item.placeOverrideLongitude = 0.006
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
        let first = MediaItem(id: "first", captureDate: Date(timeIntervalSince1970: 1_700_000_000), kind: .photo, isFavorite: true, tripKey: "trip-a", place: place)
        let second = MediaItem(id: "second", captureDate: Date(timeIntervalSince1970: 1_700_100_000), kind: .video, isFavorite: false, tripKey: "trip-b", place: place)
        context.insert(place)
        [first, second].forEach(context.insert)

        var criteria = LibraryFilterCriteria.default
        criteria.placeID = place.id
        criteria.mediaType = .photo
        criteria.favoritesOnly = true
        criteria.tripKey = "trip-a"
        criteria.fromDate = Date(timeIntervalSince1970: 1_699_999_000)
        criteria.toDate = Date(timeIntervalSince1970: 1_700_010_000)
        XCTAssertEqual(LibraryFilterEngine.filteredItems([first, second], by: criteria).map(\.id), ["first"])

        first.placeOverrideName = "Edited filter place"
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
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("moments-model-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: storeURL) }
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
            XCTAssertEqual(memories.first?.text, "Persisted across a reopen")
            XCTAssertEqual(memories.first?.author, .me)
            XCTAssertEqual(memories.first?.mediaItem?.id, "reopen-demo")
        }
    }

    private func repositoryRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url
    }
}
