import Foundation
import SwiftData
import XCTest
@testable import Moments

@MainActor
final class LibraryStoreTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    /// The store is `@MainActor` and nothing else here needs a run loop.
    private func makeStore(context: ModelContext) -> LibraryStore {
        let store = LibraryStore()
        store.start(context: context)
        return store
    }

    /// Kept for the length of a test, so its main context stays valid.
    private var container: ModelContainer?

    /// `makeContainer` in memory, like the other store tests: never on disk.
    private func makeContext() throws -> ModelContext {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        self.container = container
        return container.mainContext
    }

    // MARK: 1

    func testStartFetchesLiveDeletedAndScreenshots() throws {
        let context = try makeContext()
        let live = [
            MediaItem(id: "a", captureDate: base.addingTimeInterval(1), title: "A"),
            MediaItem(id: "b", captureDate: base.addingTimeInterval(2), title: "B"),
            MediaItem(id: "c", captureDate: base.addingTimeInterval(3), title: "C")
        ]
        let screenshot = MediaItem(id: "shot", captureDate: base.addingTimeInterval(4), isScreenshot: true)
        for item in live + [screenshot] { context.insert(item) }
        let deleted = MediaItem(id: "gone", captureDate: base)
        context.insert(deleted)
        deleted.deletedAt = base.addingTimeInterval(10)
        try context.save()

        let store = makeStore(context: context)

        XCTAssertEqual(store.items.count, 4)
        XCTAssertEqual(store.regularItems.count, 3)
        XCTAssertEqual(store.screenshotItems.count, 1)
        XCTAssertEqual(store.deletedItems.count, 1)
        XCTAssertEqual(store.itemsByID.count, 4)
        XCTAssertEqual(store.revision, 1)
        XCTAssertEqual(Set(store.screenshotItems.map(\.id)), ["shot"])
        XCTAssertEqual(Set(store.itemsByID.keys), ["a", "b", "c", "shot"])
        XCTAssertEqual(store.deletedItems.first?.id, "gone")
        XCTAssertEqual(store.refreshCount, 1)
    }

    // MARK: 2

    func testRevisionChangesOnlyWhenSomethingPagesUseChanges() throws {
        let context = try makeContext()
        let item = MediaItem(id: "a", captureDate: base, latitude: 35.0, longitude: 139.0, title: "Old title")
        context.insert(item)
        try context.save()

        let store = makeStore(context: context)
        let start = store.revision
        XCTAssertEqual(start, 1)

        // A refresh with nothing changed keeps the revision.
        store.refreshNow()
        XCTAssertEqual(store.revision, start)
        XCTAssertEqual(store.refreshCount, 2)

        // A place on the map is something the pages group by.
        item.latitude = 35.5
        try context.save()
        store.refreshNow()
        XCTAssertEqual(store.revision, start + 1)

        // A title is not: the key for a rebuild only covers position in time
        // and place, so a rename must not make every page regroup. `updatedAt`
        // is in the signature, though, so it is left alone here.
        item.title = "New title"
        try context.save()
        store.refreshNow()
        XCTAssertEqual(store.revision, start + 1)
        XCTAssertEqual(store.items.first?.title, "New title")
    }

    // MARK: 3

    func testSavesFromAnotherContextReachTheStore() async throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let store = makeStore(context: container.mainContext)
        let before = store.items.count

        let other = ModelContext(container)
        other.insert(MediaItem(id: "imported-1", captureDate: base.addingTimeInterval(100)))
        other.insert(MediaItem(id: "imported-2", captureDate: base.addingTimeInterval(200)))
        try other.save()

        let arrived = await waitUntil(timeout: 3) { store.items.count == 2 + before }
        XCTAssertTrue(arrived, "the store never saw the import; items count is \(store.items.count)")
        XCTAssertEqual(Set(store.items.map(\.id)), ["imported-1", "imported-2"])
        XCTAssertEqual(store.revision, 2)
    }

    // MARK: 4

    func testManySavesBecomeFewRefreshes() async throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let store = makeStore(context: context)
        let before = store.refreshCount

        // An import writes twenty times in a row, with no pause to settle.
        for index in 0..<20 {
            context.insert(MediaItem(id: "burst-\(index)", captureDate: base.addingTimeInterval(Double(index))))
            try context.save()
        }

        // One settle delay is 250 ms; a whole second is far more than enough.
        try await Task.sleep(for: .seconds(1))

        XCTAssertLessThanOrEqual(store.refreshCount - before, 3)
        XCTAssertEqual(store.items.count, 20)
        XCTAssertEqual(Set(store.items.map(\.id)).count, 20)
    }

    // MARK: - Helpers

    /// Polls every 50 ms, like the app's settle timer would.
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }
}
