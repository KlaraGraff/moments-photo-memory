import SwiftUI
import SwiftData
import MomentsCore

/// What one Chapters build works from: everything the main actor reads, as
/// plain values, so the build can run off the main thread and an app-level
/// pre-builder can hand the page the same thing.
struct ChaptersBuildInputs: Sendable {
    /// The key the result is looked up and stored under.
    let key: Int
    /// Every photo in store order, before place hints.
    let sourceItems: [TimelineItemSnapshot]
    /// The trips in store order, as plain values.
    let sourceTrips: [TimelineSourceTrip]
    /// The chapters that are not trips, as plain values.
    let chapterSources: [TripsScreen.ChapterSource]
    let placeIndex: NearestPlaceIndex
    let calendar: Calendar
}

/// Chapters: one cover card per stretch of life — trips, events,
/// celebrations, stretches of time and custom kinds. Opening one shows it
/// day by day and place by place, with its own and each day's memories
/// written right there. Browsing and filtering every photo stays in the
/// Library, so this screen ignores the Library filters.
///
/// A chapter's photos can be changed here: new dates re-sort them, a day
/// can be added or taken out, a trip split or merged. Each change shows a
/// short note at the bottom with Undo (also on ⌘Z).
///
/// Trips are `Trip`s (a photo is in at most one trip); the other kinds are
/// `UserGroup`s of kind `.chapter`, so a photo can be in a trip and in a
/// birthday at once. Their cards and pages use the id "chapter.<group id>".
struct TripsScreen: View {
    @Environment(LibraryStore.self) private var store
    // The library's photos and places come from the shared store, which
    // fetches them once for every page.
    private var items: [MediaItem] { store.items }
    @Query private var trips: [Trip]
    @Query(filter: #Predicate<UserGroup> { $0.kindRaw == "chapter" }) private var chapterGroups: [UserGroup]
    @Query private var groupItems: [UserGroupItem]
    @Query(sort: \CollectionMemory.createdAt) private var memories: [CollectionMemory]
    @Query(sort: \Memory.updatedAt) private var memoryRecords: [Memory]
    @Environment(SelectionModel.self) private var selection
    @Environment(\.modelContext) private var modelContext
    @Environment(\.undoManager) private var undoManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(SharingController.self) private var sharing: SharingController?
    /// The card to scroll back to when leaving a trip.
    @State private var returnTripID: String?
    /// Rebuilt only when the inputs change, not on every selection change or render.
    @State private var document = TimelineDocument(trips: [])
    /// Thumbnails need the models; looked up by id, rebuilt with `document`.
    @State private var itemByID: [String: MediaItem] = [:]
    /// The last change, with its Undo.
    @State private var notice: TripNotice?
    /// Covers chosen by hand, by trip id; a library decision. This screen is
    /// the only place that changes them.
    @State private var coverStore = TripAssignmentLocks.store.string(forKey: TripCoverChoice.defaultsKey) ?? ""
    @State private var isCreatingTrip = false
    /// The trip "This is not a trip" was chosen on.
    @State private var notTripRequest: NotTripRequest?
    /// Places the photos call home, found after the photos change.
    @State private var foundPlaces: [FoundPlace] = []
    /// Shown once after an import, when nobody named a place yet.
    @State private var confirmingPlaces: [FoundPlace] = []
    @State private var placeBook = KnownPlaceStore.book()
    @State private var isConfirmingPlaces = false
    /// The chapter judge: what each trip was, and the trips it asks about.
    @State private var judge = ChapterJudgeRunner()
    @State private var judgeBook = ChapterJudgeStore.book()
    @State private var asking: [ChapterQuestion] = []
    /// Chapters that are not trips, built like trips, by "chapter.<id>".
    @State private var chapterDocs: [String: TimelineTrip] = [:]
    /// Moves each time `inputKey` changes.
    @State private var wantedBuild = 0
    /// The `wantedBuild` the shown result was built for.
    @State private var shownBuild = -1
    @State private var isBuilding = false
    /// The last finished build, kept across visits to the page: SwiftUI drops
    /// the page's `@State` when it is left, but the built values stay valid
    /// as long as the inputs key below is unchanged.
    @MainActor private static var lastBuild: (key: Int, result: ChaptersBuildResult)?

    /// Moves when anything the page builds from changes. `.onChange` follows
    /// it; the calendar is left out on purpose, as it always was.
    private var inputKey: Int {
        Self.inputKey(
            store: store,
            memories: memoryRecords,
            trips: trips,
            chapterGroups: chapterGroups,
            groupItems: groupItems
        )
    }

    /// The key the last finished build is stored under: the same `inputKey`
    /// that decides whether the open page rebuilds, plus the calendar the
    /// build groups by, so a different calendar never shows the old result.
    private var buildCacheKey: Int {
        Self.buildKey(
            store: store,
            memories: memoryRecords,
            trips: trips,
            chapterGroups: chapterGroups,
            groupItems: groupItems,
            calendar: Calendar.autoupdatingCurrent
        )
    }

    /// The fields `inputKey` hashes, with each row array reduced to its count
    /// and the sum of its own row hashes. Summing does not depend on the order
    /// a fetch returns the rows in, and every field is read once, so this stays
    /// O(n) on every body evaluation.
    @MainActor
    private static func inputKey(
        store: LibraryStore,
        memories: [Memory],
        trips: [Trip],
        chapterGroups: [UserGroup],
        groupItems: [UserGroupItem]
    ) -> Int {
        var hasher = Hasher()
        // All photos and places the page groups by, as one revision. Faces
        // are left out because the page does not read them, so a save that
        // changed nothing but faces does not rebuild the chapters.
        hasher.combine(store.photoPlaceRevision)

        var memoriesSum: Int = 0
        for memory in memories {
            var row: Hasher = Hasher()
            row.combine(memory.id)
            row.combine(memory.mediaID)
            row.combine(memory.updatedAt)
            row.combine(memory.revision)
            memoriesSum = memoriesSum &+ row.finalize()
        }
        hasher.combine(memories.count)
        hasher.combine(memoriesSum)

        var tripsSum: Int = 0
        for trip in trips {
            var row: Hasher = Hasher()
            row.combine(trip.id)
            row.combine(trip.effectiveName)
            row.combine(trip.items.count)
            row.combine(trip.startDate)
            row.combine(trip.endDate)
            tripsSum = tripsSum &+ row.finalize()
        }
        hasher.combine(trips.count)
        hasher.combine(tripsSum)

        var chapterGroupsSum: Int = 0
        for group in chapterGroups {
            var row: Hasher = Hasher()
            row.combine(group.id)
            row.combine(group.name)
            row.combine(group.rulesData)
            chapterGroupsSum = chapterGroupsSum &+ row.finalize()
        }
        hasher.combine(chapterGroups.count)
        hasher.combine(chapterGroupsSum)

        var groupItemsSum: Int = 0
        for membership in groupItems {
            var row: Hasher = Hasher()
            row.combine(membership.id)
            row.combine(membership.excluded)
            groupItemsSum = groupItemsSum &+ row.finalize()
        }
        hasher.combine(groupItems.count)
        hasher.combine(groupItemsSum)

        return hasher.finalize()
    }

    /// The one key for a Chapters build: the `inputKey` above, then the
    /// calendar the build groups by, so a different calendar never shows the
    /// old result. A later pre-builder fetches its own rows and calls this.
    @MainActor
    static func buildKey(
        store: LibraryStore,
        memories: [Memory],
        trips: [Trip],
        chapterGroups: [UserGroup],
        groupItems: [UserGroupItem],
        calendar: Calendar
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(Self.inputKey(
            store: store,
            memories: memories,
            trips: trips,
            chapterGroups: chapterGroups,
            groupItems: groupItems
        ))
        hasher.combine(calendar.identifier)
        hasher.combine(calendar.timeZone.identifier)
        return hasher.finalize()
    }

    nonisolated static func chapterID(_ group: UserGroup) -> String { "chapter." + group.id }

    /// One chapter that is not a trip, as plain values: the main actor reads
    /// the group, its dates and its member photo ids; the build then runs off it.
    struct ChapterSource: Sendable {
        let id: String
        let name: String
        let mediaIDs: [String]
        let startDate: Date?
        let endDate: Date?
    }

    /// Each chapter that is not a trip, built from its own photos only, so
    /// photos it shares with a trip appear in both.
    nonisolated private static func buildChapters(
        sources: [ChapterSource],
        snapshots: [String: TimelineItemSnapshot],
        calendar: Calendar
    ) -> [String: TimelineTrip] {
        var result: [String: TimelineTrip] = [:]
        let builder = TimelineBuilder(calendar: calendar)
        for source in sources {
            let members = source.mediaIDs.compactMap { snapshots[$0] }
            let trips = [TimelineSourceTrip(
                id: source.id,
                name: source.name,
                itemIDs: source.mediaIDs,
                startDate: source.startDate,
                endDate: source.endDate
            )]
            let built = builder.build(items: members, trips: trips).trips.first { $0.id == source.id }
            result[source.id] = built ?? TimelineTrip(
                id: source.id,
                name: source.name,
                days: [],
                startDate: source.startDate,
                plannedEndDate: source.endDate
            )
        }
        return result
    }

    nonisolated private static func buildDocument(
        _ sourceItems: [TimelineItemSnapshot],
        sourceTrips: [TimelineSourceTrip],
        calendar: Calendar
    ) -> TimelineDocument {
        TimelineBuilder(calendar: calendar).build(
            items: sourceItems,
            trips: sourceTrips
        )
    }

    /// Every chapter, newest first, like a photo album shelf. Chapters other
    /// than trips show even before they have photos. Photos in no trip are
    /// daily life, which lives in the Library and Timeline, not here.
    private var allChapters: [TimelineTrip] {
        // A trip someone made by hand keeps its card even before photos join.
        // Imports mark their trips as suggested or confirmed; hand-made ones carry no status.
        let planned = Set(trips.filter { $0.startDate != nil && $0.suggestionStatusRaw == nil }.map(\.id))
        let real = document.trips.filter { !$0.isUnsorted && ($0.itemCount > 0 || planned.contains($0.id)) } + Array(chapterDocs.values)
        let dated = real.filter { $0.startDate != nil }.sorted { ($0.startDate ?? .distantPast, $0.id) > ($1.startDate ?? .distantPast, $1.id) }
        let undated = real.filter { $0.startDate == nil }
        return dated + undated
    }

    /// The kinds that have chapters, presets first, for a new chapter's kind.
    private var typesPresent: [ChapterType] {
        let present = Set(allChapters.filter { !$0.isUnsorted }.map { chapterType(of: $0) })
        let custom = present.filter { if case .custom = $0 { return true } else { return false } }.sorted { $0.label < $1.label }
        return ChapterType.builtIn.filter(present.contains) + custom
    }

    private func chapterType(of chapter: TimelineTrip) -> ChapterType {
        target(of: chapter.id)?.type ?? .trip
    }

    private var openTrip: TimelineTrip? {
        guard let id = selection.openTripID else { return nil }
        return document.trips.first { $0.id == id } ?? chapterDocs[id]
    }

    private var tripByID: [String: Trip] {
        Dictionary(trips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func target(of id: String) -> ChapterTarget? {
        if let trip = tripByID[id] { return .trip(trip) }
        if id.hasPrefix("chapter."), let group = chapterGroups.first(where: { Self.chapterID($0) == id }) { return .group(group) }
        return nil
    }

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView(
                    "No chapters yet",
                    systemImage: "book.pages",
                    description: Text("Import photos and trips appear here on their own. Use + for an event, a celebration or any stretch of time.")
                )
            } else if document.trips.isEmpty && chapterDocs.isEmpty {
                // Built on appear; until then show the bare page, not "0 trips".
                Paper.canvas
            } else if let trip = openTrip {
                TripDetailView(
                    trip: trip,
                    target: target(of: trip.id),
                    otherTrips: mergeCandidates(for: trip),
                    around: daysAround(trip),
                    itemByID: itemByID,
                    memories: memories,
                    actions: actions
                )
                .transition(.opacity)
            } else {
                TripShelfView(
                    trips: allChapters,
                    target: target(of:),
                    itemByID: itemByID,
                    covers: TripCoverChoice.decode(coverStore),
                    memories: memories,
                    returnTripID: returnTripID,
                    actions: actions,
                    onOpen: open,
                    onNew: { isCreatingTrip = true }
                )
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 8) {
                        if let place = newPlace {
                            NewPlaceBanner(
                                place: place,
                                onWork: { answer(place, role: .work) },
                                onTrip: { answerTrip(place) },
                                onLater: { answer(place, role: nil) }
                            )
                        } else if judge.isRunning {
                            ChapterJudgeProgressBanner(done: judge.done, total: judge.total)
                        } else if !questionTrips.isEmpty {
                            ChapterQuestionBanner(
                                count: questionTrips.count,
                                onLook: { asking = questionTrips.map(question(for:)) },
                                onLater: deferQuestions
                            )
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, newPlace != nil || judge.isRunning || !questionTrips.isEmpty ? 12 : 0)
                    .transition(.opacity)
                }
                .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if let notice {
                TripNoticeBar(notice: notice, onUndo: { undo(notice) }, onAdopt: { adopt(notice) }, onClose: { self.notice = nil })
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.animation(Motion.settle, reduceMotion: reduceMotion), value: notice?.id)
        // ⌘Z already put things back; the note and its offer no longer apply.
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidUndoChange)) { _ in
            judgeBook = ChapterJudgeStore.book()
            notice = nil
        }
        // However the chapter closed (the window's back button too), the
        // shelf comes back at its card.
        .onChange(of: selection.openTripID) { (old: String?, new: String?) in
            if new == nil, let old { returnTripID = old }
            if new == nil { settleOrdinaryDays() }
        }
        // Ordinary days left while another change's Undo was up.
        .onChange(of: notice == nil) { (_: Bool, cleared: Bool) in
            if cleared { settleOrdinaryDays() }
        }
        #if DEBUG
        .onAppear {
            PageProbe.shellReady(token: PageProbe.phaseToken)
        }
        #endif
        .task(id: notice?.id) {
            // A note without a question goes away by itself.
            guard let notice, notice.offer == nil else { return }
            try? await Task.sleep(for: .seconds(10))
            if self.notice?.id == notice.id { self.notice = nil }
        }
        .sheet(item: $notTripRequest) { request in
            NotTripSheet(
                tripName: request.name,
                summary: request.summary,
                placeName: request.place?.name,
                usedTypes: typesPresent.compactMap { if case let .custom(label) = $0 { return label } else { return nil } },
                onDone: { choice, remember in markNotTrip(request, as: choice, remember: remember) }
            )
        }
        .sheet(isPresented: $isConfirmingPlaces) {
            PlaceConfirmSheet(
                places: confirmingPlaces,
                onConfirm: confirmPlaces,
                onLater: {
                    KnownPlaceStore.change(context: nil) { $0.markAsked(confirmingPlaces.map(\.candidate.centre)) }
                    isConfirmingPlaces = false
                }
            )
            .interactiveDismissDisabled()
        }
        .task(id: store.photoPlaceRevision) {
            await findPlaces()
            await judgeChapters()
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDecisionChanged)) { note in
            switch note.object as? String {
            case KnownPlaceStore.key: placeBook = KnownPlaceStore.book()
            case ChapterJudgeStore.key: judgeBook = ChapterJudgeStore.book()
            default: break
            }
        }
        .sheet(isPresented: Binding(get: { !asking.isEmpty }, set: { if !$0 { asking = [] } })) {
            ChapterAskSheet(questions: asking, onAnswer: { setKind($0.id, $1) }, onLater: { question in
                judgeBook = ChapterJudgeStore.change { $0.deferQuestion(for: question.id, now: .now) }
            })
        }
        .sheet(isPresented: $isCreatingTrip) {
            ChapterNewSheet(
                initialType: .trip,
                customTypes: typesPresent.filter { if case .custom = $0 { return true } else { return false } },
                onCreate: createChapter
            )
        }
        .onChange(of: inputKey, initial: true) { _, _ in
            wantedBuild &+= 1
            startBuildingIfIdle()
        }
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
                await rebuild()
                shownBuild = target
                #if DEBUG
                PageProbe.contentReady(token: probeToken)
                #endif
            }
            isBuilding = false
        }
    }

    /// The last finished build for a key, if it is still the one asked for.
    @MainActor
    static func cachedBuild(key: Int) -> ChaptersBuildResult? {
        guard let lastBuild, lastBuild.key == key else { return nil }
        return lastBuild.result
    }

    /// Remembers a finished build under the key it was built for.
    @MainActor
    static func storeBuild(_ result: ChaptersBuildResult, key: Int) {
        lastBuild = (key: key, result: result)
    }

    /// Everything the build reads from SwiftData, in one main-actor pass, as
    /// plain values only: the place index, memories by photo, the snapshots,
    /// the source trips and the chapter sources, all in store order.
    @MainActor
    static func buildInputs(
        key: Int,
        store: LibraryStore,
        trips: [Trip],
        chapterGroups: [UserGroup],
        groupItems: [UserGroupItem],
        memories: [Memory],
        calendar: Calendar
    ) -> ChaptersBuildInputs {
        let placeIndex = NearestPlaceIndex(places: store.places)
        let memoriesByPhotoID = Self.memoriesByPhotoID(memories)
        let sourceItems: [TimelineItemSnapshot] = store.items.map { (item: MediaItem) -> TimelineItemSnapshot in
            TimelineItemSnapshot(item: item, placeHint: nil, memories: memoriesByPhotoID[item.persistentModelID] ?? [])
        }
        let sourceTrips: [TimelineSourceTrip] = trips.map { (trip: Trip) -> TimelineSourceTrip in
            TimelineSourceTrip(
                id: trip.id,
                name: trip.effectiveName,
                itemIDs: trip.items.map(\.id),
                startDate: trip.startDate,
                endDate: trip.endDate
            )
        }
        let chapterSources: [ChapterSource] = Self.chapterSources(groups: chapterGroups, members: groupItems)
        return ChaptersBuildInputs(
            key: key,
            sourceItems: sourceItems,
            sourceTrips: sourceTrips,
            chapterSources: chapterSources,
            placeIndex: placeIndex,
            calendar: calendar
        )
    }

    /// The same inputs as `buildInputs`, made for an app-level pre-build: the
    /// snapshots are taken in slices with a yield between them, so a 20 000
    /// photo library never means one long main-actor pass. A photo is only
    /// touched while the photos and places it was read for still stand;
    /// anything moving under the read returns nil.
    @MainActor
    static func buildInputsSliced(
        key: Int,
        store: LibraryStore,
        trips: [Trip],
        chapterGroups: [UserGroup],
        groupItems: [UserGroupItem],
        memories: [Memory],
        calendar: Calendar
    ) async -> ChaptersBuildInputs? {
        // Taken before anything is read: this describes the library the
        // snapshots below belong to.
        let revisionAtStart: Int = store.photoPlaceRevision
        let placeIndex = NearestPlaceIndex(places: store.places)
        let memoriesByPhotoID = Self.memoriesByPhotoID(memories)
        let items: [MediaItem] = store.items
        var sourceItems: [TimelineItemSnapshot] = []
        sourceItems.reserveCapacity(items.count)
        var start = 0
        while start < items.count {
            guard PagePrebuildSliceRule.readIsCurrent(
                startedAtPhotoPlaceRevision: revisionAtStart,
                photoPlaceRevision: store.photoPlaceRevision,
                startedAtVisibleGeneration: nil,
                visibleGeneration: nil,
                isCancelled: Task.isCancelled
            ) else { return nil }
            let end = min(items.count, start + PagePrebuildSliceRule.sliceSize)
            for index in start..<end {
                let item: MediaItem = items[index]
                sourceItems.append(
                    TimelineItemSnapshot(
                        item: item,
                        placeHint: nil,
                        memories: memoriesByPhotoID[item.persistentModelID] ?? []
                    )
                )
            }
            start = end
            await Task.yield()
            guard PagePrebuildSliceRule.readIsCurrent(
                startedAtPhotoPlaceRevision: revisionAtStart,
                photoPlaceRevision: store.photoPlaceRevision,
                startedAtVisibleGeneration: nil,
                visibleGeneration: nil,
                isCancelled: Task.isCancelled
            ) else { return nil }
        }
        let sourceTrips: [TimelineSourceTrip] = trips.map { (trip: Trip) -> TimelineSourceTrip in
            TimelineSourceTrip(
                id: trip.id,
                name: trip.effectiveName,
                itemIDs: trip.items.map(\.id),
                startDate: trip.startDate,
                endDate: trip.endDate
            )
        }
        let chapterSources: [ChapterSource] = Self.chapterSources(groups: chapterGroups, members: groupItems)
        return ChaptersBuildInputs(
            key: key,
            sourceItems: sourceItems,
            sourceTrips: sourceTrips,
            chapterSources: chapterSources,
            placeIndex: placeIndex,
            calendar: calendar
        )
    }

    /// The one Chapters build: place hints, then the shelf's document and
    /// every chapter. This is the body `rebuild()` ran in its detached task,
    /// unchanged, so an app-level pre-builder can run the same build.
    nonisolated static func build(
        _ inputs: ChaptersBuildInputs,
        priority: TaskPriority = .userInitiated
    ) async -> ChaptersBuildResult {
        let sourceItems: [TimelineItemSnapshot] = inputs.sourceItems
        let sourceTrips: [TimelineSourceTrip] = inputs.sourceTrips
        let chapterSources: [ChapterSource] = inputs.chapterSources
        let placeIndex: NearestPlaceIndex = inputs.placeIndex
        let calendar: Calendar = inputs.calendar
        let built = await Task.detached(priority: priority) { () -> ChaptersBuildResult in
            let hinted = sourceItems.map { snapshot in
                snapshot.withPlaceHint(Self.placeHint(for: snapshot, index: placeIndex))
            }
            let byID = Dictionary(hinted.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let document = Self.buildDocument(hinted, sourceTrips: sourceTrips, calendar: calendar)
            let chapterDocs = Self.buildChapters(sources: chapterSources, snapshots: byID, calendar: calendar)
            return ChaptersBuildResult(document: document, chapterDocs: chapterDocs)
        }.value
        return built
    }

    /// Reads everything SwiftData in one pass on the main actor, then builds
    /// the shelf and every chapter off the main thread. Only one build runs at
    /// a time, so no older result can arrive late and overwrite a newer one.
    private func rebuild() async {
        // Taken before anything is read: these are the inputs this build uses,
        // and a change during the build must not be stored under a newer key.
        let cacheKey = buildCacheKey
        if let cached = Self.cachedBuild(key: cacheKey) {
            // Nothing changed since the last finished build: show it at once,
            // without the snapshots, place hints or builder.
            document = cached.document
            chapterDocs = cached.chapterDocs
            itemByID = store.itemsByID
            #if DEBUG
            PageProbe.tally("chapters last build reused", seconds: 0)
            #endif
            return
        }
        let libraryItemByID = store.itemsByID
        // Everything the build reads stays on the main actor and becomes one
        // inputs value; the build below sees plain values only.
        let inputs = Self.buildInputs(
            key: cacheKey,
            store: store,
            trips: trips,
            chapterGroups: chapterGroups,
            groupItems: groupItems,
            memories: memoryRecords,
            calendar: Calendar.autoupdatingCurrent
        )
        let built: ChaptersBuildResult
        if let joined = await PagePrebuilder.shared.joinChapters(key: cacheKey) {
            built = joined
        } else {
            PagePrebuilder.shared.cancel()
            built = await Self.build(inputs)
        }
        document = built.document
        chapterDocs = built.chapterDocs
        itemByID = libraryItemByID
        Self.storeBuild(built, key: cacheKey)
    }

    /// The chapters that are not trips, as plain values: their ids, names,
    /// own dates, and the photo ids of their members (`excluded` left out).
    private static func chapterSources(
        groups: [UserGroup],
        members: [UserGroupItem]
    ) -> [ChapterSource] {
        let membersByGroup = Dictionary(grouping: members.filter { !$0.excluded }, by: \.groupID)
        return groups.map { group in
            let mediaIDs = Array(Set((membersByGroup[group.id] ?? []).map(\.mediaID)))
            let info = group.chapterInfo
            return ChapterSource(
                id: chapterID(group),
                name: group.name,
                mediaIDs: mediaIDs,
                startDate: info.startDate,
                endDate: info.endDate
            )
        }
    }

    /// The page's grouped memories: every `Memory` once, under the photo its
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

    private func open(_ trip: TimelineTrip) {
        withAnimation(Motion.animation(Motion.settle, reduceMotion: reduceMotion)) {
            selection.openTripID = trip.id
        }
    }

    private func closeTrip() {
        selection.viewerRequest = nil
        returnTripID = selection.openTripID
        withAnimation(Motion.animation(Motion.settle, reduceMotion: reduceMotion)) {
            selection.openTripID = nil
        }
    }

    // MARK: Changes

    private var actions: TripActions {
        TripActions(
            changeDates: changeDates,
            makePreview: makePreview,
            addPhotos: { ids, target in
                edit(String(localized: "Added")) { session in
                    switch target {
                    case let .trip(trip): TripEdits.add(ids, to: trip, session: session)
                    case let .group(group): TripEdits.add(ids, to: group, session: session)
                    }
                }
            },
            removeDay: { day, target in
                edit(String(localized: "Day taken out")) { session in
                    switch target {
                    case let .trip(trip): TripEdits.removeDay(day, from: trip, session: session)
                    case let .group(group): TripEdits.removeDay(day, from: group, session: session)
                    }
                }
            },
            split: { day, trip in
                let session = TripEdits.Session(context: modelContext)
                guard let part = TripEdits.split(trip, at: day, session: session) else { return }
                post(TripNotice(message: String(localized: "Split off “\(part.effectiveName)”"), undo: session.undo))
            },
            merge: { other, trip in
                let name = other.effectiveName
                edit(String(localized: "Merged “\(name)” into this trip")) { TripEdits.merge(other, into: trip, session: $0) }
            },
            delete: { target in
                if case let .group(group) = target, !UserGroupRuleEngine.canDelete(group) { return }
                let name = target.name
                closeTrip()
                // Brought back with Undo, the judge asks about it rather
                // than taking it away again.
                var deleted: ChapterJudgeUndo?
                if case let .trip(trip) = target { deleted = .ask([trip.id]) }
                edit(String(localized: "Deleted “\(name)”"), judgeUndo: deleted) { session in
                    switch target {
                    case let .trip(trip): TripEdits.delete(trip, session: session)
                    case let .group(group): TripEdits.delete(group, session: session)
                    }
                }
            },
            rename: { target, name in
                switch target {
                case let .trip(trip): TripRenaming.rename(trip, to: name, context: modelContext)
                case let .group(group):
                    // Only whoever made the chapter renames it (issue #28).
                    guard UserGroupRuleEngine.canEdit(group) else { return }
                    let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.isEmpty, value != group.name else { return }
                    let log = TripCorrectionSnapshotBuilder(context: modelContext)
                    let before = [log.chapter(group)]
                    group.name = value
                    group.updatedAt = .now
                    try? modelContext.save()
                    TripCorrectionRecorder.record(.rename, before: before, after: [log.chapter(group)])
                }
            },
            notTrip: { trip in
                notTripRequest = NotTripRequest(trip: trip, summary: notTripSummary(trip), place: KnownPlaceStore.placeOfTrip(trip.items))
            },
            setCover: { tripID, itemID in
                var choices = TripCoverChoice.decode(coverStore)
                choices[tripID] = itemID
                coverStore = TripCoverChoice.encode(choices)
                TripAssignmentLocks.store.set(coverStore, forKey: TripCoverChoice.defaultsKey)
            },
            judged: judgeState(for:),
            setKind: { trip, kind in _ = setKind(trip.id, kind) },
            confirmKind: confirmKind
        )
    }

    /// What new dates would do, from photos gathered once when the dates open.
    private func makePreview(_ target: ChapterTarget) -> (Date, Date) -> TripEdits.Plan {
        let calendar = Calendar.current
        switch target {
        case let .trip(trip):
            let members = TripEdits.members(context: modelContext)
            return { TripEdits.plan(for: trip, start: $0, end: $1, members: members, calendar: calendar) }
        case let .group(group):
            let members = TripEdits.members(of: group, context: modelContext)
            return { TripEdits.plan(for: group.id, start: $0, end: $1, members: members, calendar: calendar) }
        }
    }

    private func edit(_ message: String, judgeUndo: ChapterJudgeUndo? = nil, _ change: (TripEdits.Session) -> Void) {
        let session = TripEdits.Session(context: modelContext)
        change(session)
        guard !session.undo.isEmpty else { return }
        var notice = TripNotice(message: message, undo: session.undo)
        notice.judgeUndo = judgeUndo
        post(notice)
    }

    private func changeDates(_ target: ChapterTarget, start: Date, end: Date) {
        let session = TripEdits.Session(context: modelContext)
        guard case let .trip(trip) = target else {
            if case let .group(group) = target {
                let result = TripEdits.changeDates(of: group, start: start, end: end, session: session)
                post(TripNotice(message: String(localized: "Dates changed · \(result.joined) added · \(result.left) taken out"), undo: session.undo))
            }
            return
        }
        let outcome = TripEdits.changeDates(of: trip, start: start, end: end, session: session)
        var notice = TripNotice(
            message: String(localized: "Dates changed · \(outcome.joined) added · \(outcome.left) taken out"),
            undo: outcome.undo
        )
        let others = outcome.elsewhere.flatMap(\.itemIDs)
        if !others.isEmpty {
            let names = outcome.elsewhere.map { "“\($0.name)”" }.joined(separator: ", ")
            notice.offer = TripNotice.Offer(
                tripID: trip.id,
                text: String(localized: "Photos in these dates that belong to \(names): \(others.count)"),
                itemIDs: others
            )
        }
        post(notice)
    }

    private func createChapter(named name: String, type: ChapterType, symbol: String?, start: Date, end: Date) {
        guard type == .trip else {
            let session = TripEdits.Session(context: modelContext)
            let group = TripEdits.createChapter(named: name, type: type, symbol: symbol, start: start, end: end, session: session)
            let count = TripEdits.memberIDs(of: group, context: modelContext).count
            post(TripNotice(message: String(localized: "New chapter · \(count) photos"), undo: session.undo))
            withAnimation(Motion.animation(Motion.settle, reduceMotion: reduceMotion)) {
                selection.openTripID = Self.chapterID(group)
            }
            return
        }
        createTrip(named: name, start: start, end: end)
    }

    private func createTrip(named name: String, start: Date, end: Date) {
        let session = TripEdits.Session(context: modelContext)
        let created = TripEdits.create(named: name, start: start, end: end, session: session)
        var notice = TripNotice(
            message: String(localized: "New trip · \(created.outcome.joined) photos added"),
            undo: created.outcome.undo
        )
        let others = created.outcome.elsewhere.flatMap(\.itemIDs)
        if !others.isEmpty {
            let names = created.outcome.elsewhere.map { "“\($0.name)”" }.joined(separator: ", ")
            notice.offer = TripNotice.Offer(
                tripID: created.trip.id,
                text: String(localized: "Photos in these dates that belong to \(names): \(others.count)"),
                itemIDs: others
            )
        }
        post(notice)
        withAnimation(Motion.animation(Motion.settle, reduceMotion: reduceMotion)) {
            selection.openTripID = created.trip.id
        }
    }

    private func adopt(_ notice: TripNotice) {
        guard let offer = notice.offer, let trip = tripByID[offer.tripID] else { return }
        let session = TripEdits.Session(context: modelContext, continuing: notice.undo)
        TripEdits.add(offer.itemIDs, to: trip, session: session)
        post(TripNotice(message: String(localized: "Added to the trip"), undo: session.undo))
    }

    private func undo(_ notice: TripNotice) {
        undoManager?.removeAllActions(withTarget: selection)
        TripEdits.undo(notice.undo, context: modelContext)
        if let places = notice.placesBefore { KnownPlaceStore.save(places) }
        if let judged = notice.judgeUndo { judgeBook = judged.apply() }
        self.notice = nil
    }

    /// Shows the note and puts the change on ⌘Z, replacing the previous one.
    private func post(_ notice: TripNotice) {
        undoManager?.removeAllActions(withTarget: selection)
        let context = modelContext
        let undo = notice.undo
        let places = notice.placesBefore
        let judged = notice.judgeUndo
        undoManager?.registerUndo(withTarget: selection) { _ in
            MainActor.assumeIsolated {
                TripEdits.undo(undo, context: context)
                if let places { KnownPlaceStore.save(places) }
                if let judged { judged.apply() }
            }
        }
        undoManager?.setActionName(notice.message)
        self.notice = notice
    }

    // MARK: Chapter kinds

    /// Trips the judge is not sure about and has not put off, newest first.
    private var questionTrips: [Trip] {
        let now = Date.now
        return trips
            .filter { judgeBook.isQuestion($0.id, now: now) && !$0.items.isEmpty }
            .sorted { ($0.startDate ?? .distantPast) > ($1.startDate ?? .distantPast) }
    }

    private func question(for trip: Trip) -> ChapterQuestion {
        let items = trip.orderedItems
        let stills = items.filter { $0.kind != .video }
        let step = max(1, stills.count / 4)
        let photos = stride(from: 0, to: stills.count, by: step).prefix(4).map { stills[$0] }
        let verdict = judgeBook.verdict(for: trip.id) ?? ChapterVerdict(kind: .trip, confidence: .low, source: .rules)
        var options = [verdict.kind]
        for kind in verdict.alternatives + judgeBook.candidates where !options.contains(kind) {
            options.append(kind)
        }
        return ChapterQuestion(
            id: trip.id,
            place: ChapterEvidenceBuilder.placeName(of: items),
            photos: photos,
            facts: ChapterJudgeText.facts(start: trip.startDate, end: trip.endDate, verdict: verdict),
            verdict: verdict,
            options: options
        )
    }

    /// "Later" on the banner: the questions wait a week.
    private func deferQuestions() {
        let ids = questionTrips.map(\.id)
        judgeBook = ChapterJudgeStore.change { book in
            for id in ids { book.deferQuestion(for: id, now: .now) }
        }
    }

    private func judgeState(for tripID: String) -> ChapterJudgeState? {
        guard let stored = judgeBook.verdicts[tripID], let kind = judgeBook.shownKind(for: tripID), kind != .daily else { return nil }
        let others = judgeBook.candidates.filter { $0 != kind }
        return ChapterJudgeState(
            kind: kind,
            verdict: stored.verdict,
            action: judgeBook.action(for: tripID),
            showsCheck: judgeBook.showsCheck(tripID, now: .now),
            choices: Array(others.prefix(4)) + [.daily]
        )
    }

    /// Judges the trips that need it, then settles the ones it is sure were
    /// ordinary days.
    private func judgeChapters() async {
        guard !items.isEmpty, !ProcessInfo.processInfo.arguments.contains("-MomentsUITesting") else { return }
        await judge.run(trips: trips, places: KnownPlaceStore.book(), found: foundPlaces)
        guard !Task.isCancelled else { return }
        settleOrdinaryDays()
    }

    /// Trips the judge is sure were ordinary days, from any pass: removed
    /// with one Undo when nobody touched them, asked about when someone did.
    /// One that is open, or waits behind another change's Undo, is left for
    /// the next look.
    private func settleOrdinaryDays() {
        let candidates = ChapterJudgeStore.book().removals(among: trips.map(\.id))
        guard !candidates.isEmpty else {
            judgeBook = ChapterJudgeStore.book()
            return
        }
        let remembered = TripRegrouping.rememberedTripIDs(context: modelContext)
        let covered = Set(TripCoverChoice.decode(coverStore).keys)
        let locked = TripAssignmentLocks.lockedIDs()
        var remove: [Trip] = []
        var ask: [String] = []
        let byID = tripByID
        for id in candidates {
            guard let trip = byID[id] else { continue }
            let touched = TripRegrouping.isTouched(trip, remembered: remembered, covered: covered, locked: locked)
                || trip.confirmedAt != nil || sharing?.isShared(tripID: id) == true
            if touched {
                ask.append(id)
            } else if selection.openTripID != id && notice == nil {
                remove.append(trip)
            }
        }
        if !ask.isEmpty { ChapterJudgeStore.change { $0.askInstead(ask) } }
        judgeBook = ChapterJudgeStore.book()
        guard !remove.isEmpty else { return }
        let session = TripEdits.Session(context: modelContext)
        // The judge's own change, not a hand correction.
        session.pauseCorrectionLog()
        for trip in remove { TripEdits.delete(trip, session: session) }
        var notice = TripNotice(message: String(localized: "\(remove.count) stretches were daily life, not chapters"), undo: session.undo)
        notice.judgeUndo = .ask(remove.map(\.id))
        post(notice)
    }

    /// The person's answer: the trip is that kind from now on, and days
    /// like it are judged by it. Ordinary days remove the trip, with Undo.
    /// False only when a typed kind could not be kept; a trip that is gone
    /// meanwhile needs no answer.
    @discardableResult
    private func setKind(_ tripID: String, _ kind: ChapterKind) -> Bool {
        guard let trip = tripByID[tripID], !trip.isDeleted,
              let evidence = ChapterJudgeEvidence.evidence(of: trip, places: placeBook, found: foundPlaces) else { return true }
        let before = ChapterJudgeStore.book().entries(for: [tripID])
        var kept = false
        judgeBook = ChapterJudgeStore.change { kept = $0.decide(kind, for: trip.id, title: trip.effectiveName, evidence: evidence, now: .now) }
        guard kept else { return false }
        if kind == .daily {
            let name = trip.effectiveName
            if selection.openTripID == trip.id { closeTrip() }
            let session = TripEdits.Session(context: modelContext)
            TripEdits.delete(trip, session: session)
            var notice = TripNotice(message: String(localized: "“\(name)” is daily life now."), undo: session.undo)
            notice.judgeUndo = .restore(before)
            post(notice)
        }
        return true
    }

    /// "Right" on the check: the judge's kind is the person's too.
    private func confirmKind(_ trip: Trip) {
        guard let kind = judgeBook.shownKind(for: trip.id) else { return }
        setKind(trip.id, kind)
    }

    // MARK: Places

    /// A place the photos newly call home, asked about above the chapters
    /// once the person has named a place of their own.
    private var newPlace: FoundPlace? {
        guard !isConfirmingPlaces, placeBook.places.contains(where: { $0.role != .notTrip }) else { return nil }
        let unasked = placeBook.unasked(foundPlaces.map(\.candidate))
        return foundPlaces.first { place in
            place.candidate.isCurrent && unasked.contains { $0.centre == place.candidate.centre }
        }
    }

    /// Looks for the places the photos call home once the photos settle.
    /// The first time, before any place is named, they are asked about
    /// in one sheet.
    private func findPlaces() async {
        guard !items.isEmpty, !ProcessInfo.processInfo.arguments.contains("-MomentsUITesting") else { return }
        // An import saves in steps; look once it is done.
        try? await Task.sleep(for: .seconds(3))
        guard !Task.isCancelled else { return }
        let found = await KnownPlaceStore.findPlaces(items: items, book: KnownPlaceStore.book())
        guard !Task.isCancelled else { return }
        placeBook = KnownPlaceStore.book()
        foundPlaces = found
        let unasked = placeBook.unasked(found.map(\.candidate))
        guard !isConfirmingPlaces, !unasked.isEmpty,
              !placeBook.places.contains(where: { $0.role != .notTrip }) else { return }
        confirmingPlaces = Array(found.filter { place in unasked.contains { $0.centre == place.candidate.centre } }.prefix(5))
        isConfirmingPlaces = true
    }

    private func confirmPlaces(_ choices: [(FoundPlace, PlaceRole?)]) {
        KnownPlaceStore.change(context: modelContext) { book in
            for (place, role) in choices {
                if let role {
                    book.confirm(place.candidate, name: place.name, role: role, now: .now)
                } else {
                    book.decline(place.candidate.centre)
                }
            }
            book.markAsked(choices.map(\.0.candidate.centre))
        }
        placeBook = KnownPlaceStore.book()
        isConfirmingPlaces = false
    }

    /// The banner's answer: a work site, or `nil` to ask again only in Settings.
    private func answer(_ place: FoundPlace, role: PlaceRole?) {
        KnownPlaceStore.change(context: modelContext) { book in
            if let role { book.confirm(place.candidate, name: place.name, role: role, now: .now) }
            book.markAsked([place.candidate.centre])
        }
        placeBook = KnownPlaceStore.book()
    }

    /// "It was a trip": the place is no home, and its weeks become a trip.
    private func answerTrip(_ place: FoundPlace) {
        KnownPlaceStore.change(context: modelContext) { book in
            book.decline(place.candidate.centre)
            book.markAsked([place.candidate.centre])
        }
        placeBook = KnownPlaceStore.book()
        createTrip(named: place.name, start: place.candidate.firstDate, end: place.candidate.lastDate)
    }

    /// "Oct 10 – 12, 2026 · 86 photos"
    private func notTripSummary(_ trip: Trip) -> String {
        var parts: [String] = []
        if let start = trip.startDate {
            let formatter = DateIntervalFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            parts.append(formatter.string(from: start, to: max(trip.endDate ?? start, start)))
        }
        parts.append(String(localized: "\(trip.items.count) photos"))
        return parts.joined(separator: " · ")
    }

    /// The trip becomes daily life, or a chapter of the kind typed, and
    /// visits to its place can be remembered as no trip. One Undo puts it
    /// all back.
    private func markNotTrip(_ request: NotTripRequest, as choice: NotTripChoice, remember: Bool) {
        let trip = request.trip
        let name = trip.effectiveName
        let dates = trip.items.compactMap(\.effectiveCaptureDate)
        closeTrip()
        let session = TripEdits.Session(context: modelContext)
        var chapterID: String?
        var message: String
        switch choice {
        case let .custom(label):
            if let start = trip.startDate ?? dates.min(), let end = trip.endDate ?? dates.max() {
                let group = TripEdits.createChapter(named: name, type: .custom(label), symbol: "tag", start: start, end: max(start, end), session: session)
                chapterID = Self.chapterID(group)
                message = String(localized: "“\(name)” is now a chapter of the kind “\(label)”.")
            } else {
                message = String(localized: "“\(name)” is daily life now.")
            }
        case .dailyLife:
            message = String(localized: "“\(name)” is daily life now.")
        }
        TripEdits.delete(trip, session: session)
        var placesBefore: KnownPlaceBook?
        if remember, let place = request.place {
            // Only what comes later: chapters already made stay as they are.
            placesBefore = KnownPlaceStore.change(context: nil) { $0.rememberNotTrip(name: place.name, centre: place.centre, now: .now) }
            message += " " + String(localized: "Visits to \(place.name) are no trip from now on.")
            placeBook = KnownPlaceStore.book()
        }
        post(TripNotice(message: message, undo: session.undo, placesBefore: placesBefore))
        if let chapterID {
            withAnimation(Motion.animation(Motion.settle, reduceMotion: reduceMotion)) {
                selection.openTripID = chapterID
            }
        }
    }

    // MARK: Lookups

    /// Other trips, nearest in time first, for "Merge with".
    private func mergeCandidates(for trip: TimelineTrip) -> [TripLink] {
        guard !trip.isUnsorted else { return [] }
        let anchor = trip.startDate ?? .distantPast
        guard tripByID[trip.id] != nil else { return [] }
        return allChapters
            .filter { !$0.isUnsorted && $0.id != trip.id && tripByID[$0.id] != nil }
            .sorted { abs(($0.startDate ?? .distantPast).timeIntervalSince(anchor)) < abs(($1.startDate ?? .distantPast).timeIntervalSince(anchor)) }
            .prefix(8)
            .map { TripLink(id: $0.id, name: TripText.name($0)) }
    }

    /// Photos in no trip from the three days before and after the trip, by day.
    private func daysAround(_ trip: TimelineTrip) -> [TripNearbyDay] {
        guard !trip.isUnsorted, let start = trip.startDate ?? trip.orderedItems.compactMap(\.date).min() else { return [] }
        let end = trip.endDate ?? start
        let calendar = Calendar.autoupdatingCurrent
        guard let from = calendar.date(byAdding: .day, value: -3, to: calendar.startOfDay(for: start)),
              let to = calendar.date(byAdding: .day, value: 4, to: calendar.startOfDay(for: end)) else { return [] }
        let first = calendar.startOfDay(for: start)
        let last = TripEdits.endOfDay(end, calendar: calendar)
        var byDay: [Date: [MediaItem]] = [:]
        // Around a trip: photos in no trip. Around another chapter: photos not in it.
        let isTrip = tripByID[trip.id] != nil
        let inside = Set(trip.orderedItems.map(\.id))
        for item in items where isTrip ? (item.trip == nil && item.tripID == nil) : !inside.contains(item.id) {
            guard let date = item.effectiveCaptureDate, date.isOnOrAfter(from), date < to, date < first || date > last else { continue }
            byDay[calendar.startOfDay(for: date), default: []].append(item)
        }
        return byDay.keys.sorted().map { day in
            let photos = byDay[day, default: []].sorted { ($0.effectiveCaptureDate ?? .distantPast) < ($1.effectiveCaptureDate ?? .distantPast) }
            return TripNearbyDay(date: day, isBefore: day < first, itemIDs: photos.map(\.id))
        }
    }
}

