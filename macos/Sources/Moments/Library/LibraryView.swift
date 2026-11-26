import AppKit
import Foundation
import SwiftUI
import SwiftData

private enum LibraryScrollTarget {
    static func section(_ id: String) -> String { "section:\(id)" }
    static func item(_ id: String) -> String { "item:\(id)" }
}

#if DEBUG
/// The part names and values `groupingKey` was last built from, so the probe
/// can say which input moved. Main-actor only: it is read and written from the
/// library's `.task`.
@MainActor
private enum LibraryRegroupProbe {
    static var last: [String: Int] = [:]
}

#endif
struct LibraryView: View {
    @Environment(SelectionModel.self) private var selection
    @Environment(ImportController.self) private var importController
    @Environment(PhotoStackModel.self) private var stacks
    @Environment(LibraryStore.self) private var store
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // The library's photos, screenshots, faces and places come from the shared
    // store, which fetches them once for every page.
    private var regularItems: [MediaItem] { store.regularItems }
    private var screenshotItems: [MediaItem] { store.screenshotItems }
    @Query(sort: \Memory.updatedAt)
    private var memoryRecords: [Memory]
    @Query(sort: \Trip.id)
    private var allTrips: [Trip]
    private var allPlaces: [Place] { store.places }
    @Query(sort: \PlaceOverride.id)
    private var placeOverrides: [PlaceOverride]
    @Query(sort: \Person.name) private var people: [Person]
    private var faceObservations: [FaceObservation] { store.faces }
    /// What someone changed about bursts: covers, unstacked, photos taken out.
    @Query(filter: #Predicate<UserGroup> { $0.kindRaw == "stack" }) private var stackRecords: [UserGroup]
    /// The place notes every section's photos show, queried once here
    /// instead of by each section on screen.
    @Query private var placeNotes: [PlaceNote]
    /// Day and trip memories, shown under the sections that match them.
    @Query(sort: \CollectionMemory.createdAt) private var collectionMemories: [CollectionMemory]

    let state: LibraryViewState
    @Binding var firstLaunchCompleted: Bool

    /// The search field is the one thing typed to find photos; people and
    /// places are clicked where they show.
    @AppStorage(LibraryFilterKeys.query) private var query = ""

    @State private var cachedSections: [LibrarySection] = []
    /// Each section's photos before stacks were folded.
    @State private var cachedUnfoldedSectionItems: [String: [String]] = [:]
    /// Photos behind each stacked cell, by the id the cell shows.
    @State private var cachedStackCounts: [String: Int] = [:]
    @State private var cachedItemByID: [String: MediaItem] = [:]
    @State private var cachedVisibleCount = 0
    @State private var hasGrouped = false
    @State private var cachedPersonIndex: [String: Set<String>] = [:]
    /// Each section's day-memory keys, built once with the sections.
    @State private var cachedSectionDayKeys: [String: Set<String>] = [:]
    /// Each section's photos, looked up once per regroup instead of on every redraw.
    @State private var cachedSectionItems: [String: [MediaItem]] = [:]
    /// Each section's memories, worked out in `regroup()` with those day keys,
    /// and again only when the memories themselves change, instead of by every
    /// section on each render.
    @State private var cachedSectionMemories: [String: [CollectionMemory]] = [:]

    /// What one full `regroup()` computes from its inputs, as plain values, so
    /// a later visit can show the same result without walking the photos again.
    private struct LibraryRegroupResult {
        let personIndex: [String: Set<String>]
        let itemByID: [String: MediaItem]
        let sections: [LibrarySection]
        let unfoldedSectionItems: [String: [String]]
        let stackCounts: [String: Int]
        let visibleCount: Int
        let gridSections: [[String]]
        let viewerItemIDs: [String]
        let sectionItems: [String: [MediaItem]]
        let sectionDayKeys: [String: Set<String>]
        let publishedIDs: Set<String>
        /// The ids of `filtered`, for the focused-id check on the hit path.
        let filteredIDs: Set<String>
    }

    /// The last finished regroup, kept across visits to the page: SwiftUI drops
    /// the page's `@State` when it is left, but what it built stays valid as
    /// long as `groupingKey` is unchanged.
    @MainActor private static var lastRegroup: (key: Int, result: LibraryRegroupResult)?

    init(state: LibraryViewState, firstLaunchCompleted: Binding<Bool> = .constant(true)) {
        self.state = state
        self._firstLaunchCompleted = firstLaunchCompleted
    }

    private var criteria: LibraryFilterCriteria {
        LibraryFilterCriteria(searchText: query)
    }

    /// Screenshots are imported but stay out of the Library's photos.
    private var items: [MediaItem] { regularItems }

    private var allItems: [MediaItem] {
        regularItems + screenshotItems
    }

    /// What the stack model is handed, without hashing each photo: the
    /// store's running key over exactly the live photos this page passes
    /// (`regularItems + screenshotItems` is `store.items`), and that count.
    private var stackPhotosKey: Int { store.stackFieldsKey }
    private var stackPhotoCount: Int { store.items.count }

    /// One order for everyone: chapters as sections, the other photos by
    /// month, newest first.
    private var grouping: LibraryGrouping { .story }

    /// A stacked cell stands for every photo in its burst, as in Photos.
    private func deletionScope(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.flatMap { id -> [String] in
            if (cachedStackCounts[id] ?? 1) > 1, let stack = stacks.stack(containing: id) { return stack.memberIDs }
            return [id]
        }
        .filter { seen.insert($0).inserted }
    }

    private var personIDsByMediaID: [String: Set<String>] {
        cachedPersonIndex
    }

    /// A lightweight query signature for the cached regroup. Memory presence,
    /// trip/place names, and overrides come from their own queries so this
    /// token never faults `item.memories` for every media item during a render.
    private var groupingKey: Int {
        #if DEBUG
        ScrollProbe.count("library.groupingKey")
        #endif
        var hasher = Hasher()
        hasher.combine(query)
        hasher.combine(state.focusedMemoryItemID)
        hasher.combine(selection.libraryScope?.itemIDs)
        // All photos and faces the pages group by, as one revision.
        hasher.combine(store.photoFaceRevision)
        // A search reads place names and people's names; a save of those
        // alone regroups only then.
        if !query.isEmpty {
            hasher.combine(store.placeRevision)
            for person in people {
                hasher.combine(person.id)
                hasher.combine(person.name)
                hasher.combine(person.hidden)
            }
        }
        for trip in allTrips {
            hasher.combine(trip.id)
            hasher.combine(trip.name)
            hasher.combine(trip.overrideName)
        }
        for override in placeOverrides {
            hasher.combine(override.id)
            hasher.combine(override.mediaID)
            hasher.combine(override.nameOverride)
            hasher.combine(override.updatedAt)
        }
        for memory in memoryRecords {
            hasher.combine(memory.id)
            hasher.combine(memory.mediaID)
            hasher.combine(memory.updatedAt)
            hasher.combine(memory.revision)
        }
        // Bursts regroup when someone changes a stack or new analysis arrives.
        hasher.combine(stacks.generation)
        for record in stackRecords {
            hasher.combine(record.id)
            hasher.combine(record.rulesData)
        }
        return hasher.finalize()
    }

    #if DEBUG
    /// The same inputs `groupingKey` hashes, kept apart by where they come
    /// from, so the page probe can name the one that moved.
    private var groupingKeyParts: [(String, Int)] {
        var filters = Hasher()
        filters.combine(query)
        filters.combine(state.focusedMemoryItemID)
        filters.combine(selection.libraryScope?.itemIDs)
        var trips = Hasher()
        for trip in allTrips {
            trips.combine(trip.id)
            trips.combine(trip.name)
            trips.combine(trip.overrideName)
        }
        var overrides = Hasher()
        for override in placeOverrides {
            overrides.combine(override.id)
            overrides.combine(override.mediaID)
            overrides.combine(override.nameOverride)
            overrides.combine(override.updatedAt)
        }
        var memories = Hasher()
        for memory in memoryRecords {
            memories.combine(memory.id)
            memories.combine(memory.mediaID)
            memories.combine(memory.updatedAt)
            memories.combine(memory.revision)
        }
        var records = Hasher()
        for record in stackRecords {
            records.combine(record.id)
            records.combine(record.rulesData)
        }
        let readsPlaceNames: Bool = !query.isEmpty
        return [
            ("filters", filters.finalize()),
            ("store.photoFaceRevision", store.photoFaceRevision),
            ("store.placeRevision", readsPlaceNames ? store.placeRevision : -1),
            ("trips", trips.finalize()),
            ("place overrides", overrides.finalize()),
            ("memories", memories.finalize()),
            ("stacks.generation", stacks.generation),
            ("stack records", records.finalize())
        ]
    }
    #endif
    /// The memories a section can show, so they are matched again when one is
    /// added, edited or removed outside `regroup()`. The sections and their day
    /// keys are not hashed: `regroup()` does that match itself, in the same
    /// update as the sections, and hashing every section id here repeated that
    /// work on every body evaluation.
    private var memoriesKey: Int {
        var hasher = Hasher()
        hasher.combine(collectionMemories.count)
        for memory in collectionMemories {
            hasher.combine(memory.id)
            hasher.combine(memory.scopeKey)
            hasher.combine(memory.updatedAt)
        }
        return hasher.finalize()
    }

    var body: some View {
        let _ = marqueeCount(15)
        Group {
            if LibraryLaunchState.shouldShowImportFlow(hasCompletedFirstLaunch: firstLaunchCompleted, itemCount: store.items.count) {
                FirstLaunchImportView {
                    importController.chooseFolder()
                }
            } else {
                libraryContent
            }
        }
        .background(LibraryPalette.content)
        #if DEBUG
        // Tests wait here for a folder import to end, on the first-launch
        // screen as well as over the photos.
        .background(alignment: .topTrailing) { ImportFinishedProbe() }
        #endif
        .endsTextEditingOnOutsideClick()
        .onChange(of: store.items.count, initial: true) { _, count in
            if count > 0 { firstLaunchCompleted = true }
        }
        #if DEBUG
        .onAppear {
            PageProbe.shellReady(token: PageProbe.phaseToken)
        }
        #endif
        .task(id: groupingKey) {
            #if DEBUG
            let probeToken = PageProbe.phaseToken
            let parts: [(String, Int)] = groupingKeyParts
            let started: CFTimeInterval = CACurrentMediaTime()
            #endif
            regroup()
            #if DEBUG
            PageProbe.contentReady(token: probeToken)
            let previous: [String: Int] = LibraryRegroupProbe.last
            var changed: [String] = []
            for part in parts where previous[part.0] != part.1 {
                changed.append(part.0)
            }
            if previous.isEmpty { changed = ["first"] }
            var current: [String: Int] = [:]
            for part in parts { current[part.0] = part.1 }
            LibraryRegroupProbe.last = current
            let cause: String = changed.isEmpty ? "no part changed" : changed.joined(separator: " + ")
            PageProbe.tally("library regroup: " + cause, seconds: CACurrentMediaTime() - started)
            #endif
        }
        .onChange(of: memoriesKey) { _, _ in
            // A note can be added or edited without a regroup, so the match is
            // redone here; the first build is covered by regroup() itself.
            let memories: [String: [CollectionMemory]] = LibrarySectionMemories.make(
                sections: cachedSections,
                dayKeysBySection: cachedSectionDayKeys,
                memories: collectionMemories
            )
            applySectionMemories(memories)
        }
    }

    /// The page opens straight on its photos: a row of the people in them,
    /// then the photos, newest chapter first. While it shows only some photos
    /// (a face or a place name was clicked) a heading says whose or where, and
    /// one button goes back to all of them.
    private var libraryContent: some View {
        VStack(spacing: 0) {
            if let scope = selection.libraryScope {
                LibraryScopeHeading(scope: scope, photoCount: cachedVisibleCount)
            }
            ImportStatusView()
                .padding(.horizontal, 34)
                .padding(.vertical, 7)

            if !hasGrouped {
                Spacer()
            } else if cachedSections.isEmpty {
                emptyState
            } else {
                results
            }
        }
        // Tests read the count here; people see it in the title bar.
        .background(alignment: .topLeading) {
            Text(String(cachedVisibleCount))
                .font(.system(size: 1))
                .foregroundStyle(.clear)
                .allowsHitTesting(false)
                .accessibilityValue(String(cachedVisibleCount))
                .accessibilityIdentifier("library.photoCount")
        }
        .background { LibraryPeopleIndexer(state: state) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { LibraryZoomControl(state: state) }
        }
        .searchable(text: $query, placement: .toolbar, prompt: Text(String(localized: "Search people, places, trips, years, notes")))
        .navigationTitle(String(localized: "Library"))
        .modifier(LibrarySelectionSubtitle(idle: String(localized: "\(cachedVisibleCount) photos")))
    }

    @ViewBuilder
    private var results: some View {
        let _ = marqueeCount(3)
        ScrollViewReader { proxy in
            ScrollView {
                // Headings and section grids space themselves (LibrarySectionView).
                LazyVStack(alignment: .leading, spacing: 0) {
                    // The people in these photos, before the photos: it
                    // scrolls away with them. Not while only some photos show.
                    if selection.libraryScope == nil && query.isEmpty {
                        LibraryPeopleStrip(entries: state.peopleEntries)
                    }
                    ForEach(cachedSections) { section in
                        LibrarySectionView(
                            section: section,
                            items: cachedSectionItems[section.id] ?? section.itemIDs.compactMap { cachedItemByID[$0] },
                            state: state,
                            stackCounts: cachedStackCounts,
                            memories: cachedSectionMemories[section.id] ?? [],
                            placeNotes: placeNotes
                        )
                    }
                }
                .reportsLibraryGridColumns(to: state)
                .scrollTargetLayout()
                .padding(.horizontal, 34)
                .padding(.vertical, 24)
                .libraryMarqueeSelection(state: state, selection: selection)
            }
            .scrollIndicators(.visible)
            // The scroll view opens at the section that was at the top when
            // the user left, in its first layout. Scrolling there after
            // onAppear showed the top first and then jumped.
            .scrollPosition(
                // Written only when the top section really changes: the scroll
                // view reports it on every layout, and each write would
                // rebuild the whole Library while the sidebar moves. Not
                // while a rubber band scrolls the grid: each write put the
                // grid back at the heading it had just passed. And never
                // nil (a section's photos at the top), which did the same;
                // the last heading is where the Library opens again.
                id: Binding<String?>(get: { () -> String? in
                    marqueeCount(0)
                    return state.topSectionScrollID
                }, set: { (id: String?) in
                    marqueeCount(1)
                    #if DEBUG
                    MarqueeCounters.note(id ?? "nil")
                    #endif
                    guard let id, !state.marquee.isDragging, state.topSectionScrollID != id else { return }
                    marqueeCount(2)
                    state.topSectionScrollID = id
                }),
                anchor: .top
            )
            .libraryGridInteraction(state: state, proxy: proxy)
            .environment(\.photoDeletionScope, deletionScope)
            .onChange(of: selection.focusedItemID) { _, _ in
                revealRequestedSelectionIfNeeded(in: cachedSections, using: proxy)
            }
            .onChange(of: state.appearedRevealItemID) { _, appeared in
                guard let appeared, appeared == state.pendingRevealItemID else { return }
                // Let the grid finish laying out the card before centring it.
                DispatchQueue.main.async {
                    finishReveal(of: appeared, using: proxy, selection: selection, state: state)
                }
            }
            .onChange(of: selection.shouldRevealSelectionInLibrary) { _, shouldReveal in
                guard shouldReveal else { return }
                revealRequestedSelectionIfNeeded(in: cachedSections, using: proxy)
            }
            .task(id: revealTrigger) {
                guard selection.shouldRevealSelectionInLibrary else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                revealRequestedSelectionIfNeeded(in: cachedSections, using: proxy)
            }
            .onAppear {
                if selection.shouldRevealSelectionInLibrary {
                    revealRequestedSelectionIfNeeded(in: cachedSections, using: proxy)
                }
            }
        }
    }

    private var emptyState: some View {
        let isFiltered = criteria.isFiltered || selection.libraryScope != nil
        return VStack(spacing: 13) {
            ContentUnavailableView(
                isFiltered ? String(localized: "No matching photos") : String(localized: "No photos yet"),
                systemImage: isFiltered ? "magnifyingglass" : "photo.on.rectangle",
                description: Text(isFiltered ? String(localized: "Try other words.") : String(localized: "Add a photo or import a folder to begin."))
            )
            if !isFiltered {
                Button {
                    importController.chooseFolder()
                } label: {
                    Label(String(localized: "Import Folder…"), systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(LibraryPalette.accent)
                .accessibilityIdentifier("library.importFolder")
                Button {
                    NotificationCenter.default.post(name: .momentsShowPhotosImport, object: nil)
                } label: {
                    Label(String(localized: "Import from Apple Photos…"), systemImage: "photo.on.rectangle")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("library.importPhotos")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func regroup() {
        marqueeCount(7)
        // Taken before anything is read: these are the inputs this pass uses,
        // and a change during it must not be stored under a newer key.
        let key = groupingKey
        #if DEBUG
        var stepStarted: CFTimeInterval = CACurrentMediaTime()
        let step: (String) -> Void = { (name: String) -> Void in
            PageProbe.tally("regroup step: " + name, seconds: CACurrentMediaTime() - stepStarted)
            stepStarted = CACurrentMediaTime()
        }
        #endif
        if let cached = Self.lastRegroup, cached.key == key {
            // Nothing changed since the last finished regroup: show it at
            // once, without the filter passes or the sections. What does not
            // come from the cache is rebuilt exactly as the full path does.
            let result = cached.result
            cachedPersonIndex = result.personIndex
            cachedItemByID = result.itemByID
            cachedSections = result.sections
            cachedUnfoldedSectionItems = result.unfoldedSectionItems
            cachedStackCounts = result.stackCounts
            cachedVisibleCount = result.visibleCount
            state.gridSections = result.gridSections
            state.viewerItemIDs = result.viewerItemIDs
            hasGrouped = true
            // The stack model is shared with the other pages, so it is handed
            // the photos again; it does nothing when nothing changed.
            stacks.update(
                items: allItems,
                decisions: stackRecords,
                photosKey: stackPhotosKey,
                photoCount: stackPhotoCount
            )
            cachedSectionItems = result.sectionItems
            if result.sectionDayKeys != cachedSectionDayKeys {
                cachedSectionDayKeys = result.sectionDayKeys
            }
            // Memories are not in the key, so they are matched again.
            let memories: [String: [CollectionMemory]] = LibrarySectionMemories.make(
                sections: result.sections,
                dayKeysBySection: result.sectionDayKeys,
                memories: collectionMemories
            )
            applySectionMemories(memories)
            if selection.visibleItemIDs != result.publishedIDs { selection.visibleItemIDs = result.publishedIDs }
            selection.selectedItemIDs.formIntersection(selection.visibleItemIDs ?? [])
            if let focus = selection.focusedItemID,
               !result.filteredIDs.contains(focus),
               !selection.shouldRevealSelectionInLibrary {
                selection.focusedItemID = selection.selectedItemIDs.first
            }
            #if DEBUG
            PageProbe.tally("regroup step: reused last regroup", seconds: 0)
            #endif
            return
        }
        // `allItems` builds a new array each time it is read.
        let all = allItems
        #if DEBUG
        step("allItems")
        #endif
        let personIndex = UserGroupRuleEngine.makePersonIndex(faceObservations)
        cachedPersonIndex = personIndex
        #if DEBUG
        step("person index")
        #endif
        // A scope from another screen narrows the grid only; the published
        // ids below stay on the regular filters so the maps do not shrink.
        let scopedItems = selection.libraryScope.map { scope in
            items.filter { scope.itemIDs.contains($0.id) }
        } ?? items
        #if DEBUG
        step("scope")
        #endif
        // A search also finds photos by who is in them.
        var searchExtras: [String: [String]] = [:]
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var names: [String: String] = [:]
            for person in people where !person.hidden {
                let name: String = person.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !name.isEmpty { names[person.id] = name }
            }
            if !names.isEmpty {
                for (mediaID, personIDs) in personIndex {
                    let found: [String] = personIDs.compactMap { (id: String) -> String? in names[id] }
                    if !found.isEmpty { searchExtras[mediaID] = found }
                }
            }
        }
        // One call for all three results, so each photo is tested once.
        let passes = LibraryFilterEngine.regroupPasses(
            scopedItems: scopedItems,
            allItems: all,
            hasScope: selection.libraryScope != nil,
            criteria: criteria,
            editingItemID: state.focusedMemoryItemID,
            personIDsByMediaID: personIndex,
            searchExtras: searchExtras
        )
        #if DEBUG
        step("filter passes")
        #endif
        let filtered = passes.filtered
        let visible = passes.visible
        cachedItemByID = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0) })
        #if DEBUG
        step("item by id")
        #endif
        // A burst is one cell showing its cover, and counts as one photo.
        let stackIndex = stacks.update(
            items: all,
            decisions: stackRecords,
            photosKey: stackPhotosKey,
            photoCount: stackPhotoCount
        )
        #if DEBUG
        step("stacks update")
        #endif
        let unfolded = LibraryFilterEngine.sections(forVisibleItems: visible, by: grouping, sortOrder: .newestFirst)
        #if DEBUG
        step("sections")
        #endif
        let folded = LibraryFilterEngine.folding(unfolded, with: stackIndex)
        #if DEBUG
        step("folding")
        #endif
        cachedSections = folded.sections
        cachedUnfoldedSectionItems = Dictionary(unfolded.map { ($0.id, $0.itemIDs) }, uniquingKeysWith: { first, _ in first })
        cachedStackCounts = folded.stackCounts
        cachedVisibleCount = visible.count
        state.gridSections = cachedSections.map(\.itemIDs)
        state.viewerItemIDs = unfolded.flatMap(\.itemIDs)
        hasGrouped = true
        #if DEBUG
        step("publish sections")
        #endif
        // Day memories are matched per section; reading every photo's day in
        // the section's body repeated that pass on each render.
        var sectionDayKeys: [String: Set<String>] = [:]
        sectionDayKeys.reserveCapacity(cachedSections.count)
        var sectionItemsByID: [String: [MediaItem]] = [:]
        sectionItemsByID.reserveCapacity(cachedSections.count)
        for section in cachedSections {
            let sectionItems: [MediaItem] = section.itemIDs.compactMap { cachedItemByID[$0] }
            sectionItemsByID[section.id] = sectionItems
            let keys: Set<String> = Set(sectionItems.compactMap { PhotoNoteDay.key(for: $0) })
            sectionDayKeys[section.id] = keys
        }
        cachedSectionItems = sectionItemsByID
        #if DEBUG
        step("section items + day keys")
        #endif
        // Matched here, with the sections and their day keys, so both caches
        // land in this one update instead of the section list being built
        // again after an onChange sees the new day keys.
        let memories: [String: [CollectionMemory]] = LibrarySectionMemories.make(
            sections: cachedSections,
            dayKeysBySection: sectionDayKeys,
            memories: collectionMemories
        )
        #if DEBUG
        step("memories match")
        #endif
        if sectionDayKeys != cachedSectionDayKeys {
            cachedSectionDayKeys = sectionDayKeys
        }
        applySectionMemories(memories)
        #if DEBUG
        step("apply memories")
        #endif
        let publishedVisible = passes.publishedIDs
        if selection.visibleItemIDs != publishedVisible { selection.visibleItemIDs = publishedVisible }
        selection.selectedItemIDs.formIntersection(selection.visibleItemIDs ?? [])
        if let focus = selection.focusedItemID,
           !filtered.contains(where: { $0.id == focus }),
           !selection.shouldRevealSelectionInLibrary {
            selection.focusedItemID = selection.selectedItemIDs.first
        }
        #if DEBUG
        step("selection")
        #endif
        // Stored last, under the key taken before anything was read, so only a
        // finished regroup is ever reused.
        let result = LibraryRegroupResult(
            personIndex: personIndex,
            itemByID: cachedItemByID,
            sections: cachedSections,
            unfoldedSectionItems: cachedUnfoldedSectionItems,
            stackCounts: cachedStackCounts,
            visibleCount: cachedVisibleCount,
            gridSections: cachedSections.map(\.itemIDs),
            viewerItemIDs: unfolded.flatMap(\.itemIDs),
            sectionItems: sectionItemsByID,
            sectionDayKeys: sectionDayKeys,
            publishedIDs: passes.publishedIDs,
            filteredIDs: Set(filtered.map(\.id))
        )
        Self.lastRegroup = (key: key, result: result)
    }

    /// Writes newly matched section memories, but only when the ids a section
    /// shows differ. A regroup that finds the same memories must not redraw the
    /// section list, which at 20,000 photos is the whole page.
    private func applySectionMemories(_ memories: [String: [CollectionMemory]]) {
        guard !LibrarySectionMemories.sameIDs(cachedSectionMemories, memories) else { return }
        cachedSectionMemories = memories
    }

    private func revealRequestedSelectionIfNeeded(in sections: [LibrarySection], using proxy: ScrollViewProxy) {
        guard selection.shouldRevealSelectionInLibrary,
              let focus = selection.focusedItemID else { return }

        guard let target = sections.first(where: { $0.itemIDs.contains(focus) }) else {
            // A shot inside a stack (Show in Library from the viewer): the
            // stack's cell stands for it.
            if let cell = stacks.stack(containing: focus)?.memberIDs.first(where: { cachedStackCounts[$0] != nil }) {
                selection.select(cell)
            }
            return
        }
        guard state.pendingRevealItemID != focus else { return }
        state.pendingRevealItemID = focus
        state.appearedRevealItemID = nil
        // Bring the section start into view so the lazy grid builds its cards;
        // the card's onAppear then triggers the final centring scroll. The
        // scroll-position binding gets the same section so its restore of
        // the previous position cannot win over the reveal.
        state.topSectionScrollID = LibraryScrollTarget.section(target.id)
        proxy.scrollTo(LibraryScrollTarget.section(target.id), anchor: .top)
        let selectionModel = selection
        let viewState = state
        // Fallback for a card that is already built and so never re-appears.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard viewState.pendingRevealItemID == focus else { return }
            finishReveal(of: focus, using: proxy, selection: selectionModel, state: viewState)
        }
    }

    private func finishReveal(of itemID: String, using proxy: ScrollViewProxy, selection: SelectionModel, state: LibraryViewState) {
        let target = LibraryScrollTarget.item(itemID)
        if reduceMotion {
            proxy.scrollTo(target, anchor: .center)
        } else {
            withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(target, anchor: .center) }
        }
        state.pendingRevealItemID = nil
        state.appearedRevealItemID = nil
        selection.shouldRevealSelectionInLibrary = false
    }

    private var revealTrigger: Int {
        var hasher = Hasher()
        hasher.combine(selection.shouldRevealSelectionInLibrary)
        hasher.combine(selection.focusedItemID)
        for section in cachedSections {
            hasher.combine(section.id)
            for itemID in section.itemIDs {
                hasher.combine(itemID)
            }
        }
        return hasher.finalize()
    }
}

private struct FirstLaunchImportView: View {
    let importAction: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(LibraryPalette.accent)
            Text(String(localized: "Bring your photos into Moments"))
                .font(.system(size: 30, weight: .medium, design: .serif))
                .foregroundStyle(LibraryPalette.ink)
            Text(String(localized: "Import your photos, write a line under any of them, and look back on them trip by trip."))
                .multilineTextAlignment(.center)
                .foregroundStyle(LibraryPalette.muted)
                .frame(maxWidth: 400)
            Button(action: importAction) {
                Label(String(localized: "Import Folder…"), systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(LibraryPalette.accent)
            .accessibilityIdentifier("library.importFolder")
            Button {
                NotificationCenter.default.post(name: .momentsShowPhotosImport, object: nil)
            } label: {
                Label(String(localized: "Import from Apple Photos…"), systemImage: "photo.on.rectangle")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("library.importPhotos")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.firstLaunch")
    }
}

private struct LibrarySectionView: View {
    let section: LibrarySection
    let items: [MediaItem]
    let state: LibraryViewState
    var stackCounts: [String: Int] = [:]
    /// The section's memories and the place notes its photos show, matched and
    /// queried once by the page instead of by every section.
    var memories: [CollectionMemory] = []
    var placeNotes: [PlaceNote] = []

    /// Set by the scroll content (reportsLibraryGridColumns) from the chosen
    /// photos per row; the window's size changes it only when it is too
    /// narrow for that many.
    private var columnCount: Int { max(1, state.gridColumns) }

    private var size: LibraryThumbnailSize { LibraryThumbnailSize(columns: columnCount) }

    @Environment(SelectionModel.self) private var selection

    private var sectionTripID: String? {
        section.id.hasPrefix("trip:") ? String(section.id.dropFirst("trip:".count)) : nil
    }

    private func selectSection() {
        selection.select(section.itemIDs, focus: section.itemIDs.first)
    }

    /// The heading and the section's grid are children of the Library's lazy
    /// stack. The grid has a fixed number of equal columns, set by − and +,
    /// so when the window or the sidebar changes size the photos grow and
    /// shrink instead of jumping to another column count, like Photos.
    /// (One HStack per row instead of a grid scrolled with several times
    /// more stalls on 2,000 photos.)
    var body: some View {
        let _ = marqueeCount(4)
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                // Like a moment title in Photos: click selects the section's
                // photos, and the menu goes to the trip or the map. A trip's
                // name also changes in place on double-click.
                HStack(spacing: 0) {
                    if let tripID = sectionTripID, section.id != "trip:unassigned" {
                        EditableTripTitle(tripID: tripID, title: section.title, onClick: selectSection)
                            .accessibilityAction(named: Text(String(localized: "Select these photos"))) { selectSection() }
                    } else {
                        Button { selectSection() } label: {
                            Text(section.title)
                                .font(.system(size: 21, weight: .medium, design: .serif))
                                .foregroundStyle(LibraryPalette.ink)
                        }
                        .buttonStyle(.plain)
                        .help(String(localized: "Select these photos"))
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("library.section.\(section.id)")
                .contextMenu {
                    Button(String(localized: "Select these photos")) { selectSection() }
                    if let tripID = sectionTripID, section.id != "trip:unassigned" {
                        Button(String(localized: "Show Trip")) { selection.showTrip(tripID) }
                    }
                }
                Text(dateSpan)
                    .font(.caption)
                    .foregroundStyle(LibraryPalette.muted)
                // A chapter's photos lead to the chapter: its days, places,
                // people and map.
                if let tripID = sectionTripID, section.id != "trip:unassigned" {
                    Button { selection.showTrip(tripID) } label: {
                        Image(systemName: "book.pages")
                            .font(.caption)
                            .foregroundStyle(LibraryPalette.muted)
                            .frame(width: 22, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Show Trip"))
                    .accessibilityLabel(String(localized: "Show Trip"))
                    .accessibilityIdentifier("library.chapter-link.\(tripID)")
                }
                // Who is in these photos.
                if !state.peopleEntries.isEmpty {
                    LibrarySectionFaces(sectionID: section.id, itemIDs: section.itemIDs, state: state)
                }
                Spacer()
                Text(String(localized: "\(section.count) photos"))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(LibraryPalette.muted)
            }

            CollectionMemoryLines(memories: memories)
        }
        .padding(.bottom, 13)
        .id(LibraryScrollTarget.section(section.id))
        #if DEBUG
        .modifier(ResizeProbeGridWidth(columns: columnCount))
        #endif

        LazyVGrid(columns: gridColumns, alignment: .leading, spacing: size.rowSpacing) {
            ForEach(items, id: \.id) { item in
                LibraryPhotoCell(item: item, state: state, placeNotes: placeNotes, isCompact: size.isCompact, stackCount: stackCounts[item.id] ?? 1, probeToken: pageProbePhaseToken)
            }
        }
        .padding(.bottom, LibrarySectionView.sectionSpacing)
    }

    /// A fixed number of equal columns, so when the space changes the
    /// photos grow and shrink with it instead of reflowing.
    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: size.spacing, alignment: .top), count: columnCount)
    }

    /// Space between one section's grid and the next heading.
    static let sectionSpacing: CGFloat = 34

    private var dateSpan: String {
        guard let start = section.startDate else { return String(localized: "Undated") }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        guard let end = section.endDate, !Calendar.current.isDate(start, inSameDayAs: end) else {
            return formatter.string(from: start)
        }
        return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
    }
}

/// One photo in the grid. Its body never reads the selection: the parts
/// that show it (frame, marks, menu, accessibility) are small views and
/// modifiers of their own, so a rubber-band drag that selects a row redraws
/// those, not every photo on screen.
private struct LibraryPhotoCell: View {
    @Environment(SelectionModel.self) private var selection
    let item: MediaItem
    let state: LibraryViewState
    var placeNotes: [PlaceNote] = []
    /// The smallest zoom levels: a dense grid of photos only; place, memory
    /// and note are read and written in the large viewer.
    var isCompact = false
    /// More than one: the cell is a burst, shown as a stack with its cover.
    var stackCount = 1
    /// The page probe phase this cell was built in (DEBUG only).
    var probeToken: UInt64? = nil
    @State private var isHovering = false

