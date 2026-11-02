import Foundation
import QuartzCore
import SwiftData

/// Builds the Timeline and Chapters pages ahead of time, while the app is
/// quiet, so the first visit takes the page's existing cached path instead of
/// waiting for a full build.
///
/// One page at a time, app-wide. A pre-build stores its result only under the
/// key it was built for, and only while that key is still the current one. A
/// page that opens while its pre-build runs joins it; a page that opens for
/// another key cancels it and builds itself.
@MainActor
final class PagePrebuilder {
    static let shared = PagePrebuilder()

    enum Page: Equatable {
        case timeline
        case chapters
    }

    /// A pre-build running now: the page, its key and the task producing it.
    private enum Running {
        case timeline(id: Int, key: Int, task: Task<TimelineBuildResult?, Never>)
        case chapters(id: Int, key: Int, task: Task<ChaptersBuildResult?, Never>)

        /// Distinguishes two runs of the same page, so the late finish of an
        /// older run never clears a newer one.
        var id: Int {
            switch self {
            case let .timeline(id, _, _): return id
            case let .chapters(id, _, _): return id
            }
        }
    }

    /// How many builds this pre-builder started. A second run with nothing
    /// changed starts none; the tests check exactly that.
    private(set) var buildsStarted = 0

    private var running: Running?
    private var nextRunID = 0
    /// Moves on every `cancel()`. A pre-build that was preparing its inputs
    /// (slicing photos, before its task exists) sees the move and stops
    /// instead of starting a second build beside the page's own.
    private var cancelCount = 0
    /// The `prebuild` call whose task is alive, so the cancellation of an
    /// older `.task(id:)` never stops a newer pre-build.
    private var activePrebuild: Int?
    private var nextPrebuildToken = 0

    // MARK: Both pages

    /// Builds the Timeline, then Chapters, one at a time. Returns when both
    /// are cached, when the library moved during a sliced read (a later quiet
    /// window retries), or when the task is cancelled.
    func prebuild(
        context: ModelContext,
        store: LibraryStore,
        selection: SelectionModel,
        stacks: PhotoStackModel
    ) async {
        cancel()
        let token: Int = nextPrebuildToken
        nextPrebuildToken &+= 1
        activePrebuild = token
        await withTaskCancellationHandler {
            guard await prebuildTimeline(context: context, store: store, selection: selection, stacks: stacks) else { return }
            guard !Task.isCancelled else { return }
            _ = await prebuildChapters(context: context, store: store)
        } onCancel: {
            // The trigger's `.task` is cancelled when an input moves: stop the
            // build it started, so it never keeps working into a window the
            // person is using.
            Task { @MainActor in PagePrebuilder.shared.cancel(prebuildToken: token) }
        }
        if activePrebuild == token { activePrebuild = nil }
    }

    /// Stops the pre-build started by `token`, and nothing else: a newer
    /// quiet window's pre-build is left alone.
    private func cancel(prebuildToken: Int) {
        guard activePrebuild == prebuildToken else { return }
        activePrebuild = nil
        cancel()
    }

    /// Cancels the running pre-build; a cancelled pre-build stores nothing.
    func cancel() {
        cancelCount &+= 1
        guard let running else { return }
        switch running {
        case let .timeline(_, _, task):
            task.cancel()
        case let .chapters(_, _, task):
            task.cancel()
        }
        self.running = nil
    }

    // MARK: Joining from a page

    /// The running pre-build for this page and key, awaited; nil when nothing
    /// runs for this page, when it runs for another key (which is cancelled),
    /// or when it was cancelled or dropped as stale.
    func joinTimeline(key: Int) async -> TimelineBuildResult? {
        guard case let .timeline(id, runningKey, task) = running else { return nil }
        guard runningKey == key else {
            cancel()
            return nil
        }
        tally("prebuild timeline joined")
        let result: TimelineBuildResult? = await task.value
        clearRunning(id)
        return result
    }

    /// The Chapters counterpart of `joinTimeline(key:)`.
    func joinChapters(key: Int) async -> ChaptersBuildResult? {
        guard case let .chapters(id, runningKey, task) = running else { return nil }
        guard runningKey == key else {
            cancel()
            return nil
        }
        tally("prebuild chapters joined")
        let result: ChaptersBuildResult? = await task.value
        clearRunning(id)
        return result
    }

    // MARK: Timeline

