import Foundation
import MomentsCore
import SwiftData
import XCTest
@testable import Moments

/// The stack model gets its photos key from the store's running per-photo sum
/// when a page passes exactly the store's live photos, so a first visit does
/// not hash every photo on the main thread. These tests prove the two keys
/// agree, and that a subset never takes the shortcut.
@MainActor
final class PhotoStackKeyTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    /// Kept for the length of a test, so its main context stays valid.
    private var container: ModelContainer?

    private func makeContext() throws -> ModelContext {
        let container: ModelContainer = try MomentsPersistence.makeContainer(inMemory: true)
        self.container = container
        return container.mainContext
    }

    private func makeStore(context: ModelContext) -> LibraryStore {
        let store: LibraryStore = LibraryStore()
        store.start(context: context)
        return store
    }

    /// The model under test: no analysis file, so nothing is read from disk.
    private func makeStacks() -> PhotoStackModel {
        PhotoStackModel(analysis: PhotoStackAnalysisStore(fileURL: nil))
    }

    private func key(of items: [MediaItem]) -> Int {
        PhotoStackModel.key(of: items)
    }

    private func insertSyntheticPhotos(_ context: ModelContext) throws -> [MediaItem] {
        var items: [MediaItem] = []
        for index in 0..<6 {
            let item: MediaItem = MediaItem(
                id: "stack-key-\(index)",
                captureDate: base.addingTimeInterval(Double(index)),
                kind: .photo,
                perceptualHash: String(format: "%016llx", UInt64(index))
            )
            context.insert(item)
            items.append(item)
        }
        let video: MediaItem = MediaItem(
            id: "stack-key-video",
            captureDate: base.addingTimeInterval(1.5),
            kind: .video,
            perceptualHash: "0000000000000000"
        )
        context.insert(video)
        items.append(video)
        let screen: MediaItem = MediaItem(
            id: "stack-key-screen",
            captureDate: base.addingTimeInterval(2.5),
            kind: .photo,
            isScreenshot: true,
            perceptualHash: "0000000000000000"
        )
        context.insert(screen)
        items.append(screen)
        try context.save()
        return items
    }

    /// (a) The key the store keeps as a running sum equals the key hashed from
    /// the store's own photo list, before and after inserts, edits and deletes.
    func testStoreKeyEqualsHashedKeyForTheWholeLiveSet() throws {
        let context: ModelContext = try makeContext()
        _ = try insertSyntheticPhotos(context)
        let store: LibraryStore = makeStore(context: context)
        let stacks: PhotoStackModel = makeStacks()

        XCTAssertEqual(key(of: store.items), store.stackFieldsKey, "start: the keys must agree")

        let first: PhotoStackIndex = stacks.update(
            items: store.items,
            decisions: [],
            photosKey: store.stackFieldsKey,
            photoCount: store.items.count
        )
        XCTAssertEqual(first.stacks.count, 1, "the burst must fold on the store key")
        XCTAssertNil(first.stack(containing: "stack-key-video"))
        XCTAssertNil(first.stack(containing: "stack-key-screen"))

        // Insert: a new photo between the burst's shots.
        let inserted: MediaItem = MediaItem(
            id: "stack-key-inserted",
            captureDate: base.addingTimeInterval(3.5),
            kind: .photo,
            perceptualHash: "0000000000000003"
        )
        context.insert(inserted)
        try context.save()
        store.refreshNow()
        XCTAssertEqual(key(of: store.items), store.stackFieldsKey, "after insert: the keys must agree")

        // Edit the capture date.
        inserted.captureDate = base.addingTimeInterval(600)
        try context.save()
        store.refreshNow()
        XCTAssertEqual(key(of: store.items), store.stackFieldsKey, "after a date edit: the keys must agree")

        // Edit the perceptual hash.
        inserted.perceptualHash = "FFFFFFFFFFFFFFFF"
        try context.save()
        store.refreshNow()
        XCTAssertEqual(key(of: store.items), store.stackFieldsKey, "after a hash edit: the keys must agree")

        // Edit the screenshot flag.
        inserted.isScreenshot = true
        try context.save()
        store.refreshNow()
        XCTAssertEqual(key(of: store.items), store.stackFieldsKey, "after a screenshot edit: the keys must agree")

        // Delete: the photo moves to Recently Deleted and leaves `items`.
        inserted.deletedAt = base.addingTimeInterval(1_000)
        try context.save()
        store.refreshNow()
        XCTAssertEqual(store.deletedItems.count, 1)
        XCTAssertEqual(key(of: store.items), store.stackFieldsKey, "after a delete: the keys must agree")
        withExtendedLifetime(container) {}
    }

    /// The store's own sum also covers Recently Deleted, so the page's key has
    /// to be taken over the live photos only; a delete then moves it.
    func testStoreKeyMovesWhenAPhotoIsDeleted() throws {
        let context: ModelContext = try makeContext()
        _ = try insertSyntheticPhotos(context)
        let store: LibraryStore = makeStore(context: context)
        let before: Int = store.stackFieldsKey
        let photo: MediaItem = try XCTUnwrap(store.items.first)
        photo.deletedAt = base.addingTimeInterval(1_000)
        try context.save()
        store.refreshNow()
        XCTAssertNotEqual(store.stackFieldsKey, before, "a delete must move the stack key")
        XCTAssertEqual(key(of: store.items), store.stackFieldsKey)
        withExtendedLifetime(container) {}
    }

    /// (b) A subset is hashed, never given the full set's store key: the
    /// stack the full set produced must be gone, not kept.
    func testSubsetNeverTakesTheStoreKey() throws {
        let context: ModelContext = try makeContext()
        _ = try insertSyntheticPhotos(context)
        let store: LibraryStore = makeStore(context: context)
        let stacks: PhotoStackModel = makeStacks()

        let full: PhotoStackIndex = stacks.update(
            items: store.items,
            decisions: [],
            waits: true,
            photosKey: store.stackFieldsKey,
            photoCount: store.items.count
        )
        XCTAssertEqual(full.stacks.count, 1)

        let subset: [MediaItem] = store.items.filter { (item: MediaItem) -> Bool in
            item.id == "stack-key-video"
        }
        XCTAssertLessThan(subset.count, store.items.count)
        let afterSubset: PhotoStackIndex = stacks.update(
            items: subset,
            decisions: [],
            waits: true,
            photosKey: store.stackFieldsKey,
            photoCount: store.items.count
        )
        XCTAssertTrue(afterSubset.isEmpty, "a subset must be hashed, so the burst is gone")
        withExtendedLifetime(container) {}
    }
}
