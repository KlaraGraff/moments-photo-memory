import Foundation
import SwiftData
import XCTest
@testable import Moments

/// The app-level pre-builder fills the pages' build caches ahead of time, so a
/// first visit takes the "last build reused" path. These tests use an
/// in-memory store and synthetic photos only.
@MainActor
final class PagePrebuildTests: XCTestCase {
    private let base: Date = Date(timeIntervalSince1970: 1_700_000_000)

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

    private func makeStacks() -> PhotoStackModel {
        PhotoStackModel(analysis: PhotoStackAnalysisStore(fileURL: nil))
    }

    /// One synthetic trip with `count` photos, each with one memory, and one
    /// synthetic chapter with its first two photos as members.
    @discardableResult
    private func makeLibrary(
        context: ModelContext,
        prefix: String,
        count: Int
    ) throws -> Trip {
        let trip: Trip = Trip(id: "trip-" + prefix, name: "Synthetic " + prefix)
        context.insert(trip)
        for index in 0..<count {
            let photo: MediaItem = MediaItem(
                id: prefix + "-photo-\(index)",
                captureDate: base.addingTimeInterval(Double(index) * 86_400),
                latitude: 0.001,
                longitude: 0.002,
                title: "Synthetic " + prefix + " \(index)"
            )
            context.insert(photo)
            photo.trip = trip
            let memory: Memory = Memory(
                id: prefix + "-memory-\(index)",
                text: "Synthetic memory " + prefix + " \(index)",
                createdAt: base.addingTimeInterval(Double(index)),
                updatedAt: base.addingTimeInterval(Double(index)),
                mediaItem: photo
            )
            context.insert(memory)
        }
        let group: UserGroup = UserGroup(id: "group-" + prefix, name: "Synthetic event " + prefix, kind: .chapter)
        context.insert(group)
        for index in 0..<min(2, count) {
            let member: UserGroupItem = UserGroupItem(
                id: prefix + "-member-\(index)",
                groupID: group.id,
                mediaID: prefix + "-photo-\(index)"
            )
            context.insert(member)
        }
        try context.save()
        return trip
    }