/// What the Trips pages can change, handed down to the views that offer it.
struct TripActions {
    var changeDates: (ChapterTarget, Date, Date) -> Void
    /// Gathers the photos once and returns what given dates would do.
    var makePreview: (ChapterTarget) -> (Date, Date) -> TripEdits.Plan
    var addPhotos: ([String], ChapterTarget) -> Void
    /// Days by their `yyyy-MM-dd` key, as the page groups them.
    var removeDay: (String, ChapterTarget) -> Void
    var split: (String, Trip) -> Void
    /// The first trip merges into the second.
    var merge: (Trip, Trip) -> Void
    var delete: (ChapterTarget) -> Void
    var rename: (ChapterTarget, String) -> Void
    /// Opens "This is not a trip" for the trip.
    var notTrip: (Trip) -> Void
    var setCover: (String, String) -> Void
    /// What the chapter judge says about a trip, while it shows a kind.
    var judged: (String) -> ChapterJudgeState?
    /// The person picked the trip's kind.
    var setKind: (Trip, ChapterKind) -> Void
    /// The person said the judge's kind is right.
    var confirmKind: (Trip) -> Void
}

/// A trip's kind as the chapter judge left it, for its page.
struct ChapterJudgeState {
    let kind: ChapterKind
    let verdict: ChapterVerdict
    let action: JudgeAction?
    let showsCheck: Bool
    /// The other kinds to change to, ordinary days last.
    let choices: [ChapterKind]
}