    private var showsMemoryEditor: Bool {
        state.memoryDrafts[item.id] != nil
            || item.latestMemory?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    /// A photo with a memory shows just that memory; its note line appears
    /// while the pointer is over the photo or the line is in use. It keeps
    /// its space, so the grid never shifts.
    private var showsNoteLine: Bool {
        !showsMemoryEditor || isHovering || state.focusedNoteItemID == item.id
            || !(state.noteDrafts[item.id] ?? "").isEmpty
    }

    var body: some View {
        let _ = marqueeCount(5)
        VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .topLeading) {
                Button {
                    click()
                } label: {
                    if isCompact {
                        ThumbnailView(item: item, width: 280, height: 280, probeToken: probeToken)
                            .aspectRatio(1, contentMode: .fit)
                            .stackedPaper(stackCount, isCompact: true, cornerRadius: 10)
                            .overlay { LibraryPhotoSelectionFrame(itemID: item.id, cornerRadius: 10) }
                    } else {
                        ThumbnailView(item: item, width: 560, height: 420, probeToken: probeToken)
                            .aspectRatio(1.33, contentMode: .fit)
                            .padding(5)
                            // A print's white mat, lifted by a warm two-layer shadow.
                            // The mat casts it, not the photo: a shadow over the
                            // whole cell is redrawn offscreen while the grid scrolls.
                            .background(
                                Color.white
                                    .shadow(.drop(color: Paper.shadow.opacity(0.08), radius: 1, y: 1))
                                    .shadow(.drop(color: Paper.shadow.opacity(0.10), radius: 8, y: 5))
                            )
                            .stackedPaper(stackCount, isCompact: false)
                            // Selected photos get an accent frame, like Photos.
                            .overlay { LibraryPhotoSelectionFrame(itemID: item.id, cornerRadius: 0) }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("library.photo.\(item.id)")
                .modifier(LibraryPhotoSelectionAccessibility(itemID: item.id))
                .id(LibraryScrollTarget.item(item.id))
                .libraryMarqueeTarget(item.id, marquee: state.marquee)
                .onAppear {
                    if state.pendingRevealItemID == item.id { state.appearedRevealItemID = item.id }
                }
                // Outside the button, so the count is its own element for
                // VoiceOver and tests; clicks pass through to the photo.
                .overlay(alignment: .bottomTrailing) {
                    stackBadge
                        .padding(isCompact ? 0 : 5)
                        .allowsHitTesting(false)
                }
                // A video or a Live Photo says so on its thumbnail, so nobody
                // needs a switch to tell them apart.
                .overlay(alignment: .bottomLeading) {
                    if item.kind != .photo {
                        Image(systemName: item.kind == .video ? "video.fill" : "livephoto")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .shadow(color: Paper.shadow.opacity(0.4), radius: 2)
                            .padding(isCompact ? 7 : 12)
                            .allowsHitTesting(false)
                            .accessibilityLabel(item.kind == .video ? String(localized: "Videos") : String(localized: "Live Photos"))
                            .accessibilityIdentifier("library.kind.\(item.kind.rawValue).\(item.id)")
                    }
                }

                LibraryPhotoMarks(item: item, isCompact: isCompact, isHovering: isHovering)
            }

            if !isCompact {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    PhotoPlaceLine(item: item, placeNotes: placeNotes)
                    Spacer(minLength: 0)
                    PhotoNoteBadge(item: item)
                }
                // A written memory stays editable here; the ruled line below is
                // where new words go, so an empty photo shows only that one line.
                if showsMemoryEditor {
                    MemoryEditor(item: item, state: state)
                }
                PhotoNoteSection(item: item, state: state)
                    .opacity(showsNoteLine ? 1 : 0)
            }
        }
        .onHover {
            marqueeCount(6)
            isHovering = $0
        }
        .modifier(LibraryPhotoMenu(item: item, state: state, stackCount: stackCount, open: open))
        .onDrag { NSItemProvider(object: item.id as NSString) }
    }