    /// The same rows in another `ModelContext`, as the page's `@Query`s hold
    /// them: the pre-builder's key must not depend on the order they come in.
    private func reversedRows(
        from context: ModelContext,
        store: LibraryStore,
        selection: SelectionModel,
        stacks: PhotoStackModel
    ) throws -> Int {
        let other: ModelContext = ModelContext(try XCTUnwrap(container))
        let trips: [Trip] = try other.fetch(FetchDescriptor<Trip>())
        let memories: [Memory] = try other.fetch(FetchDescriptor<Memory>())
        let stackRecords: [UserGroup] = try other.fetch(
            FetchDescriptor<UserGroup>(predicate: #Predicate<UserGroup> { $0.kindRaw == "stack" })
        )
        return TimelineScreen.buildKey(
            store: store,
            selection: selection,
            memories: Array(memories.reversed()),
            trips: Array(trips.reversed()),
            stacks: stacks,
            stackRecords: stackRecords,
            calendar: Calendar.autoupdatingCurrent
        )
    }

    /// The Chapters key, from the same reversed rows in another context.
    private func reversedChaptersKey(
        from context: ModelContext,
        store: LibraryStore
    ) throws -> Int {
        let other: ModelContext = ModelContext(try XCTUnwrap(container))
        let trips: [Trip] = try other.fetch(FetchDescriptor<Trip>())
        let memories: [Memory] = try other.fetch(FetchDescriptor<Memory>())
        let chapterGroups: [UserGroup] = try other.fetch(
            FetchDescriptor<UserGroup>(predicate: #Predicate<UserGroup> { $0.kindRaw == "chapter" })
        )
        let groupItems: [UserGroupItem] = try other.fetch(FetchDescriptor<UserGroupItem>())
        return TripsScreen.buildKey(
            store: store,
            memories: Array(memories.reversed()),
            trips: Array(trips.reversed()),
            chapterGroups: Array(chapterGroups.reversed()),
            groupItems: Array(groupItems.reversed()),
            calendar: Calendar.autoupdatingCurrent
        )
    }

    /// One quiet pre-build fills both pages' caches, under the key each page
    /// computes for itself.
    func testPrebuildFillsBothPageCaches() async throws {
        let context: ModelContext = try makeContext()
        try makeLibrary(context: context, prefix: "first", count: 3)
        let store: LibraryStore = makeStore(context: context)
        let selection: SelectionModel = SelectionModel()
        let stacks: PhotoStackModel = makeStacks()
        let buildsBefore: Int = PagePrebuilder.shared.buildsStarted

        await PagePrebuilder.shared.prebuild(
            context: context,
            store: store,
            selection: selection,
            stacks: stacks
        )

        let timelineKey: Int = try reversedRows(from: context, store: store, selection: selection, stacks: stacks)
        let chaptersKey: Int = try reversedChaptersKey(from: context, store: store)

        let timelineBuild: TimelineBuildResult? = TimelineScreen.cachedBuild(key: timelineKey)
        let chaptersBuild: ChaptersBuildResult? = TripsScreen.cachedBuild(key: chaptersKey)
        XCTAssertNotNil(timelineBuild, "the pre-build must fill the Timeline cache")
        XCTAssertNotNil(chaptersBuild, "the pre-build must fill the Chapters cache")
        XCTAssertEqual(
            PagePrebuilder.shared.buildsStarted,
            buildsBefore + 2,
            "one quiet window starts exactly two builds: Timeline, then Chapters"
        )
        XCTAssertEqual(timelineBuild?.viewerOrder.count, 3)
        let chapterItems: Int = (chaptersBuild?.document.trips ?? []).reduce(into: 0) { (total: inout Int, trip: TimelineTrip) in
            total += trip.itemCount
        }
        XCTAssertEqual(chapterItems, 3)
    }

    /// With the caches warm, another quiet window builds nothing and leaves
    /// exactly the same results in place.
    func testSecondPrebuildStartsNoNewBuild() async throws {
        let context: ModelContext = try makeContext()
        try makeLibrary(context: context, prefix: "second", count: 4)
        let store: LibraryStore = makeStore(context: context)
        let selection: SelectionModel = SelectionModel()
        let stacks: PhotoStackModel = makeStacks()

        await PagePrebuilder.shared.prebuild(
            context: context,
            store: store,
            selection: selection,
            stacks: stacks
        )
        let timelineKey: Int = try reversedRows(from: context, store: store, selection: selection, stacks: stacks)
        let chaptersKey: Int = try reversedChaptersKey(from: context, store: store)
        let firstTimeline: TimelineBuildResult? = TimelineScreen.cachedBuild(key: timelineKey)
        let firstChapters: ChaptersBuildResult? = TripsScreen.cachedBuild(key: chaptersKey)
        let firstMonths: [String] = (firstTimeline?.months ?? []).map { (month: TimelineMonth) -> String in month.id }
        let firstOrder: [String] = firstTimeline?.viewerOrder ?? []
        let firstChapterDocs: [String: TimelineTrip] = firstChapters?.chapterDocs ?? [:]
        let firstDocs: [String] = firstChapterDocs.keys.sorted()
        let buildsAfterFirst: Int = PagePrebuilder.shared.buildsStarted

        await PagePrebuilder.shared.prebuild(
            context: context,
            store: store,
            selection: selection,
            stacks: stacks
        )

        let secondTimeline: TimelineBuildResult? = TimelineScreen.cachedBuild(key: timelineKey)
        let secondChapters: ChaptersBuildResult? = TripsScreen.cachedBuild(key: chaptersKey)
        let secondMonths: [String] = (secondTimeline?.months ?? []).map { (month: TimelineMonth) -> String in month.id }
        let secondOrder: [String] = secondTimeline?.viewerOrder ?? []
        let secondChapterDocs: [String: TimelineTrip] = secondChapters?.chapterDocs ?? [:]
        let secondDocs: [String] = secondChapterDocs.keys.sorted()
        XCTAssertEqual(PagePrebuilder.shared.buildsStarted, buildsAfterFirst, "a warm cache starts no build")
        XCTAssertEqual(secondMonths, firstMonths)
        XCTAssertEqual(secondOrder, firstOrder)
        XCTAssertEqual(secondDocs, firstDocs)
        XCTAssertFalse(firstMonths.isEmpty, "the first pre-build built real months")
        XCTAssertFalse(firstDocs.isEmpty, "the first pre-build built the chapter")
    }

    /// The sliced read takes every photo, in slices, exactly as the page's own
    /// `buildInputs` would: more photos than one slice, and all of them there.
    func testSlicedTimelineInputsTakeEveryPhoto() async throws {
        let context: ModelContext = try makeContext()
        try makeLibrary(context: context, prefix: "sliced", count: 520)
        let store: LibraryStore = makeStore(context: context)
        let selection: SelectionModel = SelectionModel()
        let memories: [Memory] = try context.fetch(FetchDescriptor<Memory>())

        let inputs: TimelineBuildInputs? = await TimelineScreen.buildInputsSliced(
            key: 1,
            store: store,
            selection: selection,
            memories: memories,
            calendar: Calendar.autoupdatingCurrent
        )

        XCTAssertEqual(inputs?.sourceItems.count, 520)
        XCTAssertEqual(inputs?.sourceItems.first?.id, "sliced-photo-0")
        XCTAssertEqual(inputs?.sourceItems.last?.id, "sliced-photo-519")
        XCTAssertEqual(inputs?.key, 1)
    }

    /// The Chapters sliced read does the same, over more than one slice.
    func testSlicedChaptersInputsTakeEveryPhoto() async throws {
        let context: ModelContext = try makeContext()
        try makeLibrary(context: context, prefix: "chapters", count: 510)
        let store: LibraryStore = makeStore(context: context)
        let trips: [Trip] = try context.fetch(FetchDescriptor<Trip>())
        let groups: [UserGroup] = try context.fetch(
            FetchDescriptor<UserGroup>(predicate: #Predicate<UserGroup> { $0.kindRaw == "chapter" })
        )
        let members: [UserGroupItem] = try context.fetch(FetchDescriptor<UserGroupItem>())
        let memories: [Memory] = try context.fetch(FetchDescriptor<Memory>())

        let inputs: ChaptersBuildInputs? = await TripsScreen.buildInputsSliced(
            key: 2,
            store: store,
            trips: trips,
            chapterGroups: groups,
            groupItems: members,
            memories: memories,
            calendar: Calendar.autoupdatingCurrent
        )

        XCTAssertEqual(inputs?.sourceItems.count, 510)
        XCTAssertEqual(inputs?.sourceTrips.count, 1)
        XCTAssertEqual(inputs?.chapterSources.count, 1)
        XCTAssertEqual(inputs?.key, 2)
    }

    /// A cancelled read stops at its first slice check and returns nothing, so
    /// no photo is touched after the work was called off.
    func testSlicedInputsReturnNilWhenCancelled() async throws {
        let context: ModelContext = try makeContext()
        try makeLibrary(context: context, prefix: "cancelled", count: 600)
        let store: LibraryStore = makeStore(context: context)
        let selection: SelectionModel = SelectionModel()
        let memories: [Memory] = try context.fetch(FetchDescriptor<Memory>())

        let task: Task<TimelineBuildInputs?, Never> = Task { @MainActor () -> TimelineBuildInputs? in
            await TimelineScreen.buildInputsSliced(
                key: 3,
                store: store,
                selection: selection,
                memories: memories,
                calendar: Calendar.autoupdatingCurrent
            )
        }
        task.cancel()
        let inputs: TimelineBuildInputs? = await task.value

        XCTAssertNil(inputs, "a cancelled read must not hand inputs to a build")
    }

    /// The gate both sliced reads use: a moved photo-and-place revision, a
    /// moved Library filter generation, or cancellation all stop the read; an
    /// unchanged library lets it go on.
    func testSliceRuleStopsWhenTheLibraryMoved() {
        XCTAssertTrue(PagePrebuildSliceRule.readIsCurrent(
            startedAtPhotoPlaceRevision: 7,
            photoPlaceRevision: 7,
            startedAtVisibleGeneration: 3,
            visibleGeneration: 3,
            isCancelled: false
        ))
        XCTAssertFalse(PagePrebuildSliceRule.readIsCurrent(
            startedAtPhotoPlaceRevision: 7,
            photoPlaceRevision: 8,
            startedAtVisibleGeneration: 3,
            visibleGeneration: 3,
            isCancelled: false
        ), "a photo or place added between slices must stop the read")
        XCTAssertFalse(PagePrebuildSliceRule.readIsCurrent(
            startedAtPhotoPlaceRevision: 7,
            photoPlaceRevision: 7,
            startedAtVisibleGeneration: 3,
            visibleGeneration: 4,
            isCancelled: false
        ), "moved Library filters must stop the read")
        XCTAssertFalse(PagePrebuildSliceRule.readIsCurrent(
            startedAtPhotoPlaceRevision: 7,
            photoPlaceRevision: 7,
            startedAtVisibleGeneration: nil,
            visibleGeneration: nil,
            isCancelled: true
        ), "a cancelled read must stop")
        XCTAssertTrue(PagePrebuildSliceRule.readIsCurrent(
            startedAtPhotoPlaceRevision: 7,
            photoPlaceRevision: 7,
            startedAtVisibleGeneration: nil,
            visibleGeneration: nil,
            isCancelled: false
        ))
        XCTAssertEqual(PagePrebuildSliceRule.sliceSize, 500)
    }

    /// A page that opens for another key cancels the running pre-build and
    /// builds itself; the join returns nothing in that case.
    func testJoinForAnotherKeyCancelsAndReturnsNil() async throws {
        let context: ModelContext = try makeContext()
        try makeLibrary(context: context, prefix: "join", count: 4)
        let store: LibraryStore = makeStore(context: context)
        let selection: SelectionModel = SelectionModel()
        let stacks: PhotoStackModel = makeStacks()

        let idleTimeline: TimelineBuildResult? = await PagePrebuilder.shared.joinTimeline(key: 1_234_567)
        let idleChapters: ChaptersBuildResult? = await PagePrebuilder.shared.joinChapters(key: 1_234_567)
        XCTAssertNil(idleTimeline, "nothing runs: no join")
        XCTAssertNil(idleChapters)
        await PagePrebuilder.shared.prebuild(
            context: context,
            store: store,
            selection: selection,
            stacks: stacks
        )
        let finishedTimeline: TimelineBuildResult? = await PagePrebuilder.shared.joinTimeline(key: 7_654_321)
        XCTAssertNil(finishedTimeline, "a finished pre-build is not running")
        PagePrebuilder.shared.cancel()
    }
}