/// The stored chapter behind a card or page: a trip, or another kind.
enum ChapterTarget {
    case trip(Trip)
    case group(UserGroup)

    var type: ChapterType {
        switch self {
        // A trip shows what the chapter judge called it, once it is sure
        // enough or the person said so.
        case let .trip(trip): ChapterJudgeStore.shownType(for: trip.id) ?? .trip
        case let .group(group): group.chapterType
        }
    }

    var symbol: String {
        switch self {
        case .trip: type.defaultSymbol
        case let .group(group): group.chapterSymbol
        }
    }

    var name: String {
        switch self {
        case let .trip(trip): trip.effectiveName
        case let .group(group): group.name
        }
    }

    var startDate: Date? {
        switch self {
        case let .trip(trip): trip.startDate
        case let .group(group): group.chapterInfo.startDate
        }
    }

    var endDate: Date? {
        switch self {
        case let .trip(trip): trip.endDate
        case let .group(group): group.chapterInfo.endDate
        }
    }

    var trip: Trip? {
        if case let .trip(trip) = self { return trip }
        return nil
    }
}

/// The last change to a trip, with its Undo and sometimes a question.
struct TripNotice: Identifiable {
    struct Offer {
        let tripID: String
        let text: String
        let itemIDs: [String]
    }

    let id = UUID()
    let message: String
    let undo: TripEdits.Undo
    var offer: Offer?
    /// The places as they were, when the change also named a place.
    var placesBefore: KnownPlaceBook?
    /// What Undo changes in the chapter judge's book, when the judge or an
    /// answer to it removed the chapters.
    var judgeUndo: ChapterJudgeUndo?
}

