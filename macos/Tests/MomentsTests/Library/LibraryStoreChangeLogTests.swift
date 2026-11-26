import Foundation
import SwiftData
import XCTest
@testable import Moments

/// `LibraryStore.changedPhotoIDs(sincePhotoFaceRevision:)`: which photos a
/// `photoFaceRevision` bump changed, so a page can update just those, and nil
/// whenever that is not known.
@MainActor
final class LibraryStoreChangeLogTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    /// Kept for the length of a test, so its main context stays valid.
    private var container: ModelContainer?

    private func makeStore(photoCount: Int = 5) throws -> (context: ModelContext, store: LibraryStore, photos: [MediaItem]) {
        let container: ModelContainer = try MomentsPersistence.makeContainer(inMemory: true)
        self.container = container
        let context: ModelContext = container.mainContext
        var photos: [MediaItem] = []
        for index in 0..<photoCount {
            let date: Date = base.addingTimeInterval(TimeInterval(index * 60))
            let photo: MediaItem = MediaItem(id: "photo-\(index)", captureDate: date)
            context.insert(photo)
            photos.append(photo)
        }
        try context.save()
        let store: LibraryStore = LibraryStore()
        store.start(context: context)
        return (context, store, photos)
    }

    private func saveAndWait(_ context: ModelContext, _ store: LibraryStore) async throws -> Bool {
        let refreshes: Int = store.refreshCount
        try context.save()
        return await waitUntil(timeout: 3) { () -> Bool in store.refreshCount > refreshes }
    }

    /// Polls every 50 ms, like the app's settle timer would.
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline: Date = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    func testCurrentRevisionHasNoChanges() throws {
        let setup = try makeStore()
        let store: LibraryStore = setup.store
        XCTAssertEqual(store.changedPhotoIDs(sincePhotoFaceRevision: store.photoFaceRevision), [])
    }

    func testFirstFetchIsNotDescribable() throws {
        let setup = try makeStore()
        XCTAssertNil(setup.store.changedPhotoIDs(sincePhotoFaceRevision: 0), "the first fetch is a full rebuild")
    }

    func testDateChangeNamesThatPhotoOnly() async throws {
        let setup = try makeStore()
        let store: LibraryStore = setup.store
        let start: Int = store.photoFaceRevision

        setup.photos[2].captureDate = base.addingTimeInterval(-3_600)
        setup.photos[3].localDayKey = "2023-11-13"
        let applied: Bool = try await saveAndWait(setup.context, store)
        XCTAssertTrue(applied, "the store never applied the save")

        XCTAssertGreaterThan(store.photoFaceRevision, start)
        let changed: Set<String>? = store.changedPhotoIDs(sincePhotoFaceRevision: start)
        XCTAssertEqual(changed, ["photo-2", "photo-3"])
    }

    func testChangesOverSeveralBumpsAreJoined() async throws {
        let setup = try makeStore()
        let store: LibraryStore = setup.store
        let start: Int = store.photoFaceRevision

        setup.photos[0].captureDate = base.addingTimeInterval(-10)
        let first: Bool = try await saveAndWait(setup.context, store)
        XCTAssertTrue(first)
        let middle: Int = store.photoFaceRevision
        setup.photos[4].latitude = 35.0
        setup.photos[4].longitude = 139.0
        let second: Bool = try await saveAndWait(setup.context, store)
        XCTAssertTrue(second)

        XCTAssertEqual(store.changedPhotoIDs(sincePhotoFaceRevision: start), ["photo-0", "photo-4"])
        XCTAssertEqual(store.changedPhotoIDs(sincePhotoFaceRevision: middle), ["photo-4"])
    }

    func testInsertedPhotoIsNotDescribable() async throws {
        let setup = try makeStore()
        let store: LibraryStore = setup.store
        let start: Int = store.photoFaceRevision

        setup.context.insert(MediaItem(id: "photo-new", captureDate: base))
        let applied: Bool = try await saveAndWait(setup.context, store)
        XCTAssertTrue(applied)

        XCTAssertGreaterThan(store.photoFaceRevision, start)
        XCTAssertNil(store.changedPhotoIDs(sincePhotoFaceRevision: start), "a new photo needs a full rebuild")
    }

    func testTrashedPhotoIsNotDescribable() async throws {
        let setup = try makeStore()
        let store: LibraryStore = setup.store
        let start: Int = store.photoFaceRevision

        setup.photos[1].deletedAt = base
        let applied: Bool = try await saveAndWait(setup.context, store)
        XCTAssertTrue(applied)

        XCTAssertNil(store.changedPhotoIDs(sincePhotoFaceRevision: start), "a trashed photo needs a full rebuild")
    }

    func testFullFetchIsNotDescribable() throws {
        let setup = try makeStore()
        let store: LibraryStore = setup.store
        let start: Int = store.photoFaceRevision

        setup.photos[1].captureDate = base.addingTimeInterval(-99)
        try setup.context.save()
        store.refreshNow()

        XCTAssertGreaterThan(store.photoFaceRevision, start)
        XCTAssertNil(store.changedPhotoIDs(sincePhotoFaceRevision: start), "a full fetch cannot say what changed")
    }

    func testFaceChangeIsNotDescribable() async throws {
        let setup = try makeStore()
        let store: LibraryStore = setup.store
        let start: Int = store.photoFaceRevision

        let face: FaceObservation = FaceObservation(
            id: "face-1",
            mediaID: "photo-0",
            rect: (x: 0.1, y: 0.1, w: 0.2, h: 0.2),
            embedding: Data(),
            cropData: Data([1]),
            quality: 0.8,
            clusterID: "pending-f"
        )
        setup.context.insert(face)
        let applied: Bool = try await saveAndWait(setup.context, store)
        XCTAssertTrue(applied)

        XCTAssertGreaterThan(store.photoFaceRevision, start)
        XCTAssertNil(store.changedPhotoIDs(sincePhotoFaceRevision: start), "a face change needs a full rebuild")
    }

    func testOldRevisionOutsideTheLogIsNotDescribable() async throws {
        let setup = try makeStore()
        let store: LibraryStore = setup.store
        let start: Int = store.photoFaceRevision

        for step in 0...LibraryStore.photoChangeLogLength {
            setup.photos[0].captureDate = base.addingTimeInterval(TimeInterval(-1 - step))
            let applied: Bool = try await saveAndWait(setup.context, store)
            XCTAssertTrue(applied)
        }

        XCTAssertNil(store.changedPhotoIDs(sincePhotoFaceRevision: start), "a revision that left the log is unknown")
        let recent: Int = store.photoFaceRevision - 1
        XCTAssertEqual(store.changedPhotoIDs(sincePhotoFaceRevision: recent), ["photo-0"])
    }

    func testFutureRevisionIsNotDescribable() throws {
        let setup = try makeStore()
        let store: LibraryStore = setup.store
        XCTAssertNil(store.changedPhotoIDs(sincePhotoFaceRevision: store.photoFaceRevision + 1))
    }
}