    /// Returns false when the pre-build must stop: the library moved during
    /// the sliced read, the build was cancelled, or its result was stale.
    private func prebuildTimeline(
        context: ModelContext,
        store: LibraryStore,
        selection: SelectionModel,
        stacks: PhotoStackModel
    ) async -> Bool {
        // Taken before anything is read: a change during the read must not
        // end up under this key.
        let revisionBefore: Int = store.photoPlaceRevision
        let rows: TimelineRows = Self.timelineRows(context: context)
        let key: Int = TimelineScreen.buildKey(
            store: store,
            selection: selection,
            memories: rows.memories,
            trips: rows.trips,
            stacks: stacks,
            stackRecords: rows.stackRecords,
            calendar: Calendar.autoupdatingCurrent
        )
        // The rows the key was taken from must still be the library's rows.
        guard store.photoPlaceRevision == revisionBefore, !Task.isCancelled else { return false }
        if TimelineScreen.cachedBuild(key: key) != nil {
            tally("prebuild timeline skipped (cached)")
            return true
        }
        let cancelsAtStart: Int = cancelCount
        guard let inputs: TimelineBuildInputs = await TimelineScreen.buildInputsSliced(
            key: key,
            store: store,
            selection: selection,
            memories: rows.memories,
            calendar: Calendar.autoupdatingCurrent
        ) else {
            // The library moved under the read; no photo is touched further.
            return false
        }
        // A page opened and called `cancel()` while the photos were sliced:
        // it builds itself now, so this one must not start beside it.
        guard cancelsAtStart == cancelCount, !Task.isCancelled else { return false }
        let id: Int = startRun()
        let task: Task<TimelineBuildResult?, Never> = Task { @MainActor () -> TimelineBuildResult? in
            let startedAt: CFTimeInterval = CACurrentMediaTime()
            let built: TimelineBuildResult = await TimelineScreen.build(inputs, priority: .utility)
            // A cancelled pre-build stores nothing.
            guard !Task.isCancelled else { return nil }
            // The key must still be the current one, read from freshly
            // fetched rows, or the result is dropped: an old build never
            // overwrites a newer page build.
            guard Self.timelineKey(context: context, store: store, selection: selection, stacks: stacks) == key else {
                tally("prebuild timeline dropped (stale)")
                return nil
            }
            TimelineScreen.storeBuild(built, key: key)
            tally("prebuild timeline built", seconds: CACurrentMediaTime() - startedAt)
            return built
        }
        running = .timeline(id: id, key: key, task: task)
        let result: TimelineBuildResult? = await task.value
        clearRunning(id)
        return result != nil
    }

    // MARK: Chapters

    private func prebuildChapters(context: ModelContext, store: LibraryStore) async -> Bool {
        // Taken before anything is read: a change during the read must not
        // end up under this key.
        let revisionBefore: Int = store.photoPlaceRevision
        let rows: ChaptersRows = Self.chaptersRows(context: context)
        let key: Int = TripsScreen.buildKey(
            store: store,
            memories: rows.memories,
            trips: rows.trips,
            chapterGroups: rows.chapterGroups,
            groupItems: rows.groupItems,
            calendar: Calendar.autoupdatingCurrent
        )
        // The rows the key was taken from must still be the library's rows.
        guard store.photoPlaceRevision == revisionBefore, !Task.isCancelled else { return false }
        if TripsScreen.cachedBuild(key: key) != nil {
            tally("prebuild chapters skipped (cached)")
            return true
        }
        let cancelsAtStart: Int = cancelCount
        guard let inputs: ChaptersBuildInputs = await TripsScreen.buildInputsSliced(
            key: key,
            store: store,
            trips: rows.trips,
            chapterGroups: rows.chapterGroups,
            groupItems: rows.groupItems,
            memories: rows.memories,
            calendar: Calendar.autoupdatingCurrent
        ) else {
            return false
        }
        guard cancelsAtStart == cancelCount, !Task.isCancelled else { return false }
        let id: Int = startRun()
        let task: Task<ChaptersBuildResult?, Never> = Task { @MainActor () -> ChaptersBuildResult? in
            let startedAt: CFTimeInterval = CACurrentMediaTime()
            let built: ChaptersBuildResult = await TripsScreen.build(inputs, priority: .utility)
            guard !Task.isCancelled else { return nil }
            guard Self.chaptersKey(context: context, store: store) == key else {
                tally("prebuild chapters dropped (stale)")
                return nil
            }
            TripsScreen.storeBuild(built, key: key)
            tally("prebuild chapters built", seconds: CACurrentMediaTime() - startedAt)
            return built
        }
        running = .chapters(id: id, key: key, task: task)
        let result: ChaptersBuildResult? = await task.value
        clearRunning(id)
        return result != nil
    }

    // MARK: Rows and keys

    private struct TimelineRows {
        let trips: [Trip]
        let memories: [Memory]
        let stackRecords: [UserGroup]
    }

    private struct ChaptersRows {
        let trips: [Trip]
        let chapterGroups: [UserGroup]
        let groupItems: [UserGroupItem]
        let memories: [Memory]
    }