/// Undo for the chapter judge: only the chapters the change was about, so
/// later answers about other chapters stay.
enum ChapterJudgeUndo {
    /// Chapters the judge removed come back as questions.
    case ask([String])
    /// The person's answer is taken back.
    case restore(ChapterJudgeBook.Entries)

    @MainActor
    @discardableResult
    func apply() -> ChapterJudgeBook {
        ChapterJudgeStore.change { book in
            switch self {
            case let .ask(ids): book.askInstead(ids)
            case let .restore(entries): book.restore(entries)
            }
        }
    }
}

/// A trip someone said is not a trip, with what the sheet shows.
struct NotTripRequest: Identifiable {
    let trip: Trip
    let summary: String
    /// Where its photos were taken, if they have locations.
    let place: (name: String, centre: GeoPoint)?

    var id: String { trip.id }
    var name: String { trip.effectiveName }
}

/// Photos in no trip from one day just before or after a trip.
struct TripNearbyDay: Identifiable {
    let date: Date
    let isBefore: Bool
    let itemIDs: [String]
    var id: Date { date }
}

/// A slim bar at the bottom of the page: what changed, Undo, and when
/// photos of other trips fall in the new dates, the offer to move them.
private struct TripNoticeBar: View {
    let notice: TripNotice
    let onUndo: () -> Void
    let onAdopt: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Paper.accent)
                Text(notice.message)
                    .foregroundStyle(Paper.ink)
                    .lineLimit(2)
                    .accessibilityIdentifier("trips.notice")
                Spacer(minLength: 8)
                Button(String(localized: "Undo"), action: onUndo)
                    .accessibilityIdentifier("trips.notice.undo")
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Paper.muted)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Close"))
                .accessibilityLabel(String(localized: "Close"))
            }
            if let offer = notice.offer {
                HStack(spacing: 12) {
                    Text(offer.text)
                        .font(.callout)
                        .foregroundStyle(Paper.muted)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Button(String(localized: "Move them here"), action: onAdopt)
                        .accessibilityIdentifier("trips.notice.adopt")
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(maxWidth: 560)
        .background(Paper.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: Paper.shadow.opacity(0.06), radius: 1, y: 1)
        .shadow(color: Paper.shadow.opacity(0.12), radius: 14, y: 5)
        .padding(.horizontal, 16)
    }
}

