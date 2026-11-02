import SwiftUI
import SwiftData
import MomentsCore

/// Every photo by day, newest first, trips or not: everyday moments sit
/// next to travel. Each day has its memory line and its places, the same
/// as a day inside a trip, plus a link to the trip it belongs to. Follows
/// the Library filters, like the maps.
struct TimelineScreen: View {
    @Environment(LibraryStore.self) private var store
    // The library's photos and places come from the shared store, which
    // fetches them once for every page.
    private var items: [MediaItem] { store.items }
    private var places: [Place] { store.places }
    @Query private var trips: [Trip]
    @Query(sort: \CollectionMemory.createdAt) private var memories: [CollectionMemory]
    @Query(sort: \Memory.updatedAt) private var memoryRecords: [Memory]
    @Query(filter: #Predicate<UserGroup> { $0.kindRaw == "stack" }) private var stackRecords: [UserGroup]
    @Environment(SelectionModel.self) private var selection
    @Environment(PhotoStackModel.self) private var stacks
    /// Rebuilt only when the inputs change, not on every selection change or render.
    @State private var months: [TimelineMonth] = []
    @State private var itemByID: [String: MediaItem] = [:]
    @State private var tripsByItemID: [String: TripLink] = [:]
    @State private var viewerOrder: [String] = []
    @State private var isBuilt = false
    /// Moves each time `inputKey` changes.
    @State private var wantedBuild = 0
    /// The `wantedBuild` the shown result was built for.
    @State private var shownBuild = -1
    @State private var isBuilding = false
    /// The last finished build, kept across visits to the page: SwiftUI drops
    /// the page's `@State` when it is left, but the built values stay valid
    /// as long as the inputs key below is unchanged.
    @MainActor private static var lastBuild: (key: Int, months: [TimelineMonth], viewerOrder: [String])?

    private var visibleItems: [MediaItem] {
        items.filter { selection.isVisible($0.id) }
    }

    /// What the stack model is handed, without hashing each photo: the
    /// store's per-photo sum, how many photos this page passes, and a name
    /// for this page (two pages may pass different subsets).
    private var stackSourceKey: Int {
        var hasher = Hasher()
        hasher.combine(store.stackFieldsKey)
        hasher.combine(store.items.count)
        hasher.combine("timeline")
        return hasher.finalize()
    }

    private var inputKey: Int {
        var hasher = Hasher()
        // Photos and places, but not faces: the page groups days by photos,
        // places, trips, memories and groups and never reads faces, so a
        // save that changed nothing but faces does not rebuild it.
        hasher.combine(store.photoPlaceRevision)
        hasher.combine(selection.visibleGeneration)
        for memory in memoryRecords {
            hasher.combine(memory.id)
            hasher.combine(memory.mediaID)
            hasher.combine(memory.updatedAt)
        }
        for trip in trips {
            hasher.combine(trip.id)
            hasher.combine(trip.effectiveName)
            hasher.combine(trip.items.count)
        }
        hasher.combine(stacks.generation)
        for record in stackRecords {
            hasher.combine(record.id)
            hasher.combine(record.rulesData)
        }
        return hasher.finalize()
    }

    /// The key the last finished build is stored under: the same `inputKey`
    /// that decides whether the open page rebuilds, plus the calendar the
    /// build groups by, so a different calendar never shows the old result.
    private var buildCacheKey: Int {
        var hasher = Hasher()
        hasher.combine(inputKey)
        hasher.combine(Calendar.autoupdatingCurrent.identifier)
        hasher.combine(Calendar.autoupdatingCurrent.timeZone.identifier)
        return hasher.finalize()
    }

    private var dayCount: Int { months.reduce(0) { $0 + $1.days.count } }

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView(
                    "No memories yet",
                    systemImage: "calendar.badge.plus",
                    description: Text("Add a photo or import a synthetic demo to begin.")
                )
            } else if !isBuilt {
                // Built on appear; until then show the bare page.
                Paper.canvas
            } else if !items.contains(where: { selection.isVisible($0.id) }) {
                ContentUnavailableView {
                    Label("No photos match these filters", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("Change or clear the filters to see more of your days.")
                } actions: {
                    Button("Clear filters") { LibraryFilterKeys.clearAll() }
                }
            } else if months.isEmpty {
                ContentUnavailableView(
                    "No timeline entries",
                    systemImage: "calendar",
                    description: Text("No photos match the Library filters.")
                )
            } else {
                timelineScroll
            }
        }
        // The page's name lives in the window's title bar, not in the page.
        .navigationTitle(String(localized: "Timeline"))
        .navigationSubtitle(isBuilt && dayCount > 0 ? String(localized: "\(dayCount) days") : "")
        #if DEBUG
        .onAppear {
            PageProbe.shellReady(token: PageProbe.phaseToken)
        }
        #endif
        .onChange(of: inputKey, initial: true) { _, _ in
            wantedBuild &+= 1
            startBuildingIfIdle()
        }
        .compactLibraryFilters()
    }

    private var timelineScroll: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(months) { month in
                    Section {
                        VStack(alignment: .leading, spacing: 40) {
                            ForEach(month.days) { day in
                                TripDaySection(
                                    day: day,
                                    number: nil,
                                    memories: day.memoryKey.map { key in
                                        memories.filter { $0.scope != .trip && $0.scopeKey == key }
                                    } ?? [],
                                    itemByID: itemByID,
                                    onOpen: open,
                                    trips: tripLinks(for: day),
                                    onOpenTrip: openTrip
                                )
                            }
                        }
                        .padding(.bottom, 44)
                    } header: {
                        TimelineMonthHeader(month: month)
                    }
                }
            }
            .padding(.horizontal, PaperMetrics.screenInset)
            .padding(.top, PaperMetrics.screenTopInset)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.automatic)
        .background(Paper.canvas)
    }

    /// Starts a build when none runs. At most one build runs on this page:
    /// inputs that change meanwhile only move `wantedBuild`, so when the build
    /// ends its result is shown, and then exactly one more build starts for
    /// the newest inputs. A newer input therefore never abandons a running
    /// build, and dozens of superseded builds never run at once.
    private func startBuildingIfIdle() {
        guard !isBuilding else { return }
        isBuilding = true
        Task { @MainActor in
            while shownBuild != wantedBuild {
                #if DEBUG
                let probeToken = PageProbe.phaseToken
                #endif
                let target: Int = wantedBuild
                #if DEBUG
                let rebuildStarted = CACurrentMediaTime()
                #endif
                await rebuild()
                #if DEBUG
                PageProbe.tally("timeline rebuild", seconds: CACurrentMediaTime() - rebuildStarted)
                #endif
                shownBuild = target
                #if DEBUG
                PageProbe.contentReady(token: probeToken)
                #endif
            }
            #if DEBUG
            PageProbe.tally("timeline builds in one go", seconds: 0)
            #endif
            isBuilding = false
        }
    }

    /// Builds the page off the main thread and assigns it. Only one build runs
    /// at a time, so no older result can arrive late and overwrite a newer one.
    private func rebuild() async {
        // Taken before anything is read: these are the inputs this build uses,
        // and a change during the build must not be stored under a newer key.
        let cacheKey = buildCacheKey
        if let cached = Self.lastBuild, cached.key == cacheKey {
            // Nothing changed since the last finished build: show it at once,
            // without the snapshots, place hints or builder.
            months = cached.months
            viewerOrder = cached.viewerOrder
            stacks.update(items: items, decisions: stackRecords, sourceKey: stackSourceKey)
            itemByID = store.itemsByID
            var cachedLinksByItemID: [String: TripLink] = [:]
            for trip in trips {
                let link = TripLink(id: trip.id, name: trip.effectiveName)
                for item in trip.items { cachedLinksByItemID[item.id] = link }
            }
            tripsByItemID = cachedLinksByItemID
            isBuilt = true
            #if DEBUG
            PageProbe.tally("timeline last build reused", seconds: 0)
            #endif
            return
        }
        // Everything read from SwiftData stays on the main actor; the build
        // below sees plain values only.
        #if DEBUG
        var stepStarted: CFTimeInterval = CACurrentMediaTime()
        let step: (String) -> Void = { (name: String) -> Void in
            PageProbe.tally("timeline step: " + name, seconds: CACurrentMediaTime() - stepStarted)
            stepStarted = CACurrentMediaTime()
        }
        #endif
        let placeIndex = NearestPlaceIndex(places: places)
        #if DEBUG
        step("place index")
        #endif
        let memoriesByPhotoID = Self.memoriesByPhotoID(memoryRecords)
        #if DEBUG
        step("memories by photo")
        #endif
        let sourceItems = visibleItems.map { item in
            TimelineItemSnapshot(item: item, placeHint: nil, memories: memoriesByPhotoID[item.persistentModelID] ?? [])
        }
        #if DEBUG
        step("snapshots")
        #endif
        let libraryItems = items
        let stackKey: Int = stackSourceKey // taken with the photos it describes, before the build awaits
        let libraryItemByID = store.itemsByID
        let stackDecisions = stackRecords
        var linksByItemID: [String: TripLink] = [:]
        for trip in trips {
            let link = TripLink(id: trip.id, name: trip.effectiveName)
            for item in trip.items { linksByItemID[item.id] = link }
        }
        #if DEBUG
        step("trip links")
        #endif
        let tripLinksByItemID = linksByItemID
        let calendar = Calendar.autoupdatingCurrent
        #if DEBUG
        let queuedAt = CACurrentMediaTime()
        #endif

        let built = await Task.detached(priority: .userInitiated) { () -> TimelineBuildResult in
            #if DEBUG
            let startedAt: CFTimeInterval = CACurrentMediaTime()
            var timings: [String: Double] = [:]
            timings["queue wait"] = startedAt - queuedAt
            #endif
            // The place lookup is per photo and pure, so it runs here too.
            let hints: [String?] = await Self.placeHints(for: sourceItems, index: placeIndex)
            let hinted: [TimelineItemSnapshot] = zip(sourceItems, hints).map { (pair: (TimelineItemSnapshot, String?)) -> TimelineItemSnapshot in
                pair.0.withPlaceHint(pair.1)
            }
            #if DEBUG
            timings["place hints"] = CACurrentMediaTime() - startedAt
            #endif
            // No trips given: every photo lands in one stream, grouped by day and place.
            let document = TimelineBuilder(calendar: calendar).build(items: hinted, trips: [])
            #if DEBUG
            timings["builder"] = CACurrentMediaTime() - startedAt
            #endif
            let days = document.trips.flatMap(\.days)
            let dated = days.filter { $0.date != nil }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            let undated = days.filter { $0.date == nil }
            #if DEBUG
            timings["days"] = CACurrentMediaTime() - startedAt
            #endif
            let months = TimelineMonth.group(dated, calendar: calendar)
                + (undated.isEmpty ? [] : [TimelineMonth(id: "undated", date: nil, days: undated)])
            #if DEBUG
            timings["months"] = CACurrentMediaTime() - startedAt
            #endif
            // Every shot goes to the viewer, which folds bursts as the grid does.
            let viewerOrder = months.flatMap { month in
                month.days.flatMap { day in day.places.flatMap(\.itemIDs) }
            }
            #if DEBUG
            timings["viewer order"] = CACurrentMediaTime() - startedAt
            var result = TimelineBuildResult(months: months, viewerOrder: viewerOrder)
            result.timings = timings
            return result
            #endif
            return TimelineBuildResult(months: months, viewerOrder: viewerOrder)
        }.value
        #if DEBUG
        for (name, seconds) in built.timings {
            PageProbe.tally("timeline bg: " + name, seconds: seconds)
        }
        for (name, seconds) in TimelineBuilderTimings.shared.take() {
            PageProbe.tally("timeline builder: " + name, seconds: seconds)
        }
        var tailStarted: CFTimeInterval = CACurrentMediaTime()
        let tail: (String) -> Void = { (name: String) -> Void in
            PageProbe.tally("timeline step: " + name, seconds: CACurrentMediaTime() - tailStarted)
            tailStarted = CACurrentMediaTime()
        }
        #endif
        months = built.months
        viewerOrder = built.viewerOrder
        #if DEBUG
        tail("assign months")
        #endif
        Self.lastBuild = (key: cacheKey, months: built.months, viewerOrder: built.viewerOrder)
        stacks.update(items: libraryItems, decisions: stackDecisions, sourceKey: stackKey)
        #if DEBUG
        tail("stacks update")
        #endif
        itemByID = libraryItemByID
        tripsByItemID = tripLinksByItemID
        isBuilt = true
        #if DEBUG
        tail("finish")
        #endif
    }

    /// The pages' grouped memories: every `Memory` once, under the photo its
    /// own inverse relationship names. A memory without a photo is left out,
    /// exactly as `item.memories` never showed it.
    static func memoriesByPhotoID(_ records: [Memory]) -> [PersistentIdentifier: [Memory]] {
        var grouped: [PersistentIdentifier: [Memory]] = [:]
        for memory in records {
            guard let photo = memory.mediaItem else { continue }
            grouped[photo.persistentModelID, default: []].append(memory)
        }
        return grouped
    }

    /// The place name a snapshot's photo would have been labelled with, from
    /// its raw latitude and longitude: the same rule `nearestPlaceName(for:)`
    /// applies, kept here so it can run off the main actor.
    nonisolated private static func placeHint(
        for snapshot: TimelineItemSnapshot,
        index: NearestPlaceIndex
    ) -> String? {
        guard let latitude = snapshot.latitude, let longitude = snapshot.longitude else { return nil }
        return index.nearestName(to: GeoPoint(latitude: latitude, longitude: longitude), within: 100_000)
    }

    /// The place hints for a whole page, in the snapshots' order. The lookup is
    /// pure and depends only on a photo's coordinate, so the photos are split
    /// into chunks that run at the same time; each chunk remembers the answer
    /// for a coordinate it already looked up, since many photos share one.
    nonisolated static func placeHints(
        for snapshots: [TimelineItemSnapshot],
        index: NearestPlaceIndex
    ) async -> [String?] {
        guard !snapshots.isEmpty else { return [] }

        let photoCount = snapshots.count
        let chunkCount = min(photoCount, Self.placeHintChunkCount(for: photoCount))
        let chunkSize = (photoCount + chunkCount - 1) / chunkCount
        // A chunk index per chunk, so the parts can come back in any order.
        let bounds: [(index: Int, start: Int, end: Int)] = (0..<chunkCount).map { (chunk: Int) -> (index: Int, start: Int, end: Int) in
            let start = chunk * chunkSize
            let end = min(photoCount, start + chunkSize)
            return (index: chunk, start: start, end: end)
        }

        let parts: [Int: [String?]] = await withTaskGroup(of: (Int, [String?]).self) { (group: inout TaskGroup<(Int, [String?])>) in
            for bound in bounds {
                let slice = Array(snapshots[bound.start..<bound.end])
                group.addTask {
                    (bound.index, Self.placeHintsInOneChunk(for: slice, index: index))
                }
            }
            var collected: [Int: [String?]] = [:]
            for await part in group {
                collected[part.0] = part.1
            }
            return collected
        }

        var hints: [String?] = []
        hints.reserveCapacity(photoCount)
        for bound in bounds {
            hints.append(contentsOf: parts[bound.index] ?? [])
        }
        return hints
    }

    /// The chunks of about 500 photos the place hints are split into, one per
    /// core at most.
    nonisolated private static func placeHintChunkCount(for photoCount: Int) -> Int {
        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let smallestChunk = 500
        let byCores = (photoCount + smallestChunk - 1) / smallestChunk
        return max(1, min(cores, byCores))
    }

    /// One chunk of place hints: every photo in order, with a local memo so a
    /// coordinate shared by several photos is looked up only once.
    nonisolated private static func placeHintsInOneChunk(
        for snapshots: [TimelineItemSnapshot],
        index: NearestPlaceIndex
    ) -> [String?] {
        var memo: [GeoPoint: String?] = [:]
        var hints: [String?] = []
        hints.reserveCapacity(snapshots.count)
        for snapshot in snapshots {
            // A photo without a coordinate gets no hint, exactly as before.
            guard let latitude = snapshot.latitude, let longitude = snapshot.longitude else {
                hints.append(nil)
                continue
            }
            let point = GeoPoint(latitude: latitude, longitude: longitude)
            // A remembered "no place nearby" counts too: a stored nil is a hit,
            // only a coordinate missing from the memo is looked up.
            if let entry = memo.index(forKey: point) {
                hints.append(memo[entry].value)
                continue
            }
            let hint: String? = Self.placeHint(for: snapshot, index: index)
            memo[point] = hint
            hints.append(hint)
        }
        return hints
    }

    /// The trips a day's photos belong to, in the order they first appear.
    private func tripLinks(for day: TimelineDay) -> [TripLink] {
        var seen: Set<String> = []
        return day.places.flatMap(\.itemIDs).compactMap { tripsByItemID[$0] }.filter { seen.insert($0.id).inserted }
    }

    /// A photo opens in the large viewer, paging through the Timeline.
    private func open(_ itemID: String) {
        selection.select(itemID)
        selection.openViewer(itemID, in: viewerOrder)
    }

    private func openTrip(_ tripID: String) {
        selection.openTripID = tripID
        selection.requestedDestination = .trips
    }
}

