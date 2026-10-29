import AppKit
import Foundation
import SwiftUI
import SwiftData

private struct LibraryFilterOptions {
    var places: [LibraryPlaceOption] = []
    var trips: [String] = []
    var tripNames: [String: String] = [:]
}

private enum LibraryScrollTarget {
    static func section(_ id: String) -> String { "section:\(id)" }
    static func item(_ id: String) -> String { "item:\(id)" }
}

struct LibraryView: View {
    @Environment(SelectionModel.self) private var selection
    @Environment(ImportController.self) private var importController
    @Environment(PhotoStackModel.self) private var stacks
    @Environment(LibraryProjectionStore.self) private var projectionStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Keep the common Library query free of explicit screenshots in SwiftData.
    // The screenshot segment switches to the second descriptor without making
    // the normal 5k-item browsing path carry those models through filtering.
    @Query(filter: #Predicate<MediaItem> { $0.isScreenshot == false && $0.deletedAt == nil }, sort: \MediaItem.captureDate)
    private var regularItems: [MediaItem]
    @Query(filter: #Predicate<MediaItem> { $0.isScreenshot == true && $0.deletedAt == nil }, sort: \MediaItem.captureDate)
    private var screenshotItems: [MediaItem]
    @Query(sort: \Memory.updatedAt)
    private var memoryRecords: [Memory]
    @Query(sort: \Trip.id)
    private var allTrips: [Trip]
    @Query(sort: \Place.id)
    private var allPlaces: [Place]
    @Query(sort: \PlaceOverride.id)
    private var placeOverrides: [PlaceOverride]
    /// "My groups" only; chapters live on the Chapters page, and stack
    /// records are not groups anyone made.
    @Query(filter: #Predicate<UserGroup> { $0.kindRaw != "chapter" && $0.kindRaw != "stack" }, sort: \UserGroup.name)
    private var allGroups: [UserGroup]
    @Query private var groupItems: [UserGroupItem]
    @Query(sort: \Person.name) private var people: [Person]
    @Query private var faceObservations: [FaceObservation]
    /// What someone changed about bursts: covers, unstacked, photos taken out.
    @Query(filter: #Predicate<UserGroup> { $0.kindRaw == "stack" }) private var stackRecords: [UserGroup]

    let state: LibraryViewState
    @Binding var firstLaunchCompleted: Bool

    @AppStorage("moments.library.type") private var typeRaw = LibraryMediaTypeFilter.all.rawValue
    @AppStorage(LibraryFilterKeys.query) private var query = ""
    @AppStorage("moments.library.grouping") private var groupingRaw = LibraryGrouping.trip.rawValue
    @AppStorage("moments.library.fromDate") private var fromDateInterval = 0.0
    @AppStorage("moments.library.toDate") private var toDateInterval = 0.0
    @AppStorage("moments.library.place") private var placeFilterID = ""
    @AppStorage("moments.library.trip") private var tripFilterKey = ""
    @AppStorage("moments.library.memory") private var memoryFilterRaw = LibraryMemoryFilter.all.rawValue
    @AppStorage("moments.library.person") private var personFilterID = ""

    @State private var cachedSections: [LibrarySection] = []
    /// Each section's photos before stacks were folded.
    @State private var cachedUnfoldedSectionItems: [String: [String]] = [:]
    /// Photos behind each stacked cell, by the id the cell shows.
    @State private var cachedStackCounts: [String: Int] = [:]
    @State private var cachedItemByID: [String: MediaItem] = [:]
    @State private var cachedVisibleCount = 0
    @State private var hasGrouped = false
    @State private var showingSmartGroupEditor = false
    @State private var cachedPersonIndex: [String: Set<String>] = [:]
    /// Photos the import flagged for a look; shown as a banner, not a sidebar row.
    @State private var cachedReviewCount = 0
    @State private var showingReview = false
    @State private var cachedFilterOptions = LibraryFilterOptions()
    @State private var loadedPhotoLimit = 36

    init(state: LibraryViewState, firstLaunchCompleted: Binding<Bool> = .constant(true)) {
        self.state = state
        self._firstLaunchCompleted = firstLaunchCompleted
    }

    private var criteria: LibraryFilterCriteria {
        LibraryFilterCriteria(
            fromDate: fromDateInterval == 0 ? nil : Date(timeIntervalSince1970: fromDateInterval),
            toDate: toDateInterval == 0 ? nil : Date(timeIntervalSince1970: toDateInterval),
            placeID: placeFilterID.isEmpty ? nil : placeFilterID,
            mediaType: LibraryMediaTypeFilter(rawValue: typeRaw) ?? .all,
            tripKey: tripFilterKey.isEmpty ? nil : tripFilterKey,
            memoryFilter: LibraryMemoryFilter(rawValue: memoryFilterRaw) ?? .all,
            personID: personFilterID.isEmpty ? nil : personFilterID,
            searchText: query
        )
    }

    private var items: [MediaItem] {
        typeRaw == LibraryMediaTypeFilter.screenshot.rawValue ? screenshotItems : regularItems
    }

    private var allItems: [MediaItem] {
        regularItems + screenshotItems
    }

    private var grouping: LibraryGrouping {
        LibraryGrouping(rawValue: groupingRaw) ?? .trip
    }

    /// A stacked cell stands for every photo in its burst, as in Photos.
    private func deletionScope(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.flatMap { id -> [String] in
            if (cachedStackCounts[id] ?? 1) > 1, let stack = stacks.stack(containing: id) { return stack.memberIDs }
            return [id]
        }
        .filter { seen.insert($0).inserted }
    }

    /// The Place and Trip menus' rows, rebuilt with the sections in regroup().
    /// Computing them here walked every item and its place on each render,
    /// which showed up as a stall when the Library re-rendered mid-scroll.
    private var places: [LibraryPlaceOption] { cachedFilterOptions.places }

    private var trips: [String] { cachedFilterOptions.trips }

    private static func filterOptions(for items: [MediaItem]) -> LibraryFilterOptions {
        var tripNames: [String: String] = [:]
        for item in items {
            if let tripID = item.tripID, tripNames[tripID] == nil {
                tripNames[tripID] = item.trip?.effectiveName ?? tripID
            }
        }
        return LibraryFilterOptions(
            // One row per name: unnamed spots are listed under the area or
            // city that names them, places with the same name are one row,
            // and the filter matches all of them.
            places: PlaceNames.options(for: items),
            trips: tripNames.keys.sorted(),
            tripNames: tripNames
        )
    }

    private var selectedPlaceName: String? {
        places.first(where: { $0.id == placeFilterID })?.name
    }

    private var selectedTripName: String? {
        guard !tripFilterKey.isEmpty else { return nil }
        return selectedTripName(for: tripFilterKey)
    }

    private var selectedMemoryFilter: LibraryMemoryFilter {
        LibraryMemoryFilter(rawValue: memoryFilterRaw) ?? .all
    }

    private var visiblePeople: [Person] {
        people.filter { !$0.hidden && ($0.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) }
    }

    private var selectedPersonName: String? { people.first(where: { $0.id == personFilterID })?.name }

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
        hasher.combine(typeRaw)
        hasher.combine(groupingRaw)
        hasher.combine(fromDateInterval)
        hasher.combine(toDateInterval)
        hasher.combine(placeFilterID)
        hasher.combine(tripFilterKey)
        hasher.combine(memoryFilterRaw)
        hasher.combine(personFilterID)
        hasher.combine(query)
        hasher.combine(state.focusedMemoryItemID)
        hasher.combine(selection.libraryScope?.itemIDs)
        // The projection revision is the invalidation boundary for scalar
        // photo fields. Rehashing every MediaItem and faulting every Place
        // here made a page switch scale with the entire library.
        hasher.combine(projectionStore.revision)
        hasher.combine(allItems.count)
        for trip in allTrips {
            hasher.combine(trip.id)
            hasher.combine(trip.name)
            hasher.combine(trip.overrideName)
        }
        for place in allPlaces {
            hasher.combine(place.id)
            hasher.combine(place.name)
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
        for observation in faceObservations {
            hasher.combine(observation.id)
            hasher.combine(observation.mediaID)
            hasher.combine(observation.personID)
            hasher.combine(observation.confirmed)
            hasher.combine(observation.assignmentSource)
        }
        // Bursts regroup when someone changes a stack or new analysis arrives.
        hasher.combine(stacks.generation)
        for record in stackRecords {
            hasher.combine(record.id)
            hasher.combine(record.rulesData)
        }
        return hasher.finalize()
    }

    var body: some View {
        Group {
            if LibraryLaunchState.shouldShowImportFlow(hasCompletedFirstLaunch: firstLaunchCompleted, itemCount: allItems.count) {
                FirstLaunchImportView {
                    importController.chooseFolder()
                }
            } else {
                libraryContent
            }
        }
        .background(LibraryPalette.content)
        .endsTextEditingOnOutsideClick()
        .onChange(of: allItems.count, initial: true) { _, count in
            if count > 0 { firstLaunchCompleted = true }
        }
        .onChange(of: people.map(\.id), initial: true) { _, ids in
            if !personFilterID.isEmpty && !ids.contains(personFilterID) { personFilterID = "" }
        }
        #if DEBUG
        .onAppear {
            PageProbe.shellReady(token: PageProbe.phaseToken)
        }
        #endif
        .task(id: groupingKey) {
            #if DEBUG
            let probeToken = PageProbe.phaseToken
            defer {
                if Task.isCancelled { PageProbe.cancellationObserved(token: probeToken) }
            }
            #endif
            // A new filter or projection generation starts from the first
            // viewport again; a previously expanded batch must not make the
            // next navigation render hundreds of cards synchronously.
            loadedPhotoLimit = 36
            regroup()
            #if DEBUG
            if !Task.isCancelled { PageProbe.contentReady(token: probeToken) }
            #endif
        }
        .sheet(isPresented: $showingReview) {
            ReviewSheet()
        }
        // A jump to another place (such as Show in Library) closes the list.
        .onChange(of: selection.requestedDestination) { _, destination in
            if destination != nil { showingReview = false }
        }
        // The large viewer opens in the window behind the sheet; close the
        // list so a photo clicked there is seen.
        .onChange(of: selection.viewerRequest == nil) { _, isClosed in
            if !isClosed { showingReview = false }
        }
        .sheet(
            isPresented: Binding(
                get: { importController.reviewSummary != nil },
                set: { if !$0 { importController.dismissReview() } }
            )
        ) {
            if let summary = importController.reviewSummary {
                ImportReviewView(summary: summary)
            }
        }
    }

    private var libraryContent: some View {
        VStack(spacing: 0) {
            libraryHeader
            filterBar
            if cachedReviewCount > 0 {
                reviewBanner
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) { LibraryZoomControl(state: state) }
        }
        .searchable(text: $query, placement: .toolbar, prompt: Text(String(localized: "Search places, trips, notes")))
        .navigationTitle(String(localized: "Library"))
        .modifier(LibrarySelectionSubtitle(idle: String(localized: "\(cachedVisibleCount) photos")))
    }

    /// "12 photos to confirm" under the filters; opens the review list.
    private var reviewBanner: some View {
        Button {
            showingReview = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(LibraryPalette.accent)
                    .inlineIcon()
                Text(String(localized: "\(cachedReviewCount) photos to confirm"))
                    .foregroundStyle(LibraryPalette.ink)
                Spacer(minLength: 8)
                Text(String(localized: "Review"))
                    .foregroundStyle(LibraryPalette.accent)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LibraryPalette.accent)
                    .inlineIcon()
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(LibraryPalette.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, PaperMetrics.screenInset)
        .padding(.top, 10)
        // Room before the first section title, so the banner never sits on it.
        .padding(.bottom, 14)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("library.review-banner")
    }

    /// The page name and photo count live in the window's title bar; the
    /// page itself opens straight on its controls.
    private var libraryHeader: some View {
        // One fixed row at every width, so the grid never moves while the
        // sidebar animates (a ViewThatFits here switched between one, two and
        // three rows). The page title is in the window's title bar; the type
        // bar is short enough to share the row with Group by.
        HStack(alignment: .center, spacing: 22) {
            libraryTypePicker
            Spacer(minLength: 8)
            libraryGroupingPicker
        }
        .padding(.horizontal, PaperMetrics.screenInset)
        .padding(.top, PaperMetrics.screenTopInset)
        .padding(.bottom, 14)
    }

    /// The everyday choices as segments; Live Photos and Screenshots, picked
    /// rarely, wait in More. Fixed size, so the control never turns into a
    /// scrolling strip.
    private var libraryTypePicker: some View {
        let lessUsed: [(LibraryMediaTypeFilter, String)] = [
            (.live, String(localized: "Live Photos")),
            (.screenshot, String(localized: "Screenshots")),
        ]
        let pickedLessUsed = lessUsed.first { $0.0.rawValue == typeRaw }
        return HStack(spacing: 8) {
            Picker(String(localized: "Media type"), selection: $typeRaw) {
                Text(String(localized: "All")).tag(LibraryMediaTypeFilter.all.rawValue)
                Label(String(localized: "Favorites"), systemImage: "star").tag(LibraryMediaTypeFilter.favorite.rawValue)
                Text(String(localized: "Photos")).tag(LibraryMediaTypeFilter.photo.rawValue)
                Text(String(localized: "Videos")).tag(LibraryMediaTypeFilter.video.rawValue)
                if let pickedLessUsed {
                    Text(pickedLessUsed.1).tag(pickedLessUsed.0.rawValue)
                }
            }
            .pickerStyle(.segmented)
            // The segments name themselves; a visible "Media type" label wrapped
            // onto two lines in narrow windows. VoiceOver still reads it.
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("library.type-filter")

            Menu {
                ForEach(lessUsed, id: \.0) { option in
                    Button {
                        typeRaw = option.0.rawValue
                    } label: {
                        Label(option.1, systemImage: typeRaw == option.0.rawValue ? "checkmark" : "circle")
                    }
                }
            } label: {
                Text(String(localized: "More"))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(String(localized: "Live Photos and Screenshots"))
            .accessibilityIdentifier("library.type-more")
        }
    }

    private var libraryGroupingPicker: some View {
        Picker(String(localized: "Group by"), selection: $groupingRaw) {
            Text(String(localized: "By trip")).tag(LibraryGrouping.trip.rawValue)
            Text(String(localized: "By place")).tag(LibraryGrouping.place.rawValue)
            Text(String(localized: "By type")).tag(LibraryGrouping.type.rawValue)
            Text(String(localized: "By month")).tag(LibraryGrouping.month.rawValue)
        }
        .pickerStyle(.menu)
        // Sized to the longest option so "Nach Reise" never truncates.
        .fixedSize()
        .accessibilityIdentifier("library.grouping")
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            LibraryFilterChips(showsScope: true)

            // The count is in the title bar; this row only appears for a
            // filter that could become a smart group. A scope is a one-off
            // list, not a rule a smart group could keep.
            // Favorites and search have no smart-group rule yet, so a filter
            // using them can't be saved without losing part of it.
            if criteria.isFiltered && !criteria.favoritesOnly && criteria.searchText.isEmpty && selection.libraryScope == nil {
                HStack {
                    Spacer(minLength: 12)
                    Button(String(localized: "Save this filter as a smart group")) {
                        showingSmartGroupEditor = true
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .foregroundStyle(LibraryPalette.accent)
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityIdentifier("library.save-smart-group")
                }
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
        .padding(.horizontal, PaperMetrics.screenInset)
        .padding(.vertical, 13)
        // A band one tone down sets the filters apart; no rules above or below.
        .background(Paper.well.opacity(0.45))
        .sheet(isPresented: $showingSmartGroupEditor) {
            GroupEditorSheet(kind: .newSmart, group: nil, initialCriteria: criteria)
        }
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Headings and section grids space themselves (LibrarySectionView).
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(cachedSections) { section in
                        LibrarySectionView(
                            section: section,
                            items: section.itemIDs.compactMap { cachedItemByID[$0] },
                            state: state,
                            allGroups: allGroups,
                            groupItems: groupItems,
                            stackCounts: cachedStackCounts,
                            allItemIDs: cachedUnfoldedSectionItems[section.id] ?? section.itemIDs
                        )
                    }
                    if cachedItemByID.count < cachedVisibleCount {
                        ProgressView(String(localized: "Loading more photos…"))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                            .onAppear {
                                guard loadedPhotoLimit < cachedVisibleCount else { return }
                                loadedPhotoLimit += 36
                                regroup()
                            }
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
                id: Binding(get: { state.topSectionScrollID }, set: { id in
                    guard let id, !state.marquee.isDragging, state.topSectionScrollID != id else { return }
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
                systemImage: isFiltered ? "line.3.horizontal.decrease.circle" : "photo.on.rectangle",
                description: Text(isFiltered ? String(localized: "Try changing your filters.") : String(localized: "Add a photo or import a folder to begin."))
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

    private var dateFilterLabel: String? {
        guard fromDateInterval != 0 || toDateInterval != 0 else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        if fromDateInterval != 0, toDateInterval != 0 {
            return "\(String(localized: "Date:")) \(formatter.string(from: Date(timeIntervalSince1970: fromDateInterval))) – \(formatter.string(from: Date(timeIntervalSince1970: toDateInterval)))"
        }
        if fromDateInterval != 0 {
            return "\(String(localized: "From:")) \(formatter.string(from: Date(timeIntervalSince1970: fromDateInterval)))"
        }
        return "\(String(localized: "To:")) \(formatter.string(from: Date(timeIntervalSince1970: toDateInterval)))"
    }

    private var hasActiveFilters: Bool {
        placeFilterID.isEmpty == false || tripFilterKey.isEmpty == false || dateFilterLabel != nil || selectedMemoryFilter != .all || personFilterID.isEmpty == false
    }

    private func memoryFilterLabel(_ filter: LibraryMemoryFilter) -> String {
        switch filter {
        case .all: return String(localized: "All memories")
        case .hasMemory: return String(localized: "Has memory")
        case .noMemory: return String(localized: "No memory")
        }
    }

    private func selectedTripName(for tripID: String) -> String {
        cachedFilterOptions.tripNames[tripID] ?? tripID
    }

    private func clearFilters() {
        fromDateInterval = 0
        toDateInterval = 0
        placeFilterID = ""
        tripFilterKey = ""
        memoryFilterRaw = LibraryMemoryFilter.all.rawValue
        personFilterID = ""
        typeRaw = LibraryMediaTypeFilter.all.rawValue
        selection.libraryScope = nil
    }

    private func regroup() {
        cachedReviewCount = allItems.reduce(into: 0) { count, item in
            if item.needsImportReview { count += 1 }
        }
        let personIndex = UserGroupRuleEngine.makePersonIndex(faceObservations)
        cachedPersonIndex = personIndex
        // A scope from another screen narrows the grid only; the published
        // ids below stay on the regular filters so the maps do not shrink.
        let scopedItems = selection.libraryScope.map { scope in
            items.filter { scope.itemIDs.contains($0.id) }
        } ?? items
        let filtered = LibraryFilterEngine.filteredItems(scopedItems, by: criteria, personIDsByMediaID: personIndex)
        let visible = LibraryFilterEngine.filteredItems(
            scopedItems,
            by: criteria,
            preservingEditingItemID: state.focusedMemoryItemID,
            personIDsByMediaID: personIndex
        )
        // Keep the count and selection scope complete, but build only the first
        // viewport-sized batch for the initial frame. More cells are appended
        // by the sentinel below; this avoids asking SwiftUI to lay out the
        // entire library during navigation.
        let orderedVisible = visible.sorted { ($0.effectiveCaptureDate ?? .distantPast, $0.id) > ($1.effectiveCaptureDate ?? .distantPast, $1.id) }
        let initialVisible = Array(orderedVisible.prefix(max(36, loadedPhotoLimit)))
        cachedItemByID = Dictionary(uniqueKeysWithValues: initialVisible.map { ($0.id, $0) })
        // A burst is one cell showing its cover, and counts as one photo.
        let stackIndex = stacks.update(items: allItems, decisions: stackRecords)
        let unfolded = LibraryFilterEngine.sections(forVisibleItems: initialVisible, by: grouping, sortOrder: .newestFirst)
        let folded = LibraryFilterEngine.folding(unfolded, with: stackIndex)
        cachedSections = folded.sections
        cachedUnfoldedSectionItems = Dictionary(unfolded.map { ($0.id, $0.itemIDs) }, uniquingKeysWith: { first, _ in first })
        cachedStackCounts = folded.stackCounts
        cachedVisibleCount = visible.count
        state.gridSections = cachedSections.map(\.itemIDs)
        state.viewerItemIDs = unfolded.flatMap(\.itemIDs)
        hasGrouped = true
        cachedFilterOptions = Self.filterOptions(for: allItems)
        let publishedVisible = Set(LibraryFilterEngine.publishedItems(allItems, by: criteria, personIDsByMediaID: personIndex).map(\.id))
        selection.visibleItemIDs = publishedVisible
        selection.selectedItemIDs.formIntersection(selection.visibleItemIDs ?? [])
        if let focus = selection.focusedItemID,
           !filtered.contains(where: { $0.id == focus }),
           !selection.shouldRevealSelectionInLibrary {
            selection.focusedItemID = selection.selectedItemIDs.first
        }
    }

    private func revealRequestedSelectionIfNeeded(in sections: [LibrarySection], using proxy: ScrollViewProxy) {
        guard selection.shouldRevealSelectionInLibrary,
              let focus = selection.focusedItemID else { return }

        if typeRaw == LibraryMediaTypeFilter.screenshot.rawValue,
           let focusedItem = allItems.first(where: { $0.id == focus }),
           !focusedItem.isScreenshot {
            typeRaw = LibraryMediaTypeFilter.all.rawValue
            return
        }

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
        hasher.combine(typeRaw)
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
            Text(String(localized: "Choose a folder and Moments will arrange your library by trips and places."))
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
    var allGroups: [UserGroup] = []
    var groupItems: [UserGroupItem] = []
    var group: UserGroup? = nil
    var stackCounts: [String: Int] = [:]
    /// The section's photos with each stack's shots, for "Show only these".
    var allItemIDs: [String]? = nil
    @Query private var placeNotes: [PlaceNote]
    @Query(sort: \CollectionMemory.createdAt) private var collectionMemories: [CollectionMemory]

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
                    Button(String(localized: "Show only these photos")) {
                        selection.showInLibrary(allItemIDs ?? section.itemIDs, title: section.title)
                    }
                    if let tripID = sectionTripID {
                        Button(String(localized: "Show Trip")) { selection.showTrip(tripID) }
                    }
                    if let first = section.itemIDs.first {
                        Button(String(localized: "Show on Map")) { selection.showOnMap(first) }
                    }
                }
                Text(dateSpan)
                    .font(.caption)
                    .foregroundStyle(LibraryPalette.muted)
                Spacer()
                Text(String(localized: "\(section.count) photos"))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(LibraryPalette.muted)
            }

            CollectionMemoryLines(memories: sectionMemories)
        }
        .padding(.bottom, 13)
        .id(LibraryScrollTarget.section(section.id))
        #if DEBUG
        .modifier(ResizeProbeGridWidth(columns: columnCount))
        #endif

        LazyVGrid(columns: gridColumns, alignment: .leading, spacing: size.rowSpacing) {
            ForEach(items, id: \.id) { item in
                LibraryPhotoCell(item: item, state: state, allGroups: allGroups, groupItems: groupItems, group: group, placeNotes: placeNotes, isCompact: size.isCompact, stackCount: stackCounts[item.id] ?? 1)
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

    /// Trip memories for a trip section, and day memories for the days its photos were taken.
    private var sectionMemories: [CollectionMemory] {
        guard !collectionMemories.isEmpty else { return [] }
        let tripID = section.id.hasPrefix("trip:") ? String(section.id.dropFirst("trip:".count)) : nil
        let dayKeys = Set(items.compactMap { PhotoNoteDay.key(for: $0) })
        return collectionMemories.filter { memory in
            switch memory.scope {
            case .trip: return memory.scopeKey == tripID
            case .day, .photo: return dayKeys.contains(memory.scopeKey)
            }
        }
    }

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
    let allGroups: [UserGroup]
    let groupItems: [UserGroupItem]
    var group: UserGroup? = nil
    var placeNotes: [PlaceNote] = []
    /// The smallest zoom levels: a dense grid of photos only; place, memory
    /// and note are read and written in the large viewer.
    var isCompact = false
    /// More than one: the cell is a burst, shown as a stack with its cover.
    var stackCount = 1
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
        VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .topLeading) {
                Button {
                    click()
                } label: {
                    if isCompact {
                        ThumbnailView(item: item, width: 280, height: 280)
                            .aspectRatio(1, contentMode: .fit)
                            .stackedPaper(stackCount, isCompact: true, cornerRadius: 10)
                            .overlay { LibraryPhotoSelectionFrame(itemID: item.id, cornerRadius: 10) }
                    } else {
                        ThumbnailView(item: item, width: 560, height: 420)
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
        .onHover { isHovering = $0 }
        .modifier(LibraryPhotoMenu(item: item, state: state, stackCount: stackCount, group: group, allGroups: allGroups, groupItems: groupItems, open: open))
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

/// The select circle and the star over a photo.
private struct LibraryPhotoMarks: View {
    @Environment(SelectionModel.self) private var selection
    @Environment(\.modelContext) private var modelContext
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

            Button {
                item.setFavorite(!item.isFavorite, context: modelContext)
                try? modelContext.save()
            } label: {
                Image(systemName: item.isFavorite ? "star.fill" : "star")
                    .font(isCompact ? .body : .title3)
                    .foregroundStyle(item.isFavorite ? .yellow : .white)
                    .shadow(color: Paper.shadow.opacity(0.35), radius: 2)
                    // Confirmations get one small, friendly bounce.
                    .symbolEffect(.bounce, value: item.isFavorite)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Favorite"))
        }
        .padding(isCompact ? 6 : 11)
        // In the dense grid the marks show on hover, or when they mean something.
        .opacity(!isCompact || isHovering || selection.isSelected(item.id) || item.isFavorite ? 1 : 0)
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
    let group: UserGroup?
    let allGroups: [UserGroup]
    let groupItems: [UserGroupItem]
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
                Button(selection.isSelected(item.id) ? String(localized: "Deselect") : String(localized: "Select")) {
                    selection.toggle(item.id)
                }
                Button(item.isFavorite ? String(localized: "Unfavorite") : String(localized: "Favorite")) {
                    item.setFavorite(!item.isFavorite, context: modelContext)
                    try? modelContext.save()
                }
                Button(selection.isSelected(item.id) && selection.selectedItemIDs.count > 1
                       ? String(localized: "Adjust Date and Time of \(selection.selectedItemIDs.count) Photos…")
                       : String(localized: "Adjust Date and Time…")) {
                    selection.adjustDateAndTime(for: item.id)
                }
                Divider()
                if item.latitude != nil {
                    Button(String(localized: "Show on Map")) { selection.showOnMap(item.id) }
                }
                if let tripID = item.tripID {
                    Button(String(localized: "Show Trip")) { selection.showTrip(tripID) }
                }
                if let group {
                    Button(String(localized: "Remove from this group")) {
                        UserGroupRuleEngine.remove(item, from: group, memberships: groupItems, context: modelContext)
                        try? modelContext.save()
                    }
                }
                if !allGroups.isEmpty {
                    Menu(String(localized: "Add to group")) {
                        ForEach(allGroups, id: \.id) { target in
                            Button {
                                UserGroupRuleEngine.add(item, to: target, memberships: groupItems, context: modelContext)
                                try? modelContext.save()
                            } label: {
                                Label(target.name, systemImage: target.kind == .smart ? "sparkles" : "folder")
                            }
                        }
                    }
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

/// The review list in a sheet, opened from the Library banner.
struct ReviewSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ReviewListView()
            HStack {
                Spacer()
                Button(String(localized: "Done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("review.done")
            }
            .controlSize(.large)
            .padding(.horizontal, PaperMetrics.sheetInset)
            .padding(.vertical, 14)
            .background(Paper.well.opacity(0.6))
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 480, idealHeight: 620)
        .background(Paper.canvas)
        .tint(Paper.accent)
    }
}

struct ReviewListView: View {
    @Query(filter: #Predicate<MediaItem> { $0.deletedAt == nil }) private var items: [MediaItem]
    @Environment(\.modelContext) private var modelContext
    @Environment(SelectionModel.self) private var selection
    /// The last confirmation, so it can be taken back.
    @State private var lastConfirmed: [(id: String, decision: ImportReviewDecision)] = []

    private var pending: [MediaItem] {
        items
            .filter { $0.needsImportReview }
            .sorted {
                ($0.effectiveCaptureDate ?? .distantPast) < ($1.effectiveCaptureDate ?? .distantPast)
            }
    }

    var body: some View {
        let pending = self.pending
        VStack(alignment: .leading, spacing: 0) {
            PaperScreenHeader(String(localized: "To review")) {
                if !pending.isEmpty { Text("\(pending.count)") }
            } trailing: {
                if !lastConfirmed.isEmpty {
                    Button(String(localized: "Undo")) { undo() }
                        .keyboardShortcut("z", modifiers: .command)
                        .accessibilityIdentifier("review.undo")
                }
                if pending.count > 1 {
                    Button(String(localized: "Confirm all")) { confirm(pending) }
                        .accessibilityIdentifier("review.confirm-all")
                }
            }
            if pending.isEmpty {
                ContentUnavailableView(String(localized: "Nothing to review"), systemImage: "checkmark.circle", description: Text(String(localized: "Import review items will appear here.")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(pending, id: \.id) { item in
                            HStack(spacing: 14) {
                                Button {
                                    selection.select(item.id)
                                    selection.openViewer(item.id, in: pending.map(\.id))
                                } label: {
                                    ThumbnailView(item: item, width: 180, height: 140)
                                        .frame(width: 90, height: 70)
                                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .help(String(localized: "Open photo"))
                                .accessibilityIdentifier("review.photo.\(item.id)")
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title.isEmpty ? item.id : item.title)
                                        .foregroundStyle(LibraryPalette.ink)
                                    Text(item.importReviewReasons.map(\.label).joined(separator: " · "))
                                        .font(.caption)
                                        .foregroundStyle(LibraryPalette.muted)
                                }
                                Spacer(minLength: 8)
                                Button(String(localized: "Show in Library")) {
                                    selection.select(item.id)
                                    selection.requestedDestination = .library
                                }
                                .buttonStyle(.borderless)
                                .accessibilityIdentifier("review.show.\(item.id)")
                                Button(String(localized: "Confirm")) { confirm([item]) }
                                    .buttonStyle(.bordered)
                                    .accessibilityIdentifier("review.confirm.\(item.id)")
                            }
                            .paperCard(cornerRadius: 10, padding: 10)
                        }
                    }
                    .padding(.horizontal, PaperMetrics.screenInset)
                    .padding(.bottom, 24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LibraryPalette.content)
    }

    /// Confirming keeps Moments' suggestion as it is and clears the flag.
    private func confirm(_ confirmed: [MediaItem]) {
        lastConfirmed = confirmed.map { ($0.id, $0.importDecision) }
        for item in confirmed {
            item.importDecision = .accepted
            item.updatedAt = .now
            item.updatedBy = MomentsAccount.localID
        }
        try? modelContext.save()
    }

    private func undo() {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for entry in lastConfirmed {
            guard let item = byID[entry.id] else { continue }
            item.importDecision = entry.decision
            item.updatedAt = .now
            item.updatedBy = MomentsAccount.localID
        }
        try? modelContext.save()
        lastConfirmed = []
    }
}

struct GroupDetailView: View {
    let groupID: String
    let state: LibraryViewState
    @Environment(SelectionModel.self) private var selection

    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<UserGroup> { $0.kindRaw != "stack" }) private var groups: [UserGroup]
    @Query(filter: #Predicate<MediaItem> { $0.deletedAt == nil }) private var items: [MediaItem]
    @Query private var memberships: [UserGroupItem]
    @Query private var memoryRecords: [Memory]
    @Query private var mediaTags: [MediaTag]
    @Query(sort: \PlaceOverride.id) private var placeOverrides: [PlaceOverride]
    @Query private var faceObservations: [FaceObservation]
    @State private var showingEditor = false
    @State private var showingDeleteConfirmation = false
    @State private var cachedVisibleItemIDs: [String] = []
    @State private var cachedVisibleItemsByID: [String: MediaItem] = [:]
    @State private var cachedPersonIndex: [String: Set<String>] = [:]

    init(groupID: String, state: LibraryViewState) {
        self.groupID = groupID
        self.state = state
    }

    private var group: UserGroup? { groups.first(where: { $0.id == groupID }) }

    private var visibleItems: [MediaItem] {
        cachedVisibleItemIDs.compactMap { cachedVisibleItemsByID[$0] }
    }

    private var visibleItemsKey: Int {
        var hasher = Hasher()
        hasher.combine(groupID)
        if let group {
            hasher.combine(group.updatedAt)
            hasher.combine(group.kind.rawValue)
            hasher.combine(group.rules.mode.rawValue)
            for rule in group.rules.rules {
                hasher.combine(rule.field.rawValue)
                hasher.combine(rule.op.rawValue)
                hasher.combine(rule.value)
                hasher.combine(rule.secondaryValue)
            }
        }
        for item in items {
            hasher.combine(item.id)
            hasher.combine(item.updatedAt)
            hasher.combine(item.captureDate)
            hasher.combine(item.kindRaw)
            hasher.combine(item.isScreenshot)
            hasher.combine(item.tripID)
            hasher.combine(item.place?.id)
        }
        // Place renames reach rules through overrides.
        for override in placeOverrides {
            hasher.combine(override.id)
            hasher.combine(override.nameOverride)
        }
        for membership in memberships {
            hasher.combine(membership.groupID)
            hasher.combine(membership.mediaID)
            hasher.combine(membership.excluded)
        }
        for observation in faceObservations {
            hasher.combine(observation.id)
            hasher.combine(observation.mediaID)
            hasher.combine(observation.personID)
            hasher.combine(observation.confirmed)
        }
        for memory in memoryRecords {
            hasher.combine(memory.id)
            hasher.combine(memory.mediaID)
            hasher.combine(memory.updatedAt)
            hasher.combine(memory.revision)
        }
        for mediaTag in mediaTags {
            hasher.combine(mediaTag.id)
            hasher.combine(mediaTag.mediaID)
            hasher.combine(mediaTag.tagID)
            hasher.combine(mediaTag.updatedAt)
        }
        return hasher.finalize()
    }

    private func refreshVisibleItems() {
        guard let group else {
            cachedVisibleItemIDs = []
            cachedVisibleItemsByID = [:]
            return
        }
        let personIndex = UserGroupRuleEngine.makePersonIndex(faceObservations)
        cachedPersonIndex = personIndex
        let sorted = UserGroupRuleEngine.visibleItems(for: group, from: items, memberships: memberships, observations: faceObservations, personIDsByMediaID: personIndex)
            .sorted { ($0.effectiveCaptureDate ?? .distantPast, $0.id) > ($1.effectiveCaptureDate ?? .distantPast, $1.id) }
        cachedVisibleItemIDs = sorted.map(\.id)
        cachedVisibleItemsByID = Dictionary(uniqueKeysWithValues: sorted.map { ($0.id, $0) })
        state.gridSections = sections.map(\.itemIDs)
    }

    private var sections: [LibrarySection] {
        LibraryFilterEngine.sections(forVisibleItems: visibleItems, by: .month, sortOrder: .newestFirst)
    }

    var body: some View {
        Group {
            if let group {
                VStack(spacing: 0) {
                    if sections.isEmpty {
                        ContentUnavailableView(
                            String(localized: "This group is empty"),
                            systemImage: group.kind == .smart ? "sparkles" : "folder",
                            description: Text(
                                group.kind == .smart
                                    ? (group.rules.rules.isEmpty
                                        ? String(localized: "Add a condition to collect photos")
                                        : String(localized: "Matching items will appear here automatically."))
                                    : String(localized: "Add photos from the Library context menu or drag them onto this group.")
                            )
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    ForEach(sections) { section in
                                        LibrarySectionView(
                                            section: section,
                                            items: section.itemIDs.compactMap { cachedVisibleItemsByID[$0] },
                                            state: state,
                                            allGroups: groups.filter { $0.kindRaw != UserGroup.Kind.chapter.rawValue },
                                            groupItems: memberships,
                                            group: group
                                        )
                                    }
                                }
                                .reportsLibraryGridColumns(to: state)
                                .padding(.horizontal, PaperMetrics.screenInset)
                                .padding(.vertical, 24)
                                .libraryMarqueeSelection(state: state, selection: selection)
                            }
                            .libraryGridInteraction(state: state, proxy: proxy)
                        }
                    }
                }
                .background(LibraryPalette.content)
                .navigationTitle(group.name)
                .modifier(LibrarySelectionSubtitle(
                    idle: String(localized: "\(visibleItems.count) photos") + " · "
                        + (group.kind == .smart ? String(localized: "Smart") : String(localized: "Manual"))
                ))
                .toolbar {
                    ToolbarItem(placement: .primaryAction) { LibraryZoomControl(state: state) }
                    ToolbarItemGroup {
                        Button(String(localized: "Edit")) { showingEditor = true }
                        if group.kind == .smart {
                            Button(String(localized: "Convert to manual")) {
                                UserGroupRuleEngine.convertToManual(group, items: items, memberships: memberships, observations: faceObservations, context: modelContext)
                                try? modelContext.save()
                            }
                        }
                        if UserGroupRuleEngine.canDelete(group) {
                            Button(String(localized: "Delete group"), role: .destructive) {
                                showingDeleteConfirmation = true
                            }
                        }
                    }
                }
                .sheet(isPresented: $showingEditor) {
                    GroupEditorSheet(
                        kind: group.kind == .smart ? .newSmart : .newManual,
                        group: group
                    )
                }
                .confirmationDialog(String(localized: "Delete group?"), isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
                    Button(String(localized: "Delete"), role: .destructive) {
                        guard UserGroupRuleEngine.canDelete(group) else { return }
                        for membership in memberships where membership.groupID == group.id { modelContext.delete(membership) }
                        modelContext.delete(group)
                        try? modelContext.save()
                    }
                    Button(String(localized: "Cancel"), role: .cancel) {}
                }
            } else {
                ContentUnavailableView(String(localized: "Group unavailable"), systemImage: "folder")
            }
        }
        .onChange(of: visibleItemsKey, initial: true) { _, _ in
            refreshVisibleItems()
        }
    }
}

struct GroupEditorSheet: View {
    let kind: GroupEditorKind
    let group: UserGroup?
    var initialCriteria: LibraryFilterCriteria? = nil
    var onDismiss: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<MediaItem> { $0.deletedAt == nil }) private var items: [MediaItem]
    @Query(sort: \Person.name) private var people: [Person]
    @Query private var faceObservations: [FaceObservation]
    @Query(sort: \Trip.id) private var trips: [Trip]
    @Query(sort: \Tag.displayName) private var tags: [Tag]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var name = ""
    @State private var mode: UserGroupRuleSet.MatchMode = .all
    @State private var rules: [UserGroupRule] = []

    init(
        kind: GroupEditorKind,
        group: UserGroup? = nil,
        initialCriteria: LibraryFilterCriteria? = nil,
        onDismiss: @escaping () -> Void = {}
    ) {
        self.kind = kind
        self.group = group
        self.initialCriteria = initialCriteria
        self.onDismiss = onDismiss
    }

    private var isSmart: Bool { kind == .newSmart || group?.kind == .smart }
    private var matchCount: Int {
        UserGroupRuleEngine.matchingItems(items, ruleSet: UserGroupRuleSet(mode: mode, rules: rules), observations: faceObservations, personIDsByMediaID: UserGroupRuleEngine.makePersonIndex(faceObservations)).count
    }

    var body: some View {
        PaperSheet(isSmart ? String(localized: "Edit smart group") : String(localized: "Edit group")) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 16) {
                GridRow {
                    PaperFormLabel(String(localized: "Group name"))
                    TextField(String(localized: "Group name"), text: $name)
                        .textFieldStyle(.paper)
                        .labelsHidden()
                }
                if isSmart {
                    GridRow {
                        PaperFormLabel(String(localized: "Match"))
                        Picker(String(localized: "Match"), selection: $mode) {
                            Text(String(localized: "All conditions")).tag(UserGroupRuleSet.MatchMode.all)
                            Text(String(localized: "Any condition")).tag(UserGroupRuleSet.MatchMode.any)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    // First-baseline: the label lines up with the first condition's text.
                    GridRow {
                        PaperFormLabel(String(localized: "Conditions"))
                        VStack(alignment: .leading, spacing: 10) {
                            if rules.count > 5 {
                                // A long list scrolls so the buttons stay on screen.
                                ScrollView { ruleList }
                                    .frame(height: 250)
                                    .paperWell(padding: 0)
                            } else if !rules.isEmpty {
                                ruleList
                                    .paperWell()
                            }
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Button {
                                    withAnimation(Motion.animation(Motion.snap, reduceMotion: reduceMotion)) {
                                        rules.append(UserGroupRule(field: .type, value: LibraryMediaTypeFilter.photo.rawValue))
                                    }
                                } label: {
                                    Label(String(localized: "Add condition"), systemImage: "plus")
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(Paper.accent)
                                .accessibilityIdentifier("groupEditor.addCondition")
                                Text(String(format: String(localized: "Matches now message"), matchCount))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(Paper.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        } footer: {
            Button(String(localized: "Cancel")) { dismissEditor() }
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Save")) { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .onAppear {
            guard name.isEmpty else { return }
            if let group {
                name = group.name
                mode = group.rules.mode
                rules = group.rules.rules
            } else if let initialCriteria {
                name = String(localized: "New smart group")
                rules = Self.rules(from: initialCriteria)
            }
        }
        .frame(width: isSmart ? 620 : 440)
        .frame(minHeight: isSmart ? 320 : 0)
    }

    private var ruleList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach($rules) { $rule in
                ruleRow($rule)
            }
        }
        .padding(rules.count > 5 ? 10 : 0)
    }

    /// One condition on a single line. Field and condition menus have fixed
    /// widths so every row's value starts in the same column.
    private func ruleRow(_ rule: Binding<UserGroupRule>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Picker(String(localized: "Field"), selection: fieldBinding(for: rule)) {
                Text(String(localized: "Place")).tag(UserGroupRuleField.place)
                Text(String(localized: "Trip")).tag(UserGroupRuleField.trip)
                Text(String(localized: "Type")).tag(UserGroupRuleField.type)
                Text(String(localized: "Date range")).tag(UserGroupRuleField.dateRange)
                Text(String(localized: "Has memory")).tag(UserGroupRuleField.hasMemory)
                Text(String(localized: "Tag")).tag(UserGroupRuleField.tag)
                Text(String(localized: "Person")).tag(UserGroupRuleField.person)
            }
            .labelsHidden()
            .frame(width: 128)
            Picker(String(localized: "Condition"), selection: rule.op) {
                Text(String(localized: "is")).tag(UserGroupRuleOperator.equals)
                Text(String(localized: "is not")).tag(UserGroupRuleOperator.isNot)
            }
            .labelsHidden()
            .frame(width: 84)
            valueControl(rule)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                withAnimation(Motion.animation(Motion.snap, reduceMotion: reduceMotion)) {
                    rules.removeAll { $0.id == rule.wrappedValue.id }
                }
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(Paper.muted)
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Remove condition"))
            .accessibilityLabel(String(localized: "Remove condition"))
        }
    }

    /// The value as a choice from what is in the library, never a raw ID to type.
    @ViewBuilder
    private func valueControl(_ rule: Binding<UserGroupRule>) -> some View {
        switch rule.wrappedValue.field {
        case .place:
            valuePicker(rule, options: placeOptions)
        case .trip:
            valuePicker(rule, options: tripOptions)
        case .tag:
            valuePicker(rule, options: tagOptions)
        case .type:
            valuePicker(rule, options: [
                (LibraryMediaTypeFilter.photo.rawValue, String(localized: "Photos")),
                (LibraryMediaTypeFilter.video.rawValue, String(localized: "Videos")),
                (LibraryMediaTypeFilter.live.rawValue, String(localized: "Live Photos")),
                (LibraryMediaTypeFilter.screenshot.rawValue, String(localized: "Screenshots")),
            ])
        case .hasMemory:
            valuePicker(rule, options: [
                ("true", String(localized: "Has memory")),
                ("false", String(localized: "No memory")),
            ])
        case .dateRange:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                DatePicker(String(localized: "From date"), selection: dayBinding(rule.value), displayedComponents: .date)
                    .labelsHidden()
                Text(verbatim: "–")
                    .foregroundStyle(Paper.muted)
                DatePicker(String(localized: "To date"), selection: dayBinding(secondaryBinding(for: rule)), displayedComponents: .date)
                    .labelsHidden()
            }
            .datePickerStyle(.field)
        case .person:
            valuePicker(rule, options: personOptions)
        }
    }

    private func valuePicker(_ rule: Binding<UserGroupRule>, options: [(String, String)]) -> some View {
        Picker(String(localized: "Value"), selection: rule.value) {
            // A rule saved before its value disappeared still shows what it holds.
            if !options.contains(where: { $0.0 == rule.wrappedValue.value }) {
                Text(rule.wrappedValue.value.isEmpty ? String(localized: "Choose…") : rule.wrappedValue.value)
                    .tag(rule.wrappedValue.value)
            }
            ForEach(options.indices, id: \.self) { index in
                Text(options[index].1).tag(options[index].0)
            }
        }
        .labelsHidden()
    }

    /// Changing the field starts the value over with that field's first choice.
    private func fieldBinding(for rule: Binding<UserGroupRule>) -> Binding<UserGroupRuleField> {
        Binding(
            get: { rule.wrappedValue.field },
            set: { field in
                guard field != rule.wrappedValue.field else { return }
                rule.wrappedValue.field = field
                rule.wrappedValue.secondaryValue = nil
                switch field {
                case .place: rule.wrappedValue.value = placeOptions.first?.0 ?? ""
                case .trip: rule.wrappedValue.value = tripOptions.first?.0 ?? ""
                case .tag: rule.wrappedValue.value = tagOptions.first?.0 ?? ""
                case .type: rule.wrappedValue.value = LibraryMediaTypeFilter.photo.rawValue
                case .hasMemory: rule.wrappedValue.value = "true"
                case .dateRange:
                    rule.wrappedValue.value = UserGroupRuleSet.localDayKey(for: Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now)
                    rule.wrappedValue.secondaryValue = UserGroupRuleSet.localDayKey(for: .now)
                case .person: rule.wrappedValue.value = personOptions.first?.0 ?? ""
                }
            }
        )
    }

    /// A YYYY-MM-DD rule value edited with a date picker.
    private func dayBinding(_ value: Binding<String>) -> Binding<Date> {
        Binding(
            get: {
                let parts = value.wrappedValue.split(separator: "-").compactMap { Int($0) }
                guard parts.count == 3,
                      let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return .now }
                return date
            },
            set: { value.wrappedValue = UserGroupRuleSet.localDayKey(for: $0) }
        )
    }

    private var placeOptions: [(String, String)] {
        PlaceNames.options(for: items).map { ($0.id, $0.name) }
    }

    private var tripOptions: [(String, String)] {
        trips.map { ($0.id, $0.effectiveName) }
            .sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
    }

    private var personOptions: [(String, String)] {
        people.filter { !$0.hidden && $0.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
            .map { ($0.id, $0.name ?? String(localized: "Unnamed person")) }
    }

    private var tagOptions: [(String, String)] {
        tags.map { ($0.id, $0.displayName) }
            .sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
    }

    private func dismissEditor() {
        onDismiss()
        dismiss()
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let ruleSet = UserGroupRuleSet(mode: mode, rules: isSmart ? rules : [])
        if let group {
            group.name = trimmed
            group.kind = isSmart ? .smart : .manual
            group.rules = ruleSet
            group.updatedAt = .now
        } else {
            modelContext.insert(UserGroup(name: trimmed, kind: isSmart ? .smart : .manual, rules: ruleSet))
        }
        try? modelContext.save()
        dismissEditor()
    }

    private func secondaryBinding(for rule: Binding<UserGroupRule>) -> Binding<String> {
        Binding(
            get: { rule.wrappedValue.secondaryValue ?? "" },
            set: { rule.wrappedValue.secondaryValue = $0.isEmpty ? nil : $0 }
        )
    }

    private static func rules(from criteria: LibraryFilterCriteria) -> [UserGroupRule] {
        var result: [UserGroupRule] = []
        if let placeID = criteria.placeID { result.append(UserGroupRule(field: .place, value: placeID)) }
        if let tripKey = criteria.tripKey { result.append(UserGroupRule(field: .trip, value: tripKey)) }
        if criteria.mediaType != .all { result.append(UserGroupRule(field: .type, value: criteria.mediaType.rawValue)) }
        if criteria.fromDate != nil || criteria.toDate != nil {
            let from = criteria.fromDate.map { UserGroupRuleSet.localDayKey(for: $0) } ?? "0001-01-01"
            let to = criteria.toDate.map { UserGroupRuleSet.localDayKey(for: $0) }
            result.append(UserGroupRule(field: .dateRange, value: from, secondaryValue: to))
        }
        if criteria.memoryFilter != .all {
            result.append(UserGroupRule(field: .hasMemory, value: criteria.memoryFilter == .hasMemory ? "true" : "false"))
        }
        if let tagID = criteria.tagID { result.append(UserGroupRule(field: .tag, value: tagID)) }
        if let personID = criteria.personID { result.append(UserGroupRule(field: .person, value: personID)) }
        return result
    }
}
