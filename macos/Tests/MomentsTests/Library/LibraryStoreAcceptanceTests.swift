import Foundation
import SwiftData
import XCTest
@testable import Moments

/// Behaviour the pages rely on, beyond the cases in the task: which edits
/// bump `revision`, which do not, and that the lists stay in step.
@MainActor
final class LibraryStoreAcceptanceTests: XCTestCase {
    private func photo(_ id: String, day: Double) -> MediaItem {
        let item = MediaItem(id: id, title: "Synthetic \(id)")
        let seconds: TimeInterval = 1_700_000_000 + day * 86_400
        item.captureDate = Date(timeIntervalSince1970: seconds)
        return item
    }

    private func started(_ insert: (ModelContext) -> Void) throws -> (LibraryStore, ModelContext, ModelContainer) {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        insert(context)
        try context.save()
        let store = LibraryStore()
        store.start(context: context)
        return (store, context, container)
    }

    func testItemsAreSortedByCaptureDate() throws {
        let (store, _, container) = try started { context in
            context.insert(photo("c", day: 3))
            context.insert(photo("a", day: 1))
            context.insert(photo("b", day: 2))
        }
        defer { withExtendedLifetime(container) {} }
        XCTAssertEqual(store.items.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(store.regularItems.map(\.id), ["a", "b", "c"])
    }

    func testTrashMovesAPhotoBetweenListsAndBumpsRevision() throws {
        let (store, context, container) = try started { context in
            context.insert(photo("a", day: 1))
            context.insert(photo("b", day: 2))
        }
        defer { withExtendedLifetime(container) {} }
        let before = store.revision
        store.itemsByID["a"]?.deletedAt = .now
        try context.save()
        store.refreshNow()
        XCTAssertEqual(store.items.map(\.id), ["b"])
        XCTAssertEqual(store.deletedItems.map(\.id), ["a"])
        XCTAssertNil(store.itemsByID["a"])
        XCTAssertGreaterThan(store.revision, before)
    }

    func testScreenshotFlagMovesBetweenLists() throws {
        let (store, context, container) = try started { context in
            context.insert(photo("a", day: 1))
            context.insert(photo("b", day: 2))
        }
        defer { withExtendedLifetime(container) {} }
        let before = store.revision
        store.itemsByID["b"]?.isScreenshot = true
        try context.save()
        store.refreshNow()
        XCTAssertEqual(store.regularItems.map(\.id), ["a"])
        XCTAssertEqual(store.screenshotItems.map(\.id), ["b"])
        XCTAssertGreaterThan(store.revision, before)
    }

    func testAssigningAFaceBumpsRevision() throws {
        let (store, context, container) = try started { context in
            context.insert(photo("a", day: 1))
            // Typed first: the CI compiler is slow on tuple literals inside long calls.
            let rect: (x: Double, y: Double, w: Double, h: Double) = (x: 0.1, y: 0.1, w: 0.2, h: 0.2)
            let face = FaceObservation(id: "f", mediaID: "a", rect: rect, embedding: Data(), cropData: Data([1]), quality: 0.8, clusterID: "pending-f")
            context.insert(face)
        }
        defer { withExtendedLifetime(container) {} }
        XCTAssertEqual(store.faces.count, 1)
        let before = store.revision
        store.faces.first?.personID = "person-1"
        try context.save()
        store.refreshNow()
        XCTAssertGreaterThan(store.revision, before)
    }

    func testRenamingAPlaceBumpsRevision() throws {
        let (store, context, container) = try started { context in
            let place = Place(id: "city-1", name: "Synthetic Town", kind: .city)
            context.insert(place)
            let item = photo("a", day: 1)
            item.place = place
            context.insert(item)
        }
        defer { withExtendedLifetime(container) {} }
        XCTAssertEqual(store.places.map(\.id), ["city-1"])
        let before = store.revision
        store.places.first?.name = "Synthetic City"
        try context.save()
        store.refreshNow()
        XCTAssertGreaterThan(store.revision, before)
    }

    func testFavoriteBumpsRevision() throws {
        let (store, context, container) = try started { context in
            context.insert(photo("a", day: 1))
        }
        defer { withExtendedLifetime(container) {} }
        let before = store.revision
        store.itemsByID["a"]?.setFavorite(true, context: context)
        try context.save()
        store.refreshNow()
        XCTAssertGreaterThan(store.revision, before)
    }

    func testASaveOfSomethingElseKeepsRevision() throws {
        let (store, context, container) = try started { context in
            context.insert(photo("a", day: 1))
        }
        defer { withExtendedLifetime(container) {} }
        let before = store.revision
        context.insert(Tag(displayName: "Synthetic tag"))
        try context.save()
        store.refreshNow()
        XCTAssertEqual(store.revision, before)
    }

    /// Every context in the process posts `didSave`, and each test builds
    /// its own container. A save to another container names rows this store
    /// cannot read, so it must not reach the store at all.
    func testASaveToAnotherContainerIsIgnored() async throws {
        let (store, _, container) = try started { context in
            context.insert(photo("a", day: 1))
        }
        defer { withExtendedLifetime(container) {} }
        let other = try MomentsPersistence.makeContainer(inMemory: true)
        defer { withExtendedLifetime(other) {} }
        let refreshes: Int = store.refreshCount
        let revision: Int = store.revision
        let background = ModelContext(other)
        background.insert(photo("b", day: 2))
        try background.save()
        other.mainContext.insert(photo("c", day: 3))
        try other.mainContext.save()
        try await Task.sleep(for: .milliseconds(800))
        let ids: [String] = store.items.map(\.id)
        XCTAssertEqual(ids, ["a"])
        XCTAssertEqual(store.refreshCount, refreshes, "another container's save fetches nothing")
        XCTAssertEqual(store.revision, revision)
    }

    func testStartingTwiceObservesOnce() async throws {
        let (store, context, container) = try started { context in
            context.insert(photo("a", day: 1))
        }
        defer { withExtendedLifetime(container) {} }
        let before = store.refreshCount
        store.start(context: context)
        XCTAssertEqual(store.refreshCount, before, "a second start fetches nothing")
        context.insert(photo("b", day: 2))
        try context.save()
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(store.refreshCount - before, 1, "one save, one refresh")
    }
}