    /// Every memory, oldest `updatedAt` first, as the pages' `@Query`s hold
    /// them. The key sums each row's own hash, so the order is not part of
    /// it, but the fetch matches the page for the build's memory lines.
    private static func memories(context: ModelContext) -> [Memory] {
        let fetched: [Memory] = (try? context.fetch(FetchDescriptor<Memory>())) ?? []
        return fetched.sorted { (first: Memory, second: Memory) -> Bool in
            first.updatedAt < second.updatedAt
        }
    }

    private static func stackRecords(context: ModelContext) -> [UserGroup] {
        (try? context.fetch(
            FetchDescriptor<UserGroup>(predicate: #Predicate<UserGroup> { $0.kindRaw == "stack" })
        )) ?? []
    }

    private static func chapterGroups(context: ModelContext) -> [UserGroup] {
        (try? context.fetch(
            FetchDescriptor<UserGroup>(predicate: #Predicate<UserGroup> { $0.kindRaw == "chapter" })
        )) ?? []
    }

    private static func groupItems(context: ModelContext) -> [UserGroupItem] {
        (try? context.fetch(FetchDescriptor<UserGroupItem>())) ?? []
    }

    private static func trips(context: ModelContext) -> [Trip] {
        (try? context.fetch(FetchDescriptor<Trip>())) ?? []
    }

    /// The rows the Timeline's `@Query`s hold, fetched from this context with
    /// the same filters, so the key is the one the page computes.
    private static func timelineRows(context: ModelContext) -> TimelineRows {
        TimelineRows(
            trips: trips(context: context),
            memories: memories(context: context),
            stackRecords: stackRecords(context: context)
        )
    }

    private static func chaptersRows(context: ModelContext) -> ChaptersRows {
        ChaptersRows(
            trips: trips(context: context),
            chapterGroups: chapterGroups(context: context),
            groupItems: groupItems(context: context),
            memories: memories(context: context)
        )
    }

    /// The Timeline key recomputed from freshly fetched rows.
    private static func timelineKey(
        context: ModelContext,
        store: LibraryStore,
        selection: SelectionModel,
        stacks: PhotoStackModel
    ) -> Int {
        let rows: TimelineRows = timelineRows(context: context)
        return TimelineScreen.buildKey(
            store: store,
            selection: selection,
            memories: rows.memories,
            trips: rows.trips,
            stacks: stacks,
            stackRecords: rows.stackRecords,
            calendar: Calendar.autoupdatingCurrent
        )
    }

    /// The Chapters key recomputed from freshly fetched rows.
    private static func chaptersKey(context: ModelContext, store: LibraryStore) -> Int {
        let rows: ChaptersRows = chaptersRows(context: context)
        return TripsScreen.buildKey(
            store: store,
            memories: rows.memories,
            trips: rows.trips,
            chapterGroups: rows.chapterGroups,
            groupItems: rows.groupItems,
            calendar: Calendar.autoupdatingCurrent
        )
    }

    // MARK: Run bookkeeping

    /// Starts one run and returns its id, so a late finish cannot clear a
    /// newer run of the same page.
    private func startRun() -> Int {
        let id: Int = nextRunID
        nextRunID &+= 1
        buildsStarted &+= 1
        return id
    }

    private func clearRunning(_ id: Int) {
        guard let running, running.id == id else { return }
        self.running = nil
    }

    private func tally(_ name: String, seconds: Double = 0) {
        #if DEBUG
        PageProbe.tally(name, seconds: seconds)
        #endif
    }
}

/// What the app-level pre-build listens to. A change to any value restarts
/// the quiet window, and a running pre-build is replaced.
struct PagePrebuildTrigger: Hashable {
    let photoPlaceRevision: Int
    let visibleGeneration: Int
    let stackGeneration: Int
    let isImporting: Bool
    let isImportingPhotos: Bool
    let isAnalyzingStacks: Bool

    /// True while an import or the stack analysis runs: no pre-build then.
    var isBusy: Bool {
        isImporting || isImportingPhotos || isAnalyzingStacks
    }
}

/// The rule both sliced input reads follow between photo slices: the library
/// and, where the page has them, the Library filters must not have moved, and
/// the task must not be cancelled. A read that fails it returns nil and
/// touches no further photo.
enum PagePrebuildSliceRule {
    /// Photos per slice: small enough that one slice of a 20 000-photo
    /// library stays well under a frame.
    static let sliceSize = 500

    static func readIsCurrent(
        startedAtPhotoPlaceRevision: Int,
        photoPlaceRevision: Int,
        startedAtVisibleGeneration: Int?,
        visibleGeneration: Int?,
        isCancelled: Bool
    ) -> Bool {
        guard !isCancelled else { return false }
        guard startedAtPhotoPlaceRevision == photoPlaceRevision else { return false }
        guard startedAtVisibleGeneration == visibleGeneration else { return false }
        return true
    }
}