    @ViewBuilder
    private var stackBadge: some View {
        if stackCount > 1 {
            StackCountBadge(count: stackCount, isCompact: isCompact)
                .accessibilityIdentifier("library.stack.\(item.id)")
        }
    }

    /// One click selects, a second click on the only selected photo
    /// deselects it, Command and Shift extend; a double click opens it.
    private func click() {
        let event = NSApp.currentEvent
        // clickCount exists only on mouse events; a keyboard press of the
        // button (Full Keyboard Access, VoiceOver) is a single click.
        let isMouse = event?.type == .leftMouseUp || event?.type == .leftMouseDown
        if isMouse, (event?.clickCount ?? 1) >= 2 {
            open()
            return
        }
        // A click on a photo ends note editing, so the keys that follow move
        // through the grid instead of typing into the note.
        if NSApp.keyWindow?.firstResponder is NSTextView {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        let flags = event?.modifierFlags ?? []
        selection.click(item.id, command: flags.contains(.command), shift: flags.contains(.shift), order: state.orderedItemIDs)
    }

    private func open() {
        selection.select(item.id)
        selection.anchorItemID = item.id
        selection.openViewer(item.id, in: state.viewerItemIDs)
    }
}

/// The select circle over a photo.
private struct LibraryPhotoMarks: View {
    @Environment(SelectionModel.self) private var selection
    let item: MediaItem
    let isCompact: Bool
    let isHovering: Bool