// MARK: - Shelf

/// Which chapters the shelf shows while a Library filter or search is on.
enum ChapterShelfFilter {
    /// The chapters with at least one photo in `ids`; every chapter for `nil`.
    static func chapters(_ trips: [TimelineTrip], passing ids: Set<String>?) -> [TimelineTrip] {
        guard let ids else { return trips }
        return trips.filter { (trip: TimelineTrip) -> Bool in
            trip.orderedItems.contains { (item: TimelineItemSnapshot) -> Bool in ids.contains(item.id) }
        }
    }
}

private struct TripShelfView: View {
    let trips: [TimelineTrip]
    let target: (String) -> ChapterTarget?
    let itemByID: [String: MediaItem]
    let covers: [String: String]
    let memories: [CollectionMemory]
    let returnTripID: String?
    let actions: TripActions
    let onOpen: (TimelineTrip) -> Void
    let onNew: () -> Void
    @Environment(SelectionModel.self) private var selection
    @Environment(LibraryStore.self) private var store
    @Query(sort: \Person.name) private var people: [Person]
    /// Who was on each chapter, by its id, worked out once per change to the
    /// chapters, the faces or the names, not by each card.
    @State private var companions: [String: [PeopleStripEntry]] = [:]

    /// At most this many faces on a card.
    static let companionLimit = 5

    private var companionsKey: Int {
        var hasher = Hasher()
        hasher.combine(store.photoFaceRevision)
        hasher.combine(store.refreshCount)
        for trip in trips {
            hasher.combine(trip.id)
            hasher.combine(trip.itemCount)
        }
        for person in people {
            hasher.combine(person.id)
            hasher.combine(person.name)
            hasher.combine(person.hidden)
        }
        return hasher.finalize()
    }

    private var chapterCount: Int { trips.filter { !$0.isUnsorted }.count }

    /// While a Library filter or search is on, only the chapters with a
    /// photo that passes it.
    private var shownTrips: [TimelineTrip] {
        ChapterShelfFilter.chapters(trips, passing: selection.filteredItemIDs)
    }

    var body: some View {
        let shownTrips: [TimelineTrip] = self.shownTrips
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .center, spacing: 18) {
                    // Where the chapters happened, as one small map over
                    // the cards: a stamp opens its chapter, the map itself
                    // the large map of every photo.
                    ChapterFootprints(trips: shownTrips, onOpen: onOpen)
                    if shownTrips.isEmpty && selection.filteredItemIDs != nil {
                        ContentUnavailableView(
                            String(localized: "No matching chapters"),
                            systemImage: "line.3.horizontal.decrease.circle",
                            description: Text(String(localized: "Try changing your filters."))
                        )
                        .padding(.top, 40)
                        .accessibilityIdentifier("trips.noMatches")
                    }
                    // Cards sit straight in the lazy stack so only visible ones
                    // are built.
                    ForEach(shownTrips) { trip in
                        TripCoverCard(
                            trip: trip,
                            target: target(trip.id),
                            covers: covers(for: trip),
                            photos: trip.orderedItems.compactMap { itemByID[$0.id] },
                            memory: memories.first { $0.scope == .trip && $0.scopeKey == trip.id }?.text,
                            companions: companions[trip.id] ?? [],
                            actions: actions,
                            onOpen: { onOpen(trip) }
                        )
                        .id(trip.id)
                        .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, PaperMetrics.screenInset)
                .padding(.top, PaperMetrics.screenTopInset)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.automatic)
            .background(Paper.canvas)
            // The same filters and search as the Library, from a Filter button.
            .compactLibraryFilters()
            .task(id: companionsKey) {
                var sets: [String: Set<String>] = [:]
                for trip in trips where !trip.isUnsorted {
                    sets[trip.id] = Set(trip.orderedItems.map { (item: TimelineItemSnapshot) -> String in item.id })
                }
                companions = PeopleStrip.companions(
                    in: sets,
                    faces: store.faces,
                    people: people,
                    itemsByID: store.itemsByID,
                    limit: Self.companionLimit
                )
            }
            // The page's name lives in the window's title bar, not in the page.
            .navigationTitle(String(localized: "Chapters"))
            .navigationSubtitle(String(localized: "\(chapterCount) chapters"))
            .toolbar {
                // On Chapters, + starts a chapter.
                ToolbarItem(placement: .primaryAction) {
                    Button(action: onNew) {
                        Label(String(localized: "New chapter"), systemImage: "plus")
                    }
                    .help(String(localized: "New chapter"))
                    .accessibilityIdentifier("trips.new")
                }
            }
            // Back sets the card to return to as the shelf appears, in
            // either order.
            .onChange(of: returnTripID) { (_: String?, id: String?) in
                if let id { proxy.scrollTo(id, anchor: .center) }
            }
            .onAppear {
                if let returnTripID { proxy.scrollTo(returnTripID, anchor: .center) }
                #if DEBUG
                // The shelf only shows once its cards are built, so coming
                // back from a chapter shows content as soon as it appears.
                PageProbe.shellReady(token: PageProbe.phaseToken)
                PageProbe.contentReady(token: PageProbe.phaseToken)
                #endif
            }
        }
    }

    /// The chosen cover in front, if it is still in the trip; the usual pair otherwise.
    private func covers(for trip: TimelineTrip) -> [MediaItem] {
        let automatic = trip.covers.compactMap { itemByID[$0.id] }
        guard let chosenID = covers[trip.id],
              trip.orderedItems.contains(where: { $0.id == chosenID }),
              let chosen = itemByID[chosenID] else { return automatic }
        let second = automatic.first { $0.id != chosenID }
        return [chosen] + (second.map { [$0] } ?? [])
    }
}

/// Where the chapters happened: one stamp per chapter that has places, on a
/// small drawn map over the cards. A stamp opens its chapter; the map itself
/// opens the large map of every photo.
private struct ChapterFootprints: View {
    let trips: [TimelineTrip]
    let onOpen: (TimelineTrip) -> Void
    @Environment(SelectionModel.self) private var selection

    static let inset = CGSize(width: 34, height: 26)
    /// More stamps than this would only cover each other.
    static let limit = 40

    private struct Mark: Identifiable {
        let id: String
        let trip: TimelineTrip
        let stop: TripRouteStop
    }

    /// One stamp per chapter, at the middle of its places, newest first.
    private var marks: [Mark] {
        var result: [Mark] = []
        for trip in trips where !trip.isUnsorted {
            let stops: [TripRouteStop] = trip.routeStops
            guard !stops.isEmpty else { continue }
            let latitude: Double = stops.map(\.latitude).reduce(0, +) / Double(stops.count)
            let longitude: Double = stops.map(\.longitude).reduce(0, +) / Double(stops.count)
            result.append(Mark(id: trip.id, trip: trip, stop: TripRouteStop(name: TripText.name(trip), latitude: latitude, longitude: longitude)))
            if result.count == Self.limit { break }
        }
        return result
    }

