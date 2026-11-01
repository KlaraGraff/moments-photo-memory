import Foundation
import SwiftData
import XCTest
@testable import Moments

/// `LibraryFilterEngine.regroupPasses` must return exactly what the Library
/// called one after another before: `filteredItems` twice and
/// `publishedItems` once. These tests compare against those three calls.
@MainActor
final class LibraryRegroupPassesTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private let day: TimeInterval = 86_400

    /// Kept for the length of a test, so its main context stays valid.
    private var container: ModelContainer?

    private func makeContext() throws -> ModelContext {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        self.container = container
        return container.mainContext
    }

    private struct Fixture {
        let all: [MediaItem]
        let regular: [MediaItem]
        let screenshots: [MediaItem]
    }

    /// 40 synthetic photos: screenshots, favorites, photos and videos, spread
    /// over a month, a few with a memory.
    private func makeFixture(context: ModelContext) -> Fixture {
        var all: [MediaItem] = []
        var regular: [MediaItem] = []
        var screenshots: [MediaItem] = []
        all.reserveCapacity(40)
        regular.reserveCapacity(34)
        screenshots.reserveCapacity(6)
        for index in 0..<40 {
            let id: String = "photo-\(index)"
            let isScreenshot: Bool = index % 7 == 0
            let kind: MediaKind = index % 5 == 0 ? .video : .photo
            let offset: TimeInterval = Double(index) * day * 0.75
            let date: Date = base.addingTimeInterval(offset)
            let item = MediaItem(id: id, captureDate: date, kind: kind, isScreenshot: isScreenshot)
            context.insert(item)
            all.append(item)
            if isScreenshot {
                screenshots.append(item)
            } else {
                regular.append(item)
            }
        }
        for index in stride(from: 0, to: 40, by: 3) {
            let item: MediaItem = all[index]
            item.setFavorite(true, context: context)
        }
        // Some favorites have a memory too, so a favorites-and-memory filter
        // is not empty.
        let rememberedIndices: [Int] = [1, 9, 12, 19, 28, 37]
        for index in rememberedIndices {
            let item: MediaItem = all[index]
            let memory = Memory(text: "Synthetic memory \(index)", mediaItem: item)
            context.insert(memory)
        }
        return Fixture(all: all, regular: regular, screenshots: screenshots)
    }

    /// The three calls `regroup` made before, in the same order, compared with
    /// `regroupPasses` on the same input.
    private func assertMatchesOldCalls(
        scopedItems: [MediaItem],
        allItems: [MediaItem],
        hasScope: Bool,
        criteria: LibraryFilterCriteria,
        editingItemID: String?,
        personIDsByMediaID: [String: Set<String>] = [:],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let passes: LibraryFilterEngine.RegroupPasses = LibraryFilterEngine.regroupPasses(
            scopedItems: scopedItems,
            allItems: allItems,
            hasScope: hasScope,
            criteria: criteria,
            editingItemID: editingItemID,
            personIDsByMediaID: personIDsByMediaID
        )
        let oldFiltered: [MediaItem] = LibraryFilterEngine.filteredItems(
            scopedItems,
            by: criteria,
            personIDsByMediaID: personIDsByMediaID
        )
        let oldVisible: [MediaItem] = LibraryFilterEngine.filteredItems(
            scopedItems,
            by: criteria,
            preservingEditingItemID: editingItemID,
            personIDsByMediaID: personIDsByMediaID
        )
        let oldPublished: Set<String> = Set(
            LibraryFilterEngine.publishedItems(
                allItems,
                by: criteria,
                personIDsByMediaID: personIDsByMediaID
            ).map(\.id)
        )
        let filteredIDs: [String] = passes.filtered.map(\.id)
        let expectedFilteredIDs: [String] = oldFiltered.map(\.id)
        let visibleIDs: [String] = passes.visible.map(\.id)
        let expectedVisibleIDs: [String] = oldVisible.map(\.id)
        XCTAssertEqual(filteredIDs, expectedFilteredIDs, "filtered differs", file: file, line: line)
        XCTAssertEqual(visibleIDs, expectedVisibleIDs, "visible differs", file: file, line: line)
        XCTAssertEqual(passes.publishedIDs, oldPublished, "publishedIDs differ", file: file, line: line)
    }

    // MARK: 1 No filter

    func testNoFilterMatchesTheOldCalls() throws {
        let context = try makeContext()
        let fixture: Fixture = makeFixture(context: context)
        try context.save()
        assertMatchesOldCalls(
            scopedItems: fixture.regular,
            allItems: fixture.all,
            hasScope: false,
            criteria: .default,
            editingItemID: nil
        )
    }

    // MARK: 2 Favorites only

    func testFavoritesOnlyMatchesTheOldCalls() throws {
        let context = try makeContext()
        let fixture: Fixture = makeFixture(context: context)
        try context.save()
        let criteria = LibraryFilterCriteria(mediaType: .favorite)
        XCTAssertTrue(criteria.favoritesOnly)
        assertMatchesOldCalls(
            scopedItems: fixture.regular,
            allItems: fixture.all,
            hasScope: false,
            criteria: criteria,
            editingItemID: nil
        )
    }

    // MARK: 3 Screenshots segment

    func testScreenshotsSegmentMatchesTheOldCalls() throws {
        let context = try makeContext()
        let fixture: Fixture = makeFixture(context: context)
        try context.save()
        let criteria = LibraryFilterCriteria(mediaType: .screenshot)
        assertMatchesOldCalls(
            scopedItems: fixture.screenshots,
            allItems: fixture.all,
            hasScope: false,
            criteria: criteria,
            editingItemID: nil
        )
    }

    // MARK: 4 A scope from another screen

    func testScopeMatchesTheOldCalls() throws {
        let context = try makeContext()
        let fixture: Fixture = makeFixture(context: context)
        try context.save()
        let scopedItems: [MediaItem] = Array(fixture.regular.prefix(10))
        assertMatchesOldCalls(
            scopedItems: scopedItems,
            allItems: fixture.all,
            hasScope: true,
            criteria: .default,
            editingItemID: nil
        )
    }

    // MARK: 5 Memory filter with a photo being edited

    func testHasMemoryKeepsTheEditingPhotoWithoutAMemory() throws {
        let context = try makeContext()
        let fixture: Fixture = makeFixture(context: context)
        try context.save()
        var criteria = LibraryFilterCriteria()
        criteria.favoritesOnly = true
        criteria.memoryFilter = .hasMemory
        // "photo-3" is a favorite without a memory, so the memory filter drops
        // it and the old code added it back last.
        let editingItemID: String = "photo-3"
        assertMatchesOldCalls(
            scopedItems: fixture.regular,
            allItems: fixture.all,
            hasScope: false,
            criteria: criteria,
            editingItemID: editingItemID
        )

        let passes: LibraryFilterEngine.RegroupPasses = LibraryFilterEngine.regroupPasses(
            scopedItems: fixture.regular,
            allItems: fixture.all,
            hasScope: false,
            criteria: criteria,
            editingItemID: editingItemID,
            personIDsByMediaID: [:]
        )
        let filteredIDs: [String] = passes.filtered.map(\.id)
        let visibleIDs: [String] = passes.visible.map(\.id)
        XCTAssertFalse(filteredIDs.contains(editingItemID))
        XCTAssertTrue(visibleIDs.contains(editingItemID))

        // "photo-9" is a favorite with a memory, so the memory filter keeps
        // it: visible is filtered, with no second pass and no duplicate.
        let keptPasses: LibraryFilterEngine.RegroupPasses = LibraryFilterEngine.regroupPasses(
            scopedItems: fixture.regular,
            allItems: fixture.all,
            hasScope: false,
            criteria: criteria,
            editingItemID: "photo-9",
            personIDsByMediaID: [:]
        )
        let keptVisibleIDs: [String] = keptPasses.visible.map(\.id)
        let keptFilteredIDs: [String] = keptPasses.filtered.map(\.id)
        XCTAssertEqual(keptVisibleIDs, keptFilteredIDs)
    }

    // MARK: 6 Memory filter without a photo being edited

    func testHasMemoryWithoutEditingPhotoMatchesTheOldCalls() throws {
        let context = try makeContext()
        let fixture: Fixture = makeFixture(context: context)
        try context.save()
        let criteria = LibraryFilterCriteria(memoryFilter: .hasMemory)
        assertMatchesOldCalls(
            scopedItems: fixture.regular,
            allItems: fixture.all,
            hasScope: false,
            criteria: criteria,
            editingItemID: nil
        )
    }
}