    var body: some View {
        HStack(spacing: 6) {
            Button {
                selection.click(item.id, command: true)
            } label: {
                Image(systemName: selection.isSelected(item.id) ? "checkmark.circle.fill" : "circle")
                    .font(isCompact ? .body : .title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Paper.shadow.opacity(0.45))
                    .shadow(color: Paper.shadow.opacity(0.35), radius: 2)
                    .symbolEffect(.bounce, value: selection.isSelected(item.id))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Select"))

            Spacer()
        }
        .padding(isCompact ? 6 : 11)
        // In the dense grid the marks show on hover, or when they mean something.
        .opacity(!isCompact || isHovering || selection.isSelected(item.id) ? 1 : 0)
    }
}

/// The accent frame around a selected photo, like Photos.
private struct LibraryPhotoSelectionFrame: View {
    @Environment(SelectionModel.self) private var selection
    let itemID: String
    let cornerRadius: CGFloat

    var body: some View {
        if selection.isSelected(itemID) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(LibraryPalette.accent, lineWidth: 3)
        }
    }
}

private struct LibraryPhotoSelectionAccessibility: ViewModifier {
    @Environment(SelectionModel.self) private var selection
    let itemID: String

    func body(content: Content) -> some View {
        content
            .accessibilityValue(selection.isSelected(itemID) ? String(localized: "Selected") : String(localized: "Not selected"))
            .accessibilityAddTraits(selection.isSelected(itemID) ? .isSelected : [])
    }
}

/// A photo's context menu.
private struct LibraryPhotoMenu: ViewModifier {
    @Environment(SelectionModel.self) private var selection
    @Environment(PhotoStackModel.self) private var stacks
    @Environment(\.modelContext) private var modelContext
    @Environment(\.undoManager) private var undoManager
    @Environment(\.photoDeletionScope) private var deletionScope
    let item: MediaItem
    let state: LibraryViewState
    let stackCount: Int
    let open: () -> Void

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button(String(localized: "Open")) { open() }
                if stackCount > 1, let stack = stacks.stack(containing: item.id) {
                    Button(String(localized: "Unstack")) {
                        stacks.unstack(stack, context: modelContext, undoManager: undoManager)
                    }
                }
                Button(selection.isSelected(item.id) && selection.selectedItemIDs.count > 1
                       ? String(localized: "Adjust Date and Time of \(selection.selectedItemIDs.count) Photos…")
                       : String(localized: "Adjust Date and Time…")) {
                    selection.adjustDateAndTime(for: item.id)
                }
                if let tripID = item.tripID {
                    Button(String(localized: "Show Trip")) { selection.showTrip(tripID) }
                }
                Divider()
                Button(String(localized: "Delete from Moments"), role: .destructive) {
                    // The whole selection when this photo is in it, else just this one.
                    let shown = selection.isSelected(item.id)
                        ? state.orderedItemIDs.filter(selection.selectedItemIDs.contains)
                        : [item.id]
                    PhotoDeletion.request(deletionScope(shown.isEmpty ? [item.id] : shown), confirm: true, selection: selection, context: modelContext, undoManager: undoManager)
                }
                .disabled(!RecentlyDeleted.canDelete(item))
            }
    }
}

struct MemoryEditor: View {
    @Environment(\.modelContext) private var modelContext