    var body: some View {
        let marks: [Mark] = self.marks
        if !marks.isEmpty {
            let stops: [TripRouteStop] = marks.map(\.stop)
            Button {
                selection.showMap(title: String(localized: "Map"), itemIDs: nil)
            } label: {
                TripRouteMap(stops: stops, showsRoute: false, inset: Self.inset)
                    .frame(maxWidth: 880)
                    .frame(height: 150)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "Open the map"))
            .accessibilityLabel(String(localized: "Open the map"))
            .accessibilityIdentifier("trips.footprints")
            .overlay {
                GeometryReader { proxy in
                    let box = CGRect(origin: .zero, size: proxy.size).insetBy(dx: Self.inset.width, dy: Self.inset.height)
                    let points: [CGPoint] = TripRouteMap.layout(stops, in: box)
                    ForEach(Array(marks.enumerated()), id: \.element.id) { index, mark in
                        Button { onOpen(mark.trip) } label: {
                            Color.clear
                                .frame(width: 22, height: 22)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(mark.stop.name)
                        .accessibilityLabel(mark.stop.name)
                        .accessibilityIdentifier("trips.footprint.\(mark.id)")
                        .position(points[index])
                    }
                }
            }
        }
    }
}

/// One trip as a card in three parts: two photos laid on each other like
/// prints; the dates, the serif name, the route and the counts; and a small
/// drawn map of the route. One tone lighter than the page, no outline.
/// Narrow windows drop the map first, then shrink the prints.
private struct TripCoverCard: View {
    let trip: TimelineTrip
    let target: ChapterTarget?
    let covers: [MediaItem]
    let photos: [MediaItem]
    let memory: String?
    /// Who was there, as small faces under the counts.
    let companions: [PeopleStripEntry]
    let actions: TripActions
    let onOpen: () -> Void
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(SharingController.self) private var sharing: SharingController?
    @State private var isHovering = false
    @State private var isPickingCover = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 8, style: .continuous) }
    private var stops: [TripRouteStop] { trip.routeStops }
    private var type: ChapterType { target?.type ?? .trip }

    /// Trips and events show where; a celebration its date; other stretches
    /// of time how the photos spread over the days.
    private var hasSideView: Bool {
        if target?.trip != nil { return !stops.isEmpty }
        switch type {
        case .trip, .businessTrip, .homeVisit, .event: return !stops.isEmpty
        case .celebration: return trip.startDate != nil
        case .period, .custom: return trip.itemCount > 0
        }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            content(printScale: 0.8, showsMap: hasSideView)
            content(printScale: 0.8, showsMap: false)
            content(printScale: 0.62, showsMap: false)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: 880, alignment: .leading)
        .background(trip.isUnsorted ? Paper.well.opacity(0.6) : Paper.raised, in: shape)
        .overlay(alignment: .topTrailing) {
            if sharing?.isShared(tripID: trip.id) == true {
                SharedTripBadge().padding(8)
            }
        }
        .contentShape(shape)
        .onTapGesture(perform: onOpen)
        .shadow(color: Paper.shadow.opacity(isHovering ? 0.07 : 0.04), radius: 1, y: 1)
        .shadow(color: Paper.shadow.opacity(isHovering ? 0.08 : 0.03), radius: isHovering ? 12 : 6, y: isHovering ? 4 : 2)
        .onHover { hovering in
            withAnimation(Motion.animation(Motion.settle, reduceMotion: reduceMotion)) { isHovering = hovering }
        }
        .help(String(localized: "Open this trip"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(TripText.name(trip)))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onOpen() }
        .accessibilityIdentifier("trips.card.\(trip.id)")
    }

    private func content(printScale: CGFloat, showsMap: Bool) -> some View {
        HStack(alignment: .top, spacing: 22 * printScale) {
            prints(scale: printScale)

            VStack(alignment: .leading, spacing: 7) {
                if let span = TripText.dateSpan(trip, locale: locale) {
                    dates(span: span)
                }
                Text(TripText.name(trip))
                    .font(.system(size: 22, weight: .medium, design: .serif))
                    .foregroundStyle(Paper.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.bottom, 4)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .stroke(Paper.rule, style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                            .frame(height: 1)
                    }
                    .accessibilityIdentifier("trips.card.name.\(trip.id)")
                if !trip.cityNames.isEmpty {
                    Text(trip.cityNames.joined(separator: " → "))
                        .font(.subheadline)
                        .foregroundStyle(Paper.ink)
                        .lineLimit(2)
                }
                Text(TripText.counts(trip))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Paper.muted)
                    .lineLimit(1)
                CompanionFaces(entries: companions)
                    .padding(.top, 1)
                if let memory {
                    Text(memory)
                        .font(.system(.footnote, design: .serif).italic())
                        .foregroundStyle(Paper.muted)
                        .lineLimit(2)
                        .padding(.top, 2)
                }
            }
            .padding(.top, 4)
            // A fixed ideal width lets ViewThatFits judge by the layout, not by how long the name is.
            .frame(minWidth: 210, idealWidth: 230, maxWidth: .infinity, alignment: .leading)

            if showsMap {
                sideView
                    .frame(width: 200, height: 148 * printScale / 0.8)
            }
        }
    }

    @ViewBuilder
    private var sideView: some View {
        if target?.trip != nil {
            TripRouteMap(stops: stops)
        } else {
            switch type {
            case .trip, .businessTrip, .homeVisit, .event:
                TripRouteMap(stops: stops)
            case .celebration:
                ChapterAnniversary(date: trip.startDate ?? .now)
            case .period, .custom:
                ChapterDensityStrip(trip: trip)
            }
        }
    }

    /// The prints. Each is its own choice: the one behind comes to the
    /// front as the cover; the one in front opens every photo to pick from.
    @ViewBuilder
    private func prints(scale: CGFloat) -> some View {
        if trip.isUnsorted || photos.count < 2 {
            TripPrints(covers: covers, lifted: isHovering, scale: scale)
                .frame(width: 262 * scale, height: 186 * scale)
        } else {
            TripPrints(
                covers: covers,
                lifted: isHovering,
                scale: scale,
                tripID: trip.id,
                onFront: { isPickingCover = true },
                onBack: { (item: MediaItem) in actions.setCover(trip.id, item.id) }
            )
            .frame(width: 262 * scale, height: 186 * scale)
            .popover(isPresented: $isPickingCover, arrowEdge: .trailing) {
                TripCoverPicker(photos: photos, current: covers.first?.id) { item in
                    actions.setCover(trip.id, item.id)
                    isPickingCover = false
                }
            }
        }
    }

    @ViewBuilder
    private func dates(span: String) -> some View {
        let line = HStack(spacing: 6) {
            if type != .trip, let target {
                Label(type.label, systemImage: target.symbol)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(Paper.accent)
                Text(verbatim: "·")
            }
            Text(TripText.dateLine(span: span, trip: trip))
        }
        .font(.footnote)
        .foregroundStyle(Paper.muted)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        if let target {
            TripDatesControl(
                startDate: target.startDate,
                endDate: target.endDate,
                photoDates: trip.orderedItems.compactMap(\.date),
                identifier: "trips.card.dates.\(trip.id)",
                makePreview: { actions.makePreview(target) },
                onApply: { actions.changeDates(target, $0, $1) }
            ) { line }
        } else {
            line
        }
    }
}

/// Every photo of the trip, to pick the one in front.
private struct TripCoverPicker: View {
    let photos: [MediaItem]
    let current: String?
    let onPick: (MediaItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PaperFormLabel(String(localized: "Choose the cover"))
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(76), spacing: 6), count: 4), spacing: 6) {
                    ForEach(photos, id: \.id) { item in
                        Button { onPick(item) } label: {
                            ThumbnailView(item: item, width: 76, height: 76)
                                .frame(width: 76, height: 76)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                .overlay {
                                    if item.id == current {
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .stroke(Paper.accent, lineWidth: 2.5)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(item.title)
                        .accessibilityIdentifier("trips.cover.pick.\(item.id)")
                    }
                }
            }
            .frame(width: 4 * 76 + 3 * 6, height: min(CGFloat((photos.count + 3) / 4) * 82, 330))
        }
        .padding(14)
    }
}

/// Two photos as prints with a white border, the second laid over the first,
/// each turned a little. Hovering the card spreads them slightly apart.
/// Given the actions, each print is a button of its own.
private struct TripPrints: View {
    let covers: [MediaItem]
    let lifted: Bool
    var scale: CGFloat = 1
    var tripID: String? = nil
    /// The print in front was clicked.
    var onFront: (() -> Void)? = nil
    /// The print behind was clicked.
    var onBack: ((MediaItem) -> Void)? = nil

    private var isInteractive: Bool { onFront != nil }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if covers.count > 1 {
                clickable(printed(covers[1]), help: String(localized: "Set as cover"), id: "back", itemID: covers[1].id) { onBack?(covers[1]) }
                    .frame(width: 186 * scale, height: 150 * scale)
                    .rotationEffect(.degrees(lifted ? -4 : -2.5))
                    .offset(x: (lifted ? 0 : 4) * scale, y: (6) * scale)
                clickable(printed(covers[0]), help: String(localized: "Choose the cover"), id: "front", itemID: covers[0].id) { onFront?() }
                    .frame(width: 192 * scale, height: 156 * scale)
                    .rotationEffect(.degrees(lifted ? 2.5 : 1.5))
                    .offset(x: (70) * scale, y: (lifted ? 22 : 24) * scale)
            } else if let only = covers.first {
                clickable(printed(only), help: String(localized: "Choose the cover"), id: "front", itemID: only.id) { onFront?() }
                    .frame(width: 214 * scale, height: 164 * scale)
                    .rotationEffect(.degrees(-1.5))
                    .offset(x: (22) * scale, y: (10) * scale)
            } else {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Paper.well)
                    .overlay {
                        Image(systemName: "book.pages")
                            .font(.title2)
                            .foregroundStyle(Paper.muted)
                    }
                    .frame(width: 214 * scale, height: 164 * scale)
                    .offset(x: (22) * scale, y: (10) * scale)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: isInteractive ? .contain : .ignore)
        .accessibilityHidden(!isInteractive)
        .accessibilityIdentifier(tripID.map { "trips.cover.\($0)" } ?? "")
    }

    /// A print as a button when the card can change its cover; as it is
    /// otherwise.
    @ViewBuilder
    private func clickable(_ print: some View, help: String, id: String, itemID: String, action: @escaping () -> Void) -> some View {
        if isInteractive, let tripID {
            Button(action: action) { print.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help(help)
                .accessibilityLabel(help)
                .accessibilityValue(itemID)
                .accessibilityIdentifier("trips.cover.\(id).\(tripID)")
        } else {
            print
        }
    }

    private func printed(_ item: MediaItem) -> some View {
        ThumbnailView(item: item, width: 400, height: 320)
            .clipShape(Rectangle())
            .padding(6)
            .background(Color(red: 0.998, green: 0.996, blue: 0.992))
            .shadow(color: Paper.shadow.opacity(0.10), radius: 1, y: 1)
            .shadow(color: Paper.shadow.opacity(0.12), radius: 6, y: 3)
    }
}

// MARK: - One trip

