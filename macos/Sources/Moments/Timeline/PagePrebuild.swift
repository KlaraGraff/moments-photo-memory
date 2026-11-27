import Foundation
import QuartzCore
import SwiftData
import SwiftUI

/// Builds the Chapters page ahead of time, while the app is quiet, so the
/// first visit takes the page's existing cached path instead of waiting for
/// a full build.
///
/// One build at a time, app-wide. A pre-build stores its result only under the
/// key it was built for, and only while that key is still the current one. A
/// page that opens while its pre-build runs joins it; a page that opens for
/// another key cancels it and builds itself.
@MainActor
final class PagePrebuilder {
    static let shared = PagePrebuilder()

    /// A pre-build running now: its key and the task producing it.
    private struct Running {
        /// Distinguishes two runs, so the late finish of an older run never
        /// clears a newer one.
        let id: Int
        let key: Int
        let task: Task<ChaptersBuildResult?, Never>
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

    // MARK: Pre-building

    /// Builds Chapters. Returns when it is cached, when the library moved
    /// during a sliced read (a later quiet window retries), or when the task
    /// is cancelled.
    func prebuild(context: ModelContext, store: LibraryStore) async {
        cancel()
        let token: Int = nextPrebuildToken
        nextPrebuildToken &+= 1
        activePrebuild = token
        await withTaskCancellationHandler {
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
        running.task.cancel()
        self.running = nil
    }

    // MARK: Joining from the page

    /// The running pre-build for this key, awaited; nil when nothing runs,
    /// when it runs for another key (which is cancelled), or when it was
    /// cancelled or dropped as stale.
    func joinChapters(key: Int) async -> ChaptersBuildResult? {
        guard let running else { return nil }
        guard running.key == key else {
            cancel()
            return nil
        }
        tally("prebuild chapters joined")
        let result: ChaptersBuildResult? = await running.task.value
        clearRunning(running.id)
        return result
    }

    // MARK: Chapters

    /// Returns false when the pre-build must stop: the library moved during
    /// the sliced read, the build was cancelled, or its result was stale.
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
            // The library moved under the read; no photo is touched further.
            return false
        }
        // The page opened and called `cancel()` while the photos were sliced:
        // it builds itself now, so this one must not start beside it.
        guard cancelsAtStart == cancelCount, !Task.isCancelled else { return false }
        let id: Int = startRun()
        let task: Task<ChaptersBuildResult?, Never> = Task { @MainActor () -> ChaptersBuildResult? in
            let startedAt: CFTimeInterval = CACurrentMediaTime()
            let built: ChaptersBuildResult = await TripsScreen.build(inputs, priority: .utility)
            // A cancelled pre-build stores nothing.
            guard !Task.isCancelled else { return nil }
            // The key must still be the current one, read from freshly
            // fetched rows, or the result is dropped: an old build never
            // overwrites a newer page build.
            guard Self.chaptersKey(context: context, store: store) == key else {
                tally("prebuild chapters dropped (stale)")
                return nil
            }
            TripsScreen.storeBuild(built, key: key)
            tally("prebuild chapters built", seconds: CACurrentMediaTime() - startedAt)
            return built
        }
        running = Running(id: id, key: key, task: task)
        let result: ChaptersBuildResult? = await task.value
        clearRunning(id)
        return result != nil
    }

    // MARK: Rows and keys

    private struct ChaptersRows {
        let trips: [Trip]
        let chapterGroups: [UserGroup]
        let groupItems: [UserGroupItem]
        let memories: [Memory]
    }

    /// Every memory, oldest `updatedAt` first, as the page's `@Query` holds
    /// them. The key sums each row's own hash, so the order is not part of
    /// it, but the fetch matches the page for the build's memory lines.
    private static func memories(context: ModelContext) -> [Memory] {
        let fetched: [Memory] = (try? context.fetch(FetchDescriptor<Memory>())) ?? []
        return fetched.sorted { (first: Memory, second: Memory) -> Bool in
            first.updatedAt < second.updatedAt
        }
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

    /// The rows the page's `@Query`s hold, fetched from this context with the
    /// same filters, so the key is the one the page computes.
    private static func chaptersRows(context: ModelContext) -> ChaptersRows {
        ChaptersRows(
            trips: trips(context: context),
            chapterGroups: chapterGroups(context: context),
            groupItems: groupItems(context: context),
            memories: memories(context: context)
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
    /// newer run.
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
    let isImporting: Bool
    let isImportingPhotos: Bool
    let isAnalyzingStacks: Bool

    /// True while an import or the stack analysis runs: no pre-build then.
    var isBusy: Bool {
        isImporting || isImportingPhotos || isAnalyzingStacks
    }
}

/// The rule the sliced input read follows between photo slices: the library
/// must not have moved, and the task must not be cancelled. A read that fails it returns nil and
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

/// The app-level pre-build trigger, in its own tiny view so the App body does
/// not read values that change on every import save. Only this view is
/// re-evaluated when the library or a running job moves.
struct PagePrebuildDriver: View {
    let container: ModelContainer
    let store: LibraryStore
    let importController: ImportController
    let photosImportController: PhotosImportController
    let stackAnalyzer: PhotoStackAnalyzer

    private var trigger: PagePrebuildTrigger {
        PagePrebuildTrigger(
            photoPlaceRevision: store.photoPlaceRevision,
            isImporting: importController.isRunning,
            isImportingPhotos: photosImportController.isRunning,
            isAnalyzingStacks: stackAnalyzer.isRunning
        )
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task(id: trigger) {
                guard !trigger.isBusy else { return }
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                await PagePrebuilder.shared.prebuild(context: container.mainContext, store: store)
            }
    }
}