    let item: MediaItem
    let state: LibraryViewState
    @State private var saveTask: Task<Void, Never>?
    @State private var baseline: LibraryMemorySnapshot?
    @State private var wasEdited = false
    @FocusState private var isFocused: Bool

    private var storedMemory: Memory? {
        item.latestMemory
    }

    private var isPartnerMemory: Bool {
        guard let memory = storedMemory else { return false }
        if let authorAccountID = memory.authorAccountID {
            return authorAccountID != MomentsAccount.localID
        }
        return memory.author == .partner
    }

    private var hasMemory: Bool {
        storedMemory?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { state.draft(for: item) },
            set: { newValue in
                guard !isPartnerMemory else { return }
                guard newValue != state.draft(for: item) else { return }
                if !wasEdited {
                    baseline = storedMemory.map(LibraryMemorySnapshot.init(memory:))
                    wasEdited = true
                }
                state.setDraft(newValue, for: item)
                scheduleSave(newValue)
            }
        )
    }

    var body: some View {
        TextEditor(text: textBinding)
            .font(.system(.body, design: hasMemory ? .serif : .default))
            .foregroundStyle(LibraryPalette.ink)
            .frame(minHeight: hasMemory ? 42 : 24, maxHeight: hasMemory ? 110 : 28)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 0)
            .padding(.vertical, 0)
            .background(Color.clear)
            .focused($isFocused)
            .disabled(isPartnerMemory)
            .overlay(alignment: .bottom) {
                if !hasMemory {
                    Rectangle()
                        .fill(LibraryPalette.rule)
                        .frame(height: 1)
                }
            }
            .accessibilityIdentifier("library.memory.\(item.id)")
            .onAppear {
                if state.focusedMemoryItemID == item.id { isFocused = true }
            }
            .onChange(of: isFocused) { _, focused in
                if focused {
                    state.focusedMemoryItemID = item.id
                } else if state.focusedMemoryItemID == item.id {
                    state.focusedMemoryItemID = nil
                }
            }
            .onDisappear {
                saveTask?.cancel()
                if !isPartnerMemory {
                    persist(state.draft(for: item))
                }
                if state.focusedMemoryItemID == item.id { state.focusedMemoryItemID = nil }
            }
    }

    private func scheduleSave(_ newText: String) {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 550_000_000)
            guard !Task.isCancelled else { return }
            persist(newText)
        }
    }

    private func persist(_ newText: String) {
        let memory = storedMemory
        let stored = memory.map(LibraryMemorySnapshot.init(memory:))
        if let stored, !stored.isAuthoredByCurrentUser { return }
        let decision = LibraryMemoryPersistence.decision(
            draft: newText,
            wasEdited: wasEdited,
            baseline: baseline,
            stored: stored
        )

        var savedMemory: Memory?
        switch decision {
        case .noChange:
            state.clearDraft(for: item)
            return
        case .conflict:
            guard let memory, stored?.isAuthoredByCurrentUser == true else { return }
            // Keep the version that arrived while this editor was open. The
            // current user's draft becomes the live text, while the losing
            // text remains available through the revision history.
            modelContext.insert(MemoryRevision(
                text: memory.text,
                editedBy: memory.updatedBy ?? MomentsAccount.localID,
                baseRevision: memory.revision,
                reason: "conflict",
                memory: memory
            ))
            memory.text = newText
            memory.updatedAt = .now
            memory.updatedBy = MomentsAccount.localID
            memory.revision += 1
            savedMemory = memory
        case .delete:
            guard let memory else { return }
            modelContext.delete(memory)
        case .update:
            guard let memory else { return }
            if baseline == nil, memory.text != newText {
                modelContext.insert(MemoryRevision(
                    text: memory.text,
                    editedBy: memory.updatedBy ?? MomentsAccount.localID,
                    baseRevision: memory.revision,
                    reason: "late-arriving-memory",
                    memory: memory
                ))
            }
            memory.text = newText
            memory.updatedAt = .now
            memory.updatedBy = MomentsAccount.localID
            memory.revision += 1
            savedMemory = memory
        case .insert:
            let newMemory = Memory(
                text: newText,
                author: .me,
                authorAccountID: MomentsAccount.localID,
                updatedBy: MomentsAccount.localID,
                mediaItem: item
            )
            modelContext.insert(newMemory)
            savedMemory = newMemory
        }

        do {
            try modelContext.save()
            baseline = savedMemory.map(LibraryMemorySnapshot.init(memory:))
            state.clearDraft(for: item)
        } catch {
            // Keep the draft in LibraryViewState so a transient save failure does not lose input.
        }
    }
}