/// The days of one calendar month, newest first.
struct TimelineMonth: Identifiable, Sendable {
    let id: String
    /// Any moment in the month; `nil` for photos without a date.
    let date: Date?
    let days: [TimelineDay]

    /// Groups days that are already sorted newest first, keeping their order.
    static func group(_ days: [TimelineDay], calendar: Calendar) -> [TimelineMonth] {
        var months: [TimelineMonth] = []
        var current: (key: String, date: Date, days: [TimelineDay])?
        for day in days {
            guard let date = day.date else { continue }
            let parts = calendar.dateComponents([.year, .month], from: date)
            let key = String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
            if current?.key == key {
                current?.days.append(day)
            } else {
                if let current { months.append(TimelineMonth(id: current.key, date: current.date, days: current.days)) }
                current = (key, date, [day])
            }
        }
        if let current { months.append(TimelineMonth(id: current.key, date: current.date, days: current.days)) }
        return months
    }
}

private struct TimelineMonthHeader: View {
    let month: TimelineMonth
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            if let date = month.date {
                Text(date, format: .dateTime.month(.wide).year().locale(locale))
            } else {
                Text("Date to add")
            }
            Spacer()
        }
        .font(.caption.weight(.semibold))
        .textCase(.uppercase)
        .foregroundStyle(Paper.muted)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Pinned headers sit on the page's own paper, not a grey material.
        .background(Paper.canvas)
        .accessibilityIdentifier("timeline.month.\(month.id)")
    }
}