private struct TripDetailView: View {
    let trip: TimelineTrip
    /// The stored chapter, for changing it; `nil` for photos in no trip.
    let target: ChapterTarget?
    let otherTrips: [TripLink]
    let around: [TripNearbyDay]
    let itemByID: [String: MediaItem]
    let memories: [CollectionMemory]
    let actions: TripActions
    @Environment(SelectionModel.self) private var selection
    @Environment(SharingController.self) private var sharing: SharingController?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.locale) private var locale

    /// Day numbers count dated days only, from the trip's first day.
    private var dayNumbers: [String: Int] {
        var numbers: [String: Int] = [:]
        var next = 1
        for day in trip.days where day.date != nil {
            numbers[day.id] = next
            next += 1
        }
        return numbers
    }

    private var firstDatedDayID: String? { trip.days.first { $0.date != nil }?.id }

    private var model: Trip? { target?.trip }

    /// A long chapter, like a summer, gets a heading at each new month.
    private var monthStarts: Set<String> {
        guard trip.datedDayCount > 45 else { return [] }
        var starts: Set<String> = []
        var previous: String?
        for day in trip.days {
            guard let key = day.memoryKey else { continue }
            let month = String(key.prefix(7))
            if month != previous { starts.insert(day.id) }
            previous = month
        }
        return starts
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    // The trip's name is in the title bar; its dates lead the page
                    // and change when clicked.
                    if let span = TripText.dateSpan(trip, locale: locale) {
                        let heading = HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(span)
                                .font(.system(size: 21, weight: .medium, design: .serif))
                                .foregroundStyle(Paper.ink)
                            if target != nil {
                                Image(systemName: "calendar")
                                    .font(.callout)
                                    .foregroundStyle(Paper.accent)
                            }
                        }
                        if let target {
                            TripDatesControl(
                                startDate: target.startDate,
                                endDate: target.endDate,
                                photoDates: trip.orderedItems.compactMap(\.date),
                                identifier: "trips.dates",
                                makePreview: { actions.makePreview(target) },
                                onApply: { actions.changeDates(target, $0, $1) }
                            ) { heading }
                        } else {
                            heading
                        }
                    }
                    HStack(spacing: 8) {
                        Text(TripText.summary(trip))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Paper.muted)
                            #if DEBUG
                            .onAppear { PageProbe.contentReady(token: PageProbe.phaseToken) }
                            #endif
                        if let model, let judged = actions.judged(model.id) {
                            ChapterKindTag(kind: judged.kind, verdict: judged.verdict, action: judged.action, choices: judged.choices) {
                                actions.setKind(model, $0)
                            }
                        }
                    }
                    if let model, let judged = actions.judged(model.id), judged.showsCheck {
                        ChapterCheckBar(
                            kind: judged.kind,
                            verdict: judged.verdict,
                            choices: judged.choices,
                            onRight: { actions.confirmKind(model) },
                            onChange: { actions.setKind(model, $0) }
                        )
                        .frame(maxWidth: 640, alignment: .leading)
                    }
                    if !trip.cityNames.isEmpty {
                        Text(trip.cityNames.joined(separator: " → "))
                            .font(.callout)
                            .foregroundStyle(Paper.ink)
                    }
                    // Who is in these photos; a face opens that person's photos.
                    ChapterPeopleRow(itemIDs: Set(trip.orderedItems.map(\.id)), stackSpacing: 10)
                    if !trip.isUnsorted {
                        TripMemoryLines(
                            scope: .trip,
                            key: trip.id,
                            memories: memories.filter { $0.scope == .trip && $0.scopeKey == trip.id },
                            prompt: String(localized: "Write about this trip…"),
                            identifier: "trips.memory.trip"
                        )
                        .frame(maxWidth: 640, alignment: .leading)
                        .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // The route, drawn small; a click opens the large map with
                // this chapter's photos.
                if !trip.routeStops.isEmpty {
                    Button {
                        selection.showMap(title: TripText.name(trip), itemIDs: Set(trip.orderedItems.map(\.id)))
                    } label: {
                        TripRouteMap(stops: trip.routeStops)
                            .frame(width: 220, height: 150)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Open the map"))
                    .accessibilityLabel(String(localized: "Open the map"))
                    .accessibilityIdentifier("trips.map")
                }
                }
                .padding(.bottom, 30)

                LazyVStack(alignment: .leading, spacing: 40) {
                    ForEach(trip.days) { day in
                        if monthStarts.contains(day.id), let date = day.date {
                            Text(date, format: .dateTime.month(.wide).year().locale(locale))
                                .font(.caption.weight(.semibold))
                                .textCase(.uppercase)
                                .foregroundStyle(Paper.muted)
                                .padding(.bottom, -24)
                        }
                        TripDaySection(
                            day: day,
                            number: dayNumbers[day.id],
                            memories: day.memoryKey.map { key in
                                memories.filter { $0.scope != .trip && $0.scopeKey == key }
                            } ?? [],
                            itemByID: itemByID,
                            onOpen: open,
                            dayActions: dayActions(for: day)
                        )
                    }
                }

                if let target, !around.isEmpty {
                    TripAroundSection(days: around, isTrip: model != nil, itemByID: itemByID) { day in
                        actions.addPhotos(day.itemIDs, target)
                    }
                    .padding(.top, 48)
                }
            }
            .padding(.horizontal, PaperMetrics.screenInset)
            .padding(.top, PaperMetrics.screenTopInset)
            .padding(.bottom, 80)
        }
        .scrollIndicators(.automatic)
        .background(Paper.canvas)
        // The title bar holds the trip's name; double-click it to rename.
        .modifier(TripWindowTitle(name: TripText.name(trip), target: target, rename: actions.rename))
        .navigationSubtitle(TripWindowTitle.subtitle(for: target))
        // The window's back button returns to the shelf, or to where the
        // chapter was opened from.
        .toolbar {
            if let model, let sharing, sharing.canOfferSharing {
                ToolbarItem {
                    TripShareButton(tripID: model.id, tripName: TripText.name(trip))
                }
            }
            if let target {
                ToolbarItem {
                    Menu {
                        if let model, !otherTrips.isEmpty {
                            Section(String(localized: "Merge with")) {
                                ForEach(otherTrips) { other in
                                    Button(other.name) { merge(other, into: model) }
                                        .accessibilityIdentifier("trips.merge.\(other.id)")
                                }
                            }
                        }
                        if let model {
                            Button(String(localized: "This is not a trip…")) { actions.notTrip(model) }
                                .accessibilityIdentifier("trips.nottrip")
                            Divider()
                        }
                        Button(String(localized: "Delete this chapter"), role: .destructive) {
                            actions.delete(target)
                        }
                        // The other person's chapter is theirs to delete (issue #28).
                        .disabled(!TripWindowTitle.isRenamable(target))
                        .accessibilityIdentifier("trips.delete")
                    } label: {
                        Label(String(localized: "More"), systemImage: "ellipsis.circle")
                    }
                    .help(String(localized: "Merge or delete"))
                    .accessibilityIdentifier("trips.more")
                }
            }
        }
        #if DEBUG
        .onAppear {
            PageProbe.shellReady(token: PageProbe.phaseToken)
        }
        #endif
    }

    private func dayActions(for day: TimelineDay) -> TripDayActions? {
        guard let target, day.date != nil, let key = day.memoryKey else { return nil }
        return TripDayActions(
            remove: { actions.removeDay(key, target) },
            split: day.id == firstDatedDayID || model == nil ? nil : { if let model { actions.split(key, model) } }
        )
    }

    private func merge(_ link: TripLink, into model: Trip) {
        guard let other = try? modelContext.fetch(FetchDescriptor<Trip>()).first(where: { $0.id == link.id }) else { return }
        actions.merge(other, model)
    }

    /// A photo opens in the large viewer, paging through the whole trip.
    private func open(_ itemID: String) {
        selection.select(itemID)
        selection.openViewer(itemID, in: trip.orderedItems.map(\.id))
    }
}

/// What a day inside a trip offers in its menu.
struct TripDayActions {
    let remove: () -> Void
    /// `nil` on the first day, which cannot start a new trip.
    let split: (() -> Void)?
}

/// The days just before and after the trip whose photos are in no trip,
/// each with a button to add it.
private struct TripAroundSection: View {
    let days: [TripNearbyDay]
    /// Around a trip: photos in no trip. Around another chapter: photos not in it.
    let isTrip: Bool
    let itemByID: [String: MediaItem]
    let onAdd: (TripNearbyDay) -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(isTrip ? LocalizedStringKey("Around this trip") : LocalizedStringKey("Around this chapter"))
                    .font(.system(size: 17, weight: .medium, design: .serif))
                    .foregroundStyle(Paper.ink)
                Text(isTrip ? LocalizedStringKey("Photos from the days just before and after that are in no trip.") : LocalizedStringKey("Photos from the days just before and after."))
                    .font(.caption)
                    .foregroundStyle(Paper.muted)
            }
            ForEach(days) { day in
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(day.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().locale(locale))
                            .font(.callout)
                            .foregroundStyle(Paper.ink)
                        Text(day.isBefore ? String(localized: "chapter.around.before", defaultValue: "Before") : String(localized: "chapter.around.after", defaultValue: "After"))
                            .font(.caption2)
                            .foregroundStyle(Paper.muted)
                    }
                    .frame(width: 92, alignment: .leading)
                    HStack(spacing: 4) {
                        ForEach(day.itemIDs.prefix(6), id: \.self) { id in
                            if let item = itemByID[id] {
                                ThumbnailView(item: item, width: 44, height: 44)
                                    .frame(width: 44, height: 44)
                                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                            }
                        }
                        if day.itemIDs.count > 6 {
                            Text(verbatim: "+\(day.itemIDs.count - 6)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Paper.muted)
                                .padding(.leading, 4)
                        }
                    }
                    .accessibilityHidden(true)
                    Spacer(minLength: 8)
                    Button {
                        onAdd(day)
                    } label: {
                        Label(isTrip ? String(localized: "Add to trip") : String(localized: "Add"), systemImage: "plus")
                    }
                    .accessibilityIdentifier("trips.around.add.\(TripAroundSection.key(day.date))")
                }
                .padding(10)
                .background(Paper.well.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
    }

    static func key(_ date: Date) -> String {
        let parts = Calendar.autoupdatingCurrent.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// One day of a chapter: its heading ("Day 2", or the date), its memory
/// line, then its places and travel.
struct TripDaySection: View {
    let day: TimelineDay
    let number: Int?
    let memories: [CollectionMemory]
    let itemByID: [String: MediaItem]
    let onOpen: (String) -> Void
    /// Inside a trip: take the day out, or start a new trip from it.
    var dayActions: TripDayActions? = nil
    @Environment(\.locale) private var locale

    private var photoCount: Int { day.places.reduce(0) { $0 + $1.photoCount } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let number {
                    Text(String(localized: "Day \(number)"))
                        .font(.system(size: 21, weight: .medium, design: .serif))
                        .foregroundStyle(Paper.ink)
                    if let date = day.date {
                        Text(date, format: .dateTime.weekday(.wide).month(.wide).day().year().locale(locale))
                            .font(.caption)
                            .foregroundStyle(Paper.muted)
                    }
                } else if let date = day.date {
                    Text(date, format: .dateTime.weekday(.wide).month(.wide).day().locale(locale))
                        .font(.system(size: 21, weight: .medium, design: .serif))
                        .foregroundStyle(Paper.ink)
                    Text(date, format: .dateTime.year().locale(locale))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Paper.muted)
                } else {
                    Text("Date to add")
                        .font(.system(size: 21, weight: .medium, design: .serif))
                        .foregroundStyle(Paper.muted)
                }
                Spacer()
                Text(String(localized: "\(photoCount) photos"))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Paper.muted)
                if let dayActions {
                    Menu {
                        Button(String(localized: "Take this day out of the trip"), action: dayActions.remove)
                        if let split = dayActions.split {
                            Button(String(localized: "Start a new trip from this day"), action: split)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(Paper.muted)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(String(localized: "Change this day"))
                    .accessibilityLabel(String(localized: "Change this day"))
                    .accessibilityIdentifier("trips.day.menu.\(day.memoryKey ?? day.id)")
                }
            }

            if let key = day.memoryKey {
                TripMemoryLines(
                    scope: .day,
                    key: key,
                    memories: memories,
                    prompt: String(localized: "Write about this day…"),
                    identifier: "trips.memory.day.\(key)"
                )
                .frame(maxWidth: 640, alignment: .leading)
            }

            ForEach(day.events) { event in
                switch event {
                case let .place(place):
                    TripPlaceBlock(place: place, itemByID: itemByID, onOpen: onOpen)
                case let .travel(travel):
                    TripTravelRow(travel: travel)
                }
            }
        }
    }
}

