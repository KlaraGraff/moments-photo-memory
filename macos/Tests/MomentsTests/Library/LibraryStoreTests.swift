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
        XCTAssertEqual(store.fullFetchCount, 1)
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
        let fullFetches = store.fullFetchCount

        let other = ModelContext(try XCTUnwrap(container))
        other.insert(MediaItem(id: "new-1", captureDate: base.addingTimeInterval(10)))
        other.insert(MediaItem(id: "new-2", captureDate: base.addingTimeInterval(20)))
        try other.save()

        let arrived = await waitUntil(timeout: 3) { store.items.count == 5 }
        XCTAssertTrue(arrived, "the store never saw the import; items count is \(store.items.count)")
        XCTAssertEqual(store.refreshCount - refreshes, 1, "one applied batch, not a full fetch")
        // A full fetch would also reach five items, so count the fetches apart.
        XCTAssertEqual(store.fullFetchCount, fullFetches, "the batch must not fetch the whole library")
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

        // A synthetic place and a child place, so place-wide and per-photo
        // overrides have something to name during the walk.
        let place = Place(id: "place-1", name: "Synthetic Place One")
        let child = Place(id: "place-2", name: "Synthetic Place Two", parent: place)
        context.insert(place)
        context.insert(child)

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
            item.place = index % 3 == 0 ? place : child
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

        /// Every live photo in a context.
        func livePhotos(in context: ModelContext) -> [MediaItem] {
            let descriptor = FetchDescriptor<MediaItem>()
            let all: [MediaItem] = (try? context.fetch(descriptor)) ?? []
            return all.filter { $0.deletedAt == nil }
        }

        for step in 0..<200 {
            let useMain = generator.nextInt(bound: 2) == 0
            let target = useMain ? context : second
            switch generator.nextInt(bound: 11) {
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
                if let item = livePhotos(in: target).first {
                    item.deletedAt = base.addingTimeInterval(500 + Double(step))
                    trashed.append(item.id)
                }
            case 2:
                if let id = trashed.popLast() {
                    let descriptor = FetchDescriptor<MediaItem>(predicate: #Predicate<MediaItem> { $0.id == id })
                    let found: [MediaItem] = (try? target.fetch(descriptor)) ?? []
                    found.first?.deletedAt = nil
                }
            case 3:
                if let item = livePhotos(in: target).first {
                    item.isScreenshot.toggle()
                }
            case 4:
                if let item = livePhotos(in: target).first {
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
            case 6:
                let descriptor = FetchDescriptor<FaceObservation>()
                let faces: [FaceObservation] = (try? target.fetch(descriptor)) ?? []
                if let face = faces.first(where: { $0.personID == nil }) {
                    face.personID = "person-\(step % 3)"
                } else if let face = faces.first {
                    target.delete(face)
                }
            case 7:
                // Star or unstar through the photo's own API, so the same
                // save also lists a Favorite row.
                if let item = livePhotos(in: target).first {
                    item.setFavorite(!item.isFavorite, context: target)
                }
            case 8:
                // A place-wide rename: `Place.correctedName` changes.
                let descriptor = FetchDescriptor<Place>()
                let places: [Place] = (try? target.fetch(descriptor)) ?? []
                if let named = places.first(where: { $0.id == "place-1" }) {
                    let rename = "Synthetic Place Rename \(step)"
                    if let existing = named.localNameOverride {
                        existing.nameOverride = rename
                        existing.updatedAt = base.addingTimeInterval(Double(step) * 30)
                    } else {
                        let override = PlaceOverride(placeID: named.id, nameOverride: rename, place: named)
                        target.insert(override)
                    }
                }
            case 9:
                // A photo's own place name, on that photo only.
                if let item = livePhotos(in: target).first {
                    let rename = "Synthetic Photo Rename \(step)"
                    if let existing = item.localPlaceOverride {
                        existing.nameOverride = rename
                    } else {
                        let override = PlaceOverride(mediaID: item.id, nameOverride: rename, mediaItem: item)
                        target.insert(override)
                    }
                }
            default:
                // A hard delete: the row is gone, not trashed.
                let photos = livePhotos(in: target)
                if photos.count > 20, let doomed = photos.last {
                    target.delete(doomed)
                }
            }
            // A save that throws must fail the test: a silent failure would
            // leave changes the store never saw.
            XCTAssertNoThrow(try target.save(), "save at step \(step) failed")
            if step % 5 == 0 { await Task.yield() }
        }

        // Let applying settle: at most 10 s, but done once 600 ms pass with
        // no applied batch.
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

        // The main context hands back the very objects the store holds, so
        // values are compared against a new context that reads them fresh.
        let reference = ModelContext(container)

        let referenceDescriptor = FetchDescriptor<MediaItem>()
        let referencePhotos: [MediaItem] = (try? reference.fetch(referenceDescriptor)) ?? []
        var expectedByID: [String: MediaItem] = [:]
        for photo in referencePhotos { expectedByID[photo.id] = photo }
        var storedByID: [String: MediaItem] = [:]
        for photo in store.items + store.deletedItems { storedByID[photo.id] = photo }
        XCTAssertEqual(Set(storedByID.keys), Set(expectedByID.keys), "photo ids differ")
        for (id, expected) in expectedByID {
            guard let actual = storedByID[id] else { continue }
            XCTAssertEqual(actual.captureDate, expected.captureDate, "captureDate of \(id)")
            XCTAssertEqual(actual.deletedAt, expected.deletedAt, "deletedAt of \(id)")
            XCTAssertEqual(actual.isScreenshot, expected.isScreenshot, "isScreenshot of \(id)")
            XCTAssertEqual(actual.updatedAt, expected.updatedAt, "updatedAt of \(id)")
        }

        let facesDescriptor = FetchDescriptor<FaceObservation>()
        let referenceFaces: [FaceObservation] = (try? reference.fetch(facesDescriptor)) ?? []
        var personByFaceID: [String: String?] = [:]
        for face in referenceFaces { personByFaceID[face.id] = face.personID }
        XCTAssertEqual(Set(store.faces.map(\.id)), Set(personByFaceID.keys), "face ids differ")
        for face in store.faces {
            XCTAssertEqual(face.personID, personByFaceID[face.id], "personID of \(face.id)")
        }

        let placesDescriptor = FetchDescriptor<Place>()
        let referencePlaces: [Place] = (try? reference.fetch(placesDescriptor)) ?? []
        var nameByPlaceID: [String: String?] = [:]
        for place in referencePlaces { nameByPlaceID[place.id] = PlaceDisplayName.resolvedName(of: place) }
        XCTAssertEqual(Set(store.places.map(\.id)), Set(nameByPlaceID.keys), "place ids differ")
        for place in store.places {
            let expectedName = nameByPlaceID[place.id] ?? nil
            XCTAssertEqual(PlaceDisplayName.resolvedName(of: place), expectedName, "display name of \(place.id)")
        }

        // The signature must match as well. `revision` itself cannot be
        // compared across two stores: each counts its own bumps.
        XCTAssertEqual(store.measures, fresh.measures, "the walked store and a fresh fetch disagree")
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

    // 8
    func testTwoPhotosWithTheSameStringIDBothStay() async throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        self.container = container
        let context = container.mainContext
        let first = MediaItem(id: "same", captureDate: base.addingTimeInterval(1), title: "First")
        let second = MediaItem(id: "same", captureDate: base.addingTimeInterval(2), title: "Second")
        context.insert(first)
        context.insert(second)
        try context.save()

        let store = makeStore(context: context)
        XCTAssertEqual(store.items.count, 2, "two rows, even with one string id")

        // Another context edits both rows in one save.
        let other = ModelContext(container)
        let descriptor = FetchDescriptor<MediaItem>()
        let photos: [MediaItem] = try other.fetch(descriptor)
        XCTAssertEqual(photos.count, 2)
        for photo in photos {
            photo.title = "Edited " + photo.title
        }
        try other.save()

        let appliedBoth = await waitUntil(timeout: 3) {
            store.items.count == 2 && store.items.allSatisfy { $0.title.hasPrefix("Edited") }
        }
        XCTAssertTrue(appliedBoth, "the store did not apply both edits")
        XCTAssertEqual(store.items.count, 2, "both rows must stay")
        let titles = Set(store.items.map(\.title))
        XCTAssertEqual(titles, ["Edited First", "Edited Second"])
    }

    // 9
    func testFavoriteSavedForAPhotoHardDeletedInTheSameBatch() async throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        self.container = container
        let context = container.mainContext
        context.insert(MediaItem(id: "doomed", captureDate: base))
        try context.save()

        let store = makeStore(context: context)
        let refreshes = store.refreshCount
        XCTAssertEqual(store.items.count, 1)

        // One save: a favorite for the photo, then the photo itself deleted.
        let other = ModelContext(container)
        let descriptor = FetchDescriptor<MediaItem>()
        let remote = try XCTUnwrap(try other.fetch(descriptor).first)
        remote.setFavorite(true, context: other)
        other.delete(remote)
        try other.save()

        let applied = await waitUntil(timeout: 3) { store.refreshCount > refreshes }
        XCTAssertTrue(applied, "the store never applied the batch")
        XCTAssertTrue(store.items.isEmpty, "the deleted photo came back")
        XCTAssertTrue(store.deletedItems.isEmpty, "the deleted photo came back")
        XCTAssertNil(store.itemsByID["doomed"])
    }

    // 10
    func testFiftyFaceInsertAppliesWithoutAFullFetch() async throws {
        let context = try makeContext()
        for index in 0..<2_000 {
            let crop = Data([UInt8(index % 250)])
            let cluster = "pending-\(index % 40)"
            context.insert(FaceObservation(
                id: "face-\(index)",
                mediaID: "photo-\(index)",
                rect: Self.faceRect,
                embedding: Data(),
                cropData: crop,
                quality: 0.8,
                clusterID: cluster
            ))
        }
        try context.save()
        let store = makeStore(context: context)
        XCTAssertEqual(store.faces.count, 2_000)
        let fullFetches: Int = store.fullFetchCount

        // A person's context saves 50 new faces; the store applies that batch
        // on the next main-actor turn, without fetching all 2,000 again.
        for index in 2_000..<2_050 {
            context.insert(FaceObservation(
                id: "face-\(index)",
                mediaID: "photo-\(index)",
                rect: Self.otherFaceRect,
                embedding: Data(),
                cropData: Data([3]),
                quality: 0.7,
                clusterID: "pending-new"
            ))
        }
        // Timed from the save: the save and the applied batch, not the inserts.
        let start = Date()
        try context.save()

        var arrived = false
        for _ in 0..<4_000 {
            await Task.yield()
            if store.faces.count == 2_050 {
                arrived = true
                break
            }
        }
        let elapsed: TimeInterval = Date().timeIntervalSince(start)
        XCTAssertTrue(arrived, "the store never saw the 50 faces")
        XCTAssertEqual(store.fullFetchCount, fullFetches, "50 new faces must not fetch the whole library")
        // The GitHub Mac measured 51 ms for the save plus the applied batch
        // (Debug, 2026-11-01); the bound is twice that.
        XCTAssertLessThan(elapsed, 0.1, "one applied batch of 50 faces took \(elapsed * 1_000) ms")
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
