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
        // Held by the test case, so the container outlives every await below.
        self.container = container
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
        self.container = container
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

    // MARK: - Saved changes and incremental application

    // 1
    func testChangesAreReadFromTheSaveNotification() throws {
        let unknown = LibraryStore.changes(in: nil)
        XCTAssertFalse(unknown.isKnown)
        XCTAssertTrue(unknown.isEmpty)

        let context = try makeContext()
        let photo = MediaItem(id: "notified", captureDate: base)
        context.insert(photo)
        try context.save()

        let changes = LibraryStore.changes(in: ["inserted": [photo.persistentModelID]])
        XCTAssertTrue(changes.isKnown)
        XCTAssertEqual(changes.inserted.count, 1)
        XCTAssertEqual(changes.updated.count, 0)
        XCTAssertEqual(changes.deleted.count, 0)
        XCTAssertEqual(changes.inserted.first?.entityName, String(describing: MediaItem.self))
    }

    // 2
    func testBackgroundInsertArrivesWithoutAFullFetch() async throws {
        let context = try makeContext()
        for index in 0..<3 {
            context.insert(MediaItem(id: "old-\(index)", captureDate: base.addingTimeInterval(Double(index))))
        }
        try context.save()
        let store = makeStore(context: context)
        let before = store.items
        XCTAssertEqual(before.count, 3)
        let refreshes = store.refreshCount

        let other = ModelContext(try XCTUnwrap(container))
        other.insert(MediaItem(id: "new-1", captureDate: base.addingTimeInterval(10)))
        other.insert(MediaItem(id: "new-2", captureDate: base.addingTimeInterval(20)))
        try other.save()

        let arrived = await waitUntil(timeout: 3) { store.items.count == 5 }
        XCTAssertTrue(arrived, "the store never saw the import; items count is \(store.items.count)")
        XCTAssertEqual(store.refreshCount - refreshes, 1, "one applied batch, not a full fetch")
        // The three photos already known are the same objects, so their cells
        // keep their state.
        let after = Dictionary(uniqueKeysWithValues: store.items.map { ($0.id, $0) })
        for photo in before {
            XCTAssertTrue(after[photo.id] === photo, "photo \(photo.id) was replaced")
        }
    }

    // 3
    func testUnrelatedSaveChangesNothing() async throws {
        let context = try makeContext()
        context.insert(MediaItem(id: "a", captureDate: base))
        try context.save()
        let store = makeStore(context: context)
        let refreshes = store.refreshCount
        let revision = store.revision
        let items = store.items

        context.insert(Tag(displayName: "Synthetic unrelated tag"))
        try context.save()

        await Task.yield()
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(store.refreshCount, refreshes)
        XCTAssertEqual(store.revision, revision)
        XCTAssertEqual(store.items.count, items.count)
        XCTAssertTrue(store.items.elementsEqual(items, by: { $0 === $1 }))
    }

    // 4
    func testMainContextEditAppliesAtOnce() async throws {
        let context = try makeContext()
        let first = MediaItem(id: "a", captureDate: base.addingTimeInterval(1))
        let second = MediaItem(id: "b", captureDate: base.addingTimeInterval(2))
        context.insert(first)
        context.insert(second)
        try context.save()
        let store = makeStore(context: context)
        let revision = store.revision

        first.deletedAt = base.addingTimeInterval(100)
        try context.save()

        var applied = false
        for _ in 0..<20 {
            await Task.yield()
            if store.items.count == 1 && store.deletedItems.count == 1 {
                applied = true
                break
            }
        }
        XCTAssertTrue(applied, "a person's edit should not wait for the settle delay")
        XCTAssertEqual(store.items.map(\.id), ["b"])
        XCTAssertEqual(store.deletedItems.map(\.id), ["a"])
        XCTAssertGreaterThan(store.revision, revision)
    }

    // 5
    func testFaceAssignmentFromAnotherContext() async throws {
        let context = try makeContext()
        context.insert(MediaItem(id: "photo", captureDate: base))
        context.insert(FaceObservation(
            id: "face-1",
            mediaID: "photo",
            rect: Self.faceRect,
            embedding: Data(),
            cropData: Data([1]),
            quality: 0.8,
            clusterID: "pending-f"
        ))
        try context.save()
        let store = makeStore(context: context)
        let revision = store.revision
        XCTAssertEqual(store.faces.first?.personID, nil)

        let other = ModelContext(try XCTUnwrap(container))
        let faces = try other.fetch(FetchDescriptor<FaceObservation>())
        let face = try XCTUnwrap(faces.first { $0.id == "face-1" })
        face.personID = "person-1"
        try other.save()

        let arrived = await waitUntil(timeout: 3) { store.revision > revision }
        XCTAssertTrue(arrived, "the store never saw the face assignment")
        XCTAssertEqual(store.faces.first?.personID, "person-1")
    }

    // 6
    func testIncrementalMatchesAFullFetch() async throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        self.container = container
        let context = container.mainContext

        for index in 0..<50 {
            let step = Double(index)
            let seconds: TimeInterval = step * 3600
            let latitude: Double = 35 + step / 100
            let longitude: Double = 139 + step / 100
            let item = MediaItem(
                id: "photo-\(index)",
                captureDate: base.addingTimeInterval(seconds),
                latitude: latitude,
                longitude: longitude
            )
            item.isScreenshot = index % 7 == 0
            context.insert(item)
        }
        for index in 0..<30 {
            context.insert(FaceObservation(
                id: "face-\(index)",
                mediaID: "photo-\(index)",
                rect: Self.faceRect,
                embedding: Data(),
                cropData: Data([UInt8(index % 250)]),
                quality: 0.8,
                clusterID: "pending-\(index)"
            ))
        }
        try context.save()

        let store = makeStore(context: context)
        let second = ModelContext(container)

        // A fixed seed keeps a failure reproducible.
        var generator = SeededGenerator(seed: 0x5EED_1234)
        // Only ids cross contexts: a model belongs to the context that read it.
        var trashed: [String] = []
        var nextPhoto = 0
        var nextFace = 0

        func save(on context: ModelContext) {
            try? context.save()
        }

        for step in 0..<200 {
            let useMain = generator.nextInt(bound: 2) == 0
            let target = useMain ? context : second
            switch generator.nextInt(bound: 7) {
            case 0:
                let item = MediaItem(
                    id: "added-\(nextPhoto)",
                    captureDate: base.addingTimeInterval(Double(step) * 60),
                    latitude: 34,
                    longitude: 138
                )
                target.insert(item)
                nextPhoto += 1
            case 1:
                if let item = try? target.fetch(FetchDescriptor<MediaItem>()).first(where: { $0.deletedAt == nil }) {
                    item.deletedAt = base.addingTimeInterval(500 + Double(step))
                    trashed.append(item.id)
                }
            case 2:
                if let id = trashed.popLast(),
                   let item = try? target.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.id == id })).first {
                    item.deletedAt = nil
                }
            case 3:
                if let item = try? target.fetch(FetchDescriptor<MediaItem>()).first {
                    item.isScreenshot.toggle()
                }
            case 4:
                if let item = try? target.fetch(FetchDescriptor<MediaItem>()).first {
                    item.captureDate = base.addingTimeInterval(Double(step) * 120)
                }
            case 5:
                let face = FaceObservation(
                    id: "face-new-\(nextFace)",
                    mediaID: "photo-0",
                    rect: Self.otherFaceRect,
                    embedding: Data(),
                    cropData: Data([7]),
                    quality: 0.5,
                    clusterID: "pending-new-\(nextFace)"
                )
                target.insert(face)
                nextFace += 1
            default:
                let faces = (try? target.fetch(FetchDescriptor<FaceObservation>())) ?? []
                if let face = faces.first(where: { $0.personID == nil }) {
                    face.personID = "person-\(step % 3)"
                } else if let face = faces.first {
                    target.delete(face)
                }
            }
            save(on: target)
            if step % 5 == 0 { await Task.yield() }
        }

        // Wait until applying has stopped for 600 ms (at most 10 s).
        var lastCount = -1
        var stableSince = Date()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if store.refreshCount != lastCount {
                lastCount = store.refreshCount
                stableSince = Date()
            } else if Date().timeIntervalSince(stableSince) >= 0.6 {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        let fresh = LibraryStore()
        fresh.start(context: context)

        XCTAssertEqual(store.items.map(\.id), fresh.items.map(\.id))
        XCTAssertEqual(store.regularItems.map(\.id), fresh.regularItems.map(\.id))
        XCTAssertEqual(store.screenshotItems.map(\.id), fresh.screenshotItems.map(\.id))
        XCTAssertEqual(store.deletedItems.map(\.id), fresh.deletedItems.map(\.id))
        XCTAssertEqual(Set(store.faces.map(\.id)), Set(fresh.faces.map(\.id)))
        XCTAssertEqual(Set(store.itemsByID.keys), Set(fresh.itemsByID.keys))
        XCTAssertEqual(store.items.count, store.regularItems.count + store.screenshotItems.count)
        XCTAssertEqual(Set(store.items.map(\.id)), Set(store.itemsByID.keys))
    }

    // 7
    func testFavoriteStillBumpsRevision() async throws {
        let context = try makeContext()
        let item = MediaItem(id: "a", captureDate: base)
        context.insert(item)
        try context.save()
        let store = makeStore(context: context)
        let revision = store.revision

        store.itemsByID["a"]?.setFavorite(true, context: context)
        try context.save()

        var bumped = false
        for _ in 0..<20 {
            await Task.yield()
            if store.revision > revision { bumped = true; break }
        }
        XCTAssertTrue(bumped, "a favorite change must still bump revision")
    }

    // MARK: - Helpers

    // Typed once: the CI compilers are slow on tuple literals inside long calls.
    private static let faceRect: (x: Double, y: Double, w: Double, h: Double) = (x: 0.1, y: 0.1, w: 0.2, h: 0.2)
    private static let otherFaceRect: (x: Double, y: Double, w: Double, h: Double) = (x: 0.2, y: 0.2, w: 0.1, h: 0.1)

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

/// A small deterministic generator for the random-walk test; `SystemRandom`
/// would make a failure impossible to reproduce.
private struct SeededGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }

    mutating func nextInt(bound: Int) -> Int {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Int(state % UInt64(bound))
    }
}