struct TripPlaceBlock: View {
    let place: TimelinePlace
    let itemByID: [String: MediaItem]
    let onOpen: (String) -> Void
    @Environment(SelectionModel.self) private var selection
    @Environment(PhotoStackModel.self) private var stacks
    @Environment(\.locale) private var locale
    @AppStorage(AuthorNames.myNameKey) private var myName = ""
    @AppStorage(AuthorNames.partnerNameKey) private var partnerName = ""

    private let columns = [GridItem(.adaptive(minimum: 128, maximum: 200), spacing: 8, alignment: .top)]

    /// A burst shows once, as a stack with its cover.
    private var shownItems: [(item: TimelineItemSnapshot, count: Int)] {
        let byID = Dictionary(place.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return stacks.collapse(place.items.map(\.id)).compactMap { entry in
            byID[entry.id].map { ($0, entry.isStack ? entry.count : 1) }
        }
    }

    private var placeName: String { place.name ?? String(localized: "Unknown place") }

    /// Both people's memories on the photos at this place.
    private var photoMemories: [TimelineMemorySnippet] {
        place.items.flatMap(\.memories).filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "mappin")
                    .font(.caption)
                    .foregroundStyle(Paper.accent)
                // The place's name lists its photos on their own in the Library.
                Button {
                    selection.showInLibrary(place.itemIDs, title: placeName)
                } label: {
                    Text(placeName)
                        .font(.headline)
                        .foregroundStyle(Paper.ink)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Show these photos in the Library"))
                .accessibilityIdentifier("trips.place.\(place.id)")
                if let city = place.cityName, city != place.name {
                    Text(city)
                        .font(.caption)
                        .foregroundStyle(Paper.muted)
                }
                Spacer(minLength: 8)
                if let date = place.date {
                    Text(date, format: .dateTime.hour().minute().locale(locale))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Paper.muted)
                }
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(shownItems, id: \.item.id) { shown in
                    let item = shown.item
                    Button { onOpen(item.id) } label: {
                        thumbnail(for: item, stackCount: shown.count)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Open photo"))
                    .accessibilityLabel(item.title.isEmpty ? item.id : item.title)
                    .accessibilityIdentifier("trips.photo.\(item.id)")
                    // Outside the button, so the count is its own element.
                    .overlay(alignment: .bottomTrailing) {
                        if shown.count > 1 {
                            StackCountBadge(count: shown.count)
                                .accessibilityIdentifier("trips.stack.\(item.id)")
                                .allowsHitTesting(false)
                        }
                    }
                }
            }

            if !photoMemories.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    // Once someone else wrote here, each line says whose it is.
                    let showsNames = photoMemories.contains { !$0.isOwn }
                    ForEach(photoMemories) { memory in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(memory.text)
                                .font(.system(.callout, design: .serif))
                                .foregroundStyle(Paper.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            if showsNames {
                                Text(verbatim: "— \(AuthorNames.label(isOwn: memory.isOwn, myName: myName, partnerName: partnerName))")
                                    .font(.caption)
                                    .foregroundStyle(Paper.accent)
                            }
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private func thumbnail(for item: TimelineItemSnapshot, stackCount: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let selected = selection.isSelected(item.id)
        return Group {
            if let media = itemByID[item.id] {
                ThumbnailView(item: media, width: 400, height: 300)
            } else {
                shape.fill(Paper.well)
            }
        }
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
        .clipShape(shape)
        // Rows here are close together: thin edges, like the dense Library grid.
        .stackedPaper(stackCount, isCompact: true, cornerRadius: 10)
        .overlay(shape.strokeBorder(Paper.accent.opacity(selected ? 0.85 : 0), lineWidth: 2))
        .overlay(alignment: .bottomLeading) {
            if item.kindRaw == MediaKind.video.rawValue {
                Image(systemName: "video.fill")
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 2)
                    .padding(6)
            }
        }
        .contentShape(shape)
    }
}

struct TripTravelRow: View {
    let travel: TimelineTravel
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "arrow.triangle.swap")
                .foregroundStyle(Paper.accent)
            Text(travel.fromName ?? String(localized: "Unknown place"))
            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(Paper.muted)
            Text(travel.toName ?? String(localized: "Unknown place"))
            Spacer(minLength: 8)
            Text(distanceLabel(travel.distanceMeters))
                .font(.caption.monospacedDigit())
        }
        .font(.caption)
        .foregroundStyle(Paper.muted)
        .paperWell(cornerRadius: 9, padding: 9)
        .accessibilityElement(children: .combine)
    }

    private func distanceLabel(_ meters: Double) -> String {
        let formatter = MeasurementFormatter()
        formatter.locale = locale
        formatter.unitStyle = .short
        formatter.unitOptions = .naturalScale
        return formatter.string(from: Measurement(value: meters, unit: UnitLength.meters))
    }
}

/// The trip's dates, shown as the label and changed in a popover: pick a
/// start and an end, see which photos would join or leave, then Apply.
/// Nothing changes until Apply; Escape or clicking away cancels.
private struct TripDatesControl<Content: View>: View {
    let startDate: Date?
    let endDate: Date?
    let photoDates: [Date]
    let identifier: String
    let makePreview: () -> (Date, Date) -> TripEdits.Plan
    let onApply: (Date, Date) -> Void
    @ViewBuilder let label: () -> Content
    @State private var isEditing = false
    @State private var start = Date.now
    @State private var end = Date.now
    /// Made when the popover opens, so the preview follows the pickers cheaply.
    @State private var preview: ((Date, Date) -> TripEdits.Plan)?

    var body: some View {
        Button {
            start = startDate ?? photoDates.min() ?? .now
            end = endDate ?? photoDates.max() ?? start
            preview = makePreview()
            isEditing = true
        } label: {
            label().contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "Change the dates"))
        .accessibilityIdentifier(identifier)
        .popover(isPresented: $isEditing, arrowEdge: .bottom) {
            popover
        }
    }

    private var calendar: Calendar { .current }

    private var isUnchanged: Bool {
        guard let current = startDate, let currentEnd = endDate else { return false }
        return calendar.isDate(current, inSameDayAs: start) && calendar.isDate(currentEnd, inSameDayAs: end)
    }

    private var popover: some View {
        let plan = preview?(start, max(start, end)) ?? TripEdits.Plan()
        let elsewhere = plan.elsewhere.values.reduce(0) { $0 + $1.count }
        return VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    PaperFormLabel(String(localized: "Starts"))
                    DatePicker("", selection: $start, displayedComponents: .date)
                        .labelsHidden()
                        .accessibilityIdentifier("trips.dates.start")
                }
                GridRow {
                    PaperFormLabel(String(localized: "Ends"))
                    DatePicker("", selection: $end, in: start..., displayedComponents: .date)
                        .labelsHidden()
                        .accessibilityIdentifier("trips.dates.end")
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                if plan.joining.isEmpty && plan.leaving.isEmpty {
                    Text("No photos change")
                } else {
                    Text(String(localized: "Will add \(plan.joining.count) · will take out \(plan.leaving.count)"))
                }
                if elsewhere > 0 {
                    Text(String(localized: "\(elsewhere) in other trips stay there"))
                        .foregroundStyle(Paper.muted)
                }
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(Paper.ink)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("trips.dates.preview")
            HStack {
                Button(String(localized: "Use photo dates")) {
                    if let first = photoDates.min(), let last = photoDates.max() {
                        start = first
                        end = last
                    }
                }
                .disabled(photoDates.isEmpty)
                Spacer(minLength: 16)
                Button(String(localized: "Cancel")) { isEditing = false }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Apply")) {
                    isEditing = false
                    onApply(start, max(start, end))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isUnchanged)
                .accessibilityIdentifier("trips.dates.apply")
            }
        }
        .padding(16)
        .frame(minWidth: 320)
    }
}

/// The window title is the trip's name, editable in place like a document
/// title; photos in no trip get a plain title.
private struct TripWindowTitle: ViewModifier {
    let name: String
    let target: ChapterTarget?
    let rename: (ChapterTarget, String) -> Void

    func body(content: Content) -> some View {
        if let target, Self.isRenamable(target) {
            content.navigationTitle(Binding(
                get: { name },
                set: { rename(target, $0) }
            ))
        } else {
            content.navigationTitle(name)
        }
    }

    /// A chapter the other person made is theirs to rename (issue #28).
    static func isRenamable(_ target: ChapterTarget) -> Bool {
        if case let .group(group) = target { return UserGroupRuleEngine.canEdit(group) }
        return true
    }

    /// Under the title: the kind of chapter, or, on the other person's
    /// chapter, that only they can rename it.
    static func subtitle(for target: ChapterTarget?) -> String {
        guard let target else { return String(localized: "Chapters") }
        guard isRenamable(target) else {
            return String(localized: "\(AuthorNames.label(isOwn: false)) made this chapter; only they can rename it")
        }
        return target.type.label
    }
}

/// A trip a Timeline day belongs to.
struct TripLink: Identifiable, Hashable {
    let id: String
    let name: String
}

// MARK: - Text

private enum TripText {
    static func name(_ trip: TimelineTrip) -> String {
        if trip.isUnsorted || trip.name == "Unsorted memories" { return String(localized: "Not in a trip") }
        return trip.name
    }

    static func dateSpan(_ trip: TimelineTrip, locale: Locale) -> String? {
        guard let start = trip.startDate ?? trip.orderedItems.compactMap(\.date).min() else { return nil }
        let formatter = DateIntervalFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: start, to: max(trip.endDate ?? start, start))
    }

    /// "Apr 20 – 25, 2026 · 6 days"
    static func dateLine(span: String, trip: TimelineTrip) -> String {
        let days = dayCount(trip)
        guard days > 0 else { return span }
        return "\(span) · \(String(localized: "\(days) days"))"
    }

    /// Calendar days from the trip's start to its end, both included.
    static func dayCount(_ trip: TimelineTrip, calendar: Calendar = .current) -> Int {
        guard let start = trip.startDate, let end = trip.endDate else { return trip.datedDayCount }
        let from = calendar.startOfDay(for: start)
        let to = calendar.startOfDay(for: max(start, end))
        return (calendar.dateComponents([.day], from: from, to: to).day ?? 0) + 1
    }

    /// "128 photos · 156 videos"; videos only when there are any.
    static func counts(_ trip: TimelineTrip) -> String {
        let videos = trip.videoCount
        let photos = String(localized: "\(trip.itemCount - videos) photos")
        guard videos > 0 else { return photos }
        return "\(photos) · \(String(localized: "\(videos) videos"))"
    }

    /// "4 days · 6 places · 38 photos"; parts that are zero are left out.
    static func summary(_ trip: TimelineTrip) -> String {
        var parts: [String] = []
        if trip.datedDayCount > 0 { parts.append(String(localized: "\(trip.datedDayCount) days")) }
        if trip.placeCount > 0 { parts.append(String(localized: "\(trip.placeCount) places")) }
        parts.append(String(localized: "\(trip.itemCount) photos"))
        return parts.joined(separator: " · ")
    }
}
