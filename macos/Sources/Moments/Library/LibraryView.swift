import Foundation
import SwiftUI
import SwiftData

private enum LibraryPalette {
    static let sidebar = Color(red: 0.969, green: 0.906, blue: 0.863)
    static let content = Color(red: 0.984, green: 0.945, blue: 0.918)
    static let ink = Color(red: 0.227, green: 0.165, blue: 0.141)
    static let muted = Color(red: 0.478, green: 0.365, blue: 0.314)
    static let accent = Color(red: 0.690, green: 0.290, blue: 0.184)
    static let line = Color(red: 0.937, green: 0.855, blue: 0.796)
    static let rule = Color(red: 0.902, green: 0.804, blue: 0.741)
}

private enum LibraryScrollTarget {
    static func section(_ id: String) -> String { "section:\(id)" }
    static func item(_ id: String) -> String { "item:\(id)" }
}

struct LibraryView: View {
    @Environment(SelectionModel.self) private var selection
    @Environment(ImportController.self) private var importController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Keep the common Library query free of explicit screenshots in SwiftData.
    // The screenshot segment switches to the second descriptor without making
    // the normal 5k-item browsing path carry those models through filtering.
    @Query(filter: #Predicate<MediaItem> { $0.isScreenshot == false }, sort: \MediaItem.captureDate)
    private var regularItems: [MediaItem]
    @Query(filter: #Predicate<MediaItem> { $0.isScreenshot == true }, sort: \MediaItem.captureDate)
    private var screenshotItems: [MediaItem]
    @Query(sort: \Memory.updatedAt)
    private var memoryRecords: [Memory]
    @Query(sort: \Trip.id)
    private var allTrips: [Trip]
    @Query(sort: \Place.id)
    private var allPlaces: [Place]
    @Query(sort: \PlaceOverride.id)
    private var placeOverrides: [PlaceOverride]
    @Query(sort: \UserGroup.name)
    private var allGroups: [UserGroup]
    @Query private var groupItems: [UserGroupItem]

    let state: LibraryViewState
    @Binding var firstLaunchCompleted: Bool

    @AppStorage("moments.library.type") private var typeRaw = LibraryMediaTypeFilter.all.rawValue
    @AppStorage("moments.library.grouping") private var groupingRaw = LibraryGrouping.trip.rawValue
    @AppStorage("moments.library.fromDate") private var fromDateInterval = 0.0
    @AppStorage("moments.library.toDate") private var toDateInterval = 0.0
    @AppStorage("moments.library.place") private var placeFilterID = ""
    @AppStorage("moments.library.trip") private var tripFilterKey = ""
    @AppStorage("moments.library.memory") private var memoryFilterRaw = LibraryMemoryFilter.all.rawValue

    @State private var cachedSections: [LibrarySection] = []
    @State private var cachedItemByID: [String: MediaItem] = [:]
    @State private var cachedVisibleCount = 0
    @State private var hasGrouped = false
    @State private var showingSmartGroupEditor = false

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
            memoryFilter: LibraryMemoryFilter(rawValue: memoryFilterRaw) ?? .all
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

    private var places: [LibraryPlaceOption] {
        var options: [String: LibraryPlaceOption] = [:]
        for item in allItems {
            // One row per name: unnamed spots are listed under the area or
            // city that names them, and the filter matches all of them.
            if let place = item.place, let named = PlaceDisplayName.namingPlace(of: place) {
                options[named.id] = LibraryPlaceOption(id: named.id, name: named.displayName)
            }
            if let override = item.placeOverrideName?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
                options["override:\(override)"] = LibraryPlaceOption(id: "override:\(override)", name: override)
            }
        }
        return options.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var trips: [String] {
        Array(Set(allItems.compactMap(\.tripID))).sorted()
    }

    private var selectedPlaceName: String? {
        places.first(where: { $0.id == placeFilterID })?.name
    }

    private var selectedTripName: String? {
        guard !tripFilterKey.isEmpty else { return nil }
        return allItems.first(where: { $0.tripID == tripFilterKey })?.trip?.effectiveName ?? tripFilterKey
    }

    private var selectedMemoryFilter: LibraryMemoryFilter {
        LibraryMemoryFilter(rawValue: memoryFilterRaw) ?? .all
    }

    /// A lightweight query signature for the cached regroup. Memory presence,
    /// trip/place names, and overrides come from their own queries so this
    /// token never faults `item.memories` for every media item during a render.
    private var groupingKey: Int {
        var hasher = Hasher()
        hasher.combine(typeRaw)
        hasher.combine(groupingRaw)
        hasher.combine(fromDateInterval)
        hasher.combine(toDateInterval)
        hasher.combine(placeFilterID)
        hasher.combine(tripFilterKey)
        hasher.combine(memoryFilterRaw)
        hasher.combine(state.focusedMemoryItemID)
        hasher.combine(selection.libraryScope?.itemIDs)
        for item in items {
            hasher.combine(item.id)
            hasher.combine(item.captureDate)
            hasher.combine(item.userCorrectedCaptureDateUTC)
            hasher.combine(item.isScreenshot)
            hasher.combine(item.kindRaw)
            hasher.combine(item.tripID)
            hasher.combine(item.place?.id)
            hasher.combine(item.updatedAt)
        }
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
        .onChange(of: allItems.count, initial: true) { _, count in
            if count > 0 { firstLaunchCompleted = true }
        }
        .task(id: groupingKey) { regroup() }
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
    }

    private var libraryHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 22) {
                libraryHeaderTitle
                libraryTypePicker
                Spacer(minLength: 8)
                libraryGroupingPicker
            }
            VStack(alignment: .leading, spacing: 12) {
                libraryHeaderTitle
                HStack(alignment: .center, spacing: 22) {
                    libraryTypePicker
                    Spacer(minLength: 8)
                    libraryGroupingPicker
                }
            }
        }
        .padding(.horizontal, 34)
        .padding(.top, 28)
        .padding(.bottom, 18)
        .overlay(alignment: .bottom) { Rectangle().fill(LibraryPalette.line).frame(height: 1) }
    }

    private var libraryHeaderTitle: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text(String(localized: "Library"))
                .font(.system(size: 34, weight: .medium, design: .serif))
                .foregroundStyle(LibraryPalette.ink)
                .lineLimit(1)
                .layoutPriority(1)
                .minimumScaleFactor(0.7)
            Text("\(cachedVisibleCount) \(String(localized: "photos"))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(LibraryPalette.muted)
                .lineLimit(1)
                .accessibilityIdentifier("library.photoCount")
                .accessibilityValue(String(cachedVisibleCount))
        }
        // Never squeezed: a compressed title wraps one letter per line.
        .fixedSize()
    }

    private var libraryTypePicker: some View {
        Picker(String(localized: "Media type"), selection: $typeRaw) {
            Text(String(localized: "All")).tag(LibraryMediaTypeFilter.all.rawValue)
            Text(String(localized: "Photos")).tag(LibraryMediaTypeFilter.photo.rawValue)
            Text(String(localized: "Videos")).tag(LibraryMediaTypeFilter.video.rawValue)
            Text(String(localized: "Live Photos")).tag(LibraryMediaTypeFilter.live.rawValue)
            Text(String(localized: "Screenshots")).tag(LibraryMediaTypeFilter.screenshot.rawValue)
        }
        .pickerStyle(.segmented)
        // The segments name themselves; a visible "Media type" label wrapped
        // onto two lines in narrow windows. VoiceOver still reads it.
        .labelsHidden()
        .frame(maxWidth: 410)
        .accessibilityIdentifier("library.type-filter")
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
            // Chips never truncate; when they do not fit, scroll rather than clip.
            ViewThatFits(in: .horizontal) {
                filterChipRow
                ScrollView(.horizontal) { filterChipRow }
                    .scrollIndicators(.hidden)
            }

            if hasActiveFilters || selection.libraryScope != nil {
                HStack(spacing: 7) {
                    if let scope = selection.libraryScope {
                        filterChip(scope.title) { selection.libraryScope = nil }
                            .accessibilityIdentifier("library.scope-chip")
                    }
                    if let selectedPlaceName {
                        filterChip("\(String(localized: "Place:")) \(selectedPlaceName)") { placeFilterID = "" }
                    }
                    if let selectedTripName {
                        filterChip("\(String(localized: "Trip:")) \(selectedTripName)") { tripFilterKey = "" }
                    }
                    if let dateLabel = dateFilterLabel {
                        filterChip(dateLabel) {
                            fromDateInterval = 0
                            toDateInterval = 0
                        }
                    }
                    if selectedMemoryFilter != .all {
                        filterChip(memoryFilterLabel(selectedMemoryFilter)) { memoryFilterRaw = LibraryMemoryFilter.all.rawValue }
                    }
                    Button(String(localized: "Clear filters")) { clearFilters() }
                        .buttonStyle(.link)
                        .font(.caption)
                        .foregroundStyle(LibraryPalette.muted)
                }
            }

            HStack {
                Text(String(format: String(localized: "Filtered count"), cachedVisibleCount))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(LibraryPalette.muted)
                Spacer(minLength: 12)
                // Only a real filter can become a smart group. Its own row
                // keeps the chips at full width and the button on one line.
                // A scope is a one-off list, not a rule a smart group could keep.
                if criteria.isFiltered && selection.libraryScope == nil {
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
        .padding(.horizontal, 34)
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) { Rectangle().fill(LibraryPalette.line).frame(height: 1) }
        .sheet(isPresented: $showingSmartGroupEditor) {
            GroupEditorSheet(kind: .newSmart, group: nil, initialCriteria: criteria)
        }
    }

    private var filterChipRow: some View {
        HStack(spacing: 8) {
            filterMenu(label: String(localized: "Place"), selected: selectedPlaceName) {
                Button(String(localized: "All places")) { placeFilterID = "" }
                if !places.isEmpty { Divider() }
                ForEach(places) { place in
                    Button {
                        placeFilterID = place.id
                    } label: {
                        filterMenuLabel(place.name, selected: place.id == placeFilterID)
                    }
                }
            }

            filterMenu(label: String(localized: "Trip"), selected: selectedTripName) {
                Button(String(localized: "All trips")) { tripFilterKey = "" }
                if !trips.isEmpty { Divider() }
                ForEach(trips, id: \.self) { trip in
                    Button {
                        tripFilterKey = trip
                    } label: {
                        filterMenuLabel(selectedTripName(for: trip), selected: trip == tripFilterKey)
                    }
                }
            }

            dateFilterMenu
            memoryFilterMenu

            Spacer(minLength: 0)
        }
    }

    private func filterMenu<Content: View>(label: String, selected: String?, @ViewBuilder content: () -> Content) -> some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 5) {
                Text(selected.map(Self.chipTitle) ?? label)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.48), in: Capsule())
        .overlay(Capsule().stroke(LibraryPalette.line, lineWidth: 1))
        .foregroundStyle(LibraryPalette.ink)
    }

    /// A long place or trip name would push the other chips out of the row;
    /// the full name stays in the menu and in the active-filter chip below.
    static func chipTitle(_ name: String) -> String {
        name.count > 22 ? String(name.prefix(21)) + "…" : name
    }

    private func filterMenuLabel(_ text: String, selected: Bool) -> some View {
        Label(text, systemImage: selected ? "checkmark" : "circle")
    }

    private var dateFilterMenu: some View {
        Menu {
            Toggle(String(localized: "From date"), isOn: Binding(
                get: { fromDateInterval != 0 },
                set: { enabled in
                    fromDateInterval = enabled ? (fromDateInterval == 0 ? Date.now.timeIntervalSince1970 : fromDateInterval) : 0
                }
            ))
            if fromDateInterval != 0 {
                DatePicker(String(localized: "From date"), selection: fromDateBinding, displayedComponents: .date)
            }
            Toggle(String(localized: "To date"), isOn: Binding(
                get: { toDateInterval != 0 },
                set: { enabled in
                    toDateInterval = enabled ? (toDateInterval == 0 ? Date.now.timeIntervalSince1970 : toDateInterval) : 0
                }
            ))
            if toDateInterval != 0 {
                DatePicker(String(localized: "To date"), selection: toDateBinding, displayedComponents: .date)
            }
            Divider()
            Button(String(localized: "All dates")) {
                fromDateInterval = 0
                toDateInterval = 0
            }
        } label: {
            filterMenuTitle(String(localized: "Date"), selected: dateFilterLabel != nil)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.48), in: Capsule())
        .overlay(Capsule().stroke(LibraryPalette.line, lineWidth: 1))
    }

    private var memoryFilterMenu: some View {
        Menu {
            Button {
                memoryFilterRaw = LibraryMemoryFilter.all.rawValue
            } label: {
                filterMenuLabel(String(localized: "All memories"), selected: selectedMemoryFilter == .all)
            }
            Button {
                memoryFilterRaw = LibraryMemoryFilter.hasMemory.rawValue
            } label: {
                filterMenuLabel(String(localized: "Has memory"), selected: selectedMemoryFilter == .hasMemory)
            }
            Button {
                memoryFilterRaw = LibraryMemoryFilter.noMemory.rawValue
            } label: {
                filterMenuLabel(String(localized: "No memory"), selected: selectedMemoryFilter == .noMemory)
            }
        } label: {
            filterMenuTitle(String(localized: "Memory"), selected: selectedMemoryFilter != .all)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.48), in: Capsule())
        .overlay(Capsule().stroke(LibraryPalette.line, lineWidth: 1))
    }

    private func filterMenuTitle(_ label: String, selected: Bool) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .fontWeight(selected ? .semibold : .regular)
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(selected ? LibraryPalette.accent : LibraryPalette.ink)
    }

    private func filterChip(_ text: String, remove: @escaping () -> Void) -> some View {
        Button(action: remove) {
            HStack(spacing: 5) {
                Text(text)
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(LibraryPalette.accent, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 34) {
                    ForEach(cachedSections) { section in
                        LibrarySectionView(
                            section: section,
                            items: section.itemIDs.compactMap { cachedItemByID[$0] },
                            state: state,
                            allGroups: allGroups,
                            groupItems: groupItems
                        )
                        .id(LibraryScrollTarget.section(section.id))
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 34)
                .padding(.vertical, 24)
            }
            .scrollIndicators(.visible)
            // The scroll view opens at the section that was at the top when
            // the user left, in its first layout. Scrolling there after
            // onAppear showed the top first and then jumped.
            .scrollPosition(
                id: Binding(get: { state.topSectionScrollID }, set: { state.topSectionScrollID = $0 }),
                anchor: .top
            )
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

    private var fromDateBinding: Binding<Date> {
        Binding(
            get: { fromDateInterval == 0 ? .now : Date(timeIntervalSince1970: fromDateInterval) },
            set: { fromDateInterval = $0.timeIntervalSince1970 }
        )
    }

    private var toDateBinding: Binding<Date> {
        Binding(
            get: { toDateInterval == 0 ? .now : Date(timeIntervalSince1970: toDateInterval) },
            set: { toDateInterval = $0.timeIntervalSince1970 }
        )
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
        placeFilterID.isEmpty == false || tripFilterKey.isEmpty == false || dateFilterLabel != nil || selectedMemoryFilter != .all
    }

    private func memoryFilterLabel(_ filter: LibraryMemoryFilter) -> String {
        switch filter {
        case .all: return String(localized: "All memories")
        case .hasMemory: return String(localized: "Has memory")
        case .noMemory: return String(localized: "No memory")
        }
    }

    private func selectedTripName(for tripID: String) -> String {
        allItems.first(where: { $0.tripID == tripID })?.trip?.effectiveName ?? tripID
    }

    private func clearFilters() {
        fromDateInterval = 0
        toDateInterval = 0
        placeFilterID = ""
        tripFilterKey = ""
        memoryFilterRaw = LibraryMemoryFilter.all.rawValue
        typeRaw = LibraryMediaTypeFilter.all.rawValue
        selection.libraryScope = nil
    }

    private func regroup() {
        // A scope from another screen narrows the grid only; the published
        // ids below stay on the regular filters so the maps do not shrink.
        let scopedItems = selection.libraryScope.map { scope in
            items.filter { scope.itemIDs.contains($0.id) }
        } ?? items
        let filtered = LibraryFilterEngine.filteredItems(scopedItems, by: criteria)
        let visible = LibraryFilterEngine.filteredItems(
            scopedItems,
            by: criteria,
            preservingEditingItemID: state.focusedMemoryItemID
        )
        cachedVisibleCount = visible.count
        cachedItemByID = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0) })
        cachedSections = LibraryFilterEngine.sections(forVisibleItems: visible, by: grouping, sortOrder: .newestFirst)
        hasGrouped = true
        let publishedVisible = Set(LibraryFilterEngine.publishedItems(allItems, by: criteria).map(\.id))
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

        guard let target = sections.first(where: { $0.itemIDs.contains(focus) }) else { return }
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

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 175, maximum: 300), spacing: 24, alignment: .top)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(section.title)
                    .font(.system(size: 21, weight: .medium, design: .serif))
                    .foregroundStyle(LibraryPalette.ink)
                Text(dateSpan)
                    .font(.caption)
                    .foregroundStyle(LibraryPalette.muted)
                Spacer()
                Text("\(section.count) \(String(localized: "photos"))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(LibraryPalette.muted)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 28) {
                ForEach(items, id: \.id) { item in
                    LibraryPhotoCell(item: item, state: state, allGroups: allGroups, groupItems: groupItems, group: group)
                }
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

private struct LibraryPhotoCell: View {
    @Environment(SelectionModel.self) private var selection
    @Environment(\.modelContext) private var modelContext
    let item: MediaItem
    let state: LibraryViewState
    let allGroups: [UserGroup]
    let groupItems: [UserGroupItem]
    var group: UserGroup? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .topLeading) {
                Button {
                    selection.select(item.id)
                } label: {
                    ThumbnailView(item: item, width: 560, height: 420)
                        .aspectRatio(1.33, contentMode: .fit)
                        .padding(5)
                        .background(Color.white)
                        .shadow(color: .black.opacity(0.12), radius: 8, y: 5)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("library.photo.\(item.id)")
                .accessibilityValue(selection.isSelected(item.id) ? "Selected" : "Not selected")
                .accessibilityAddTraits(selection.isSelected(item.id) ? .isSelected : [])
                .id(LibraryScrollTarget.item(item.id))
                .onAppear {
                    if state.pendingRevealItemID == item.id { state.appearedRevealItemID = item.id }
                }

                HStack(spacing: 6) {
                    Button {
                        selection.toggle(item.id)
                    } label: {
                        Image(systemName: selection.isSelected(item.id) ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.42))
                            .shadow(radius: 2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Select"))

                    Spacer()

                    Button {
                        item.setFavorite(!item.isFavorite, context: modelContext)
                        try? modelContext.save()
                    } label: {
                        Image(systemName: item.isFavorite ? "star.fill" : "star")
                            .font(.title3)
                            .foregroundStyle(item.isFavorite ? .yellow : .white)
                            .shadow(radius: 2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Favorite"))
                }
                .padding(11)
            }

            MemoryEditor(item: item, state: state)
        }
        .contextMenu {
            Button(String(localized: "Select")) { selection.select(item.id) }
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
        }
        .onDrag { NSItemProvider(object: item.id as NSString) }
    }
}

private struct MemoryEditor: View {
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

struct ReviewListView: View {
    @Query private var items: [MediaItem]
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
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(localized: "To review"))
                    .font(.system(size: 30, weight: .medium, design: .serif))
                    .foregroundStyle(LibraryPalette.ink)
                Spacer()
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
            } else {
                List(pending, id: \.id) { item in
                    HStack(spacing: 12) {
                        Button {
                            selection.select(item.id)
                            selection.openViewer(item.id, in: pending.map(\.id))
                        } label: {
                            ThumbnailView(item: item, width: 180, height: 140)
                                .frame(width: 90, height: 70)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help(String(localized: "Open photo"))
                        .accessibilityIdentifier("review.photo.\(item.id)")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title.isEmpty ? item.id : item.title)
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
                    .padding(.vertical, 4)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .padding(34)
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

    @Environment(\.modelContext) private var modelContext
    @Query private var groups: [UserGroup]
    @Query private var items: [MediaItem]
    @Query private var memberships: [UserGroupItem]
    @Query private var memoryRecords: [Memory]
    @Query private var mediaTags: [MediaTag]
    @Query(sort: \PlaceOverride.id) private var placeOverrides: [PlaceOverride]
    @State private var showingEditor = false
    @State private var showingDeleteConfirmation = false
    @State private var cachedVisibleItemIDs: [String] = []
    @State private var cachedVisibleItemsByID: [String: MediaItem] = [:]

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
        let sorted = UserGroupRuleEngine.visibleItems(for: group, from: items, memberships: memberships)
            .sorted { ($0.effectiveCaptureDate ?? .distantPast, $0.id) > ($1.effectiveCaptureDate ?? .distantPast, $1.id) }
        cachedVisibleItemIDs = sorted.map(\.id)
        cachedVisibleItemsByID = Dictionary(uniqueKeysWithValues: sorted.map { ($0.id, $0) })
    }

    private var sections: [LibrarySection] {
        LibraryFilterEngine.sections(forVisibleItems: visibleItems, by: .month, sortOrder: .newestFirst)
    }

    var body: some View {
        Group {
            if let group {
                VStack(spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(group.name)
                            .font(.system(size: 34, weight: .medium, design: .serif))
                            .foregroundStyle(LibraryPalette.ink)
                        Text("\(visibleItems.count) \(String(localized: "photos"))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(LibraryPalette.muted)
                        Spacer()
                        Text(group.kind == .smart ? String(localized: "Smart") : String(localized: "Manual"))
                            .font(.caption)
                            .foregroundStyle(LibraryPalette.muted)
                    }
                    .padding(.horizontal, 34)
                    .padding(.top, 28)
                    .padding(.bottom, 18)
                    .overlay(alignment: .bottom) { Rectangle().fill(LibraryPalette.line).frame(height: 1) }

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
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 34) {
                                ForEach(sections) { section in
                                    LibrarySectionView(
                                        section: section,
                                        items: section.itemIDs.compactMap { cachedVisibleItemsByID[$0] },
                                        state: state,
                                        allGroups: groups,
                                        groupItems: memberships,
                                        group: group
                                    )
                                }
                            }
                            .padding(34)
                        }
                    }
                }
                .background(LibraryPalette.content)
                .toolbar {
                    ToolbarItemGroup {
                        Button(String(localized: "Edit")) { showingEditor = true }
                        if group.kind == .smart {
                            Button(String(localized: "Convert to manual")) {
                                UserGroupRuleEngine.convertToManual(group, items: items, memberships: memberships, context: modelContext)
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
    @Query private var items: [MediaItem]
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
        UserGroupRuleEngine.matchingItems(items, ruleSet: UserGroupRuleSet(mode: mode, rules: rules)).count
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "Group name"), text: $name)
                }
                if isSmart {
                    Section {
                        Picker(String(localized: "Match"), selection: $mode) {
                            Text(String(localized: "All conditions")).tag(UserGroupRuleSet.MatchMode.all)
                            Text(String(localized: "Any condition")).tag(UserGroupRuleSet.MatchMode.any)
                        }
                        .pickerStyle(.segmented)

                        ForEach($rules) { $rule in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Picker(String(localized: "Field"), selection: $rule.field) {
                                        Text(String(localized: "Place")).tag(UserGroupRuleField.place)
                                        Text(String(localized: "Trip")).tag(UserGroupRuleField.trip)
                                        Text(String(localized: "Type")).tag(UserGroupRuleField.type)
                                        Text(String(localized: "Date range")).tag(UserGroupRuleField.dateRange)
                                        Text(String(localized: "Has memory")).tag(UserGroupRuleField.hasMemory)
                                        Text(String(localized: "Tag")).tag(UserGroupRuleField.tag)
                                    }
                                    Picker(String(localized: "Condition"), selection: $rule.op) {
                                        Text(String(localized: "is")).tag(UserGroupRuleOperator.equals)
                                        Text(String(localized: "is not")).tag(UserGroupRuleOperator.isNot)
                                    }
                                    Button(role: .destructive) {
                                        rules.removeAll { $0.id == rule.id }
                                    } label: {
                                        Image(systemName: "minus.circle")
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(String(localized: "Remove condition"))
                                }
                                TextField(rule.field == .dateRange ? String(localized: "From date (YYYY-MM-DD)") : String(localized: "Value"), text: $rule.value)
                                if rule.field == .dateRange {
                                    TextField(String(localized: "To date (YYYY-MM-DD)"), text: secondaryBinding(for: $rule))
                                }
                            }
                        }

                        Button {
                            rules.append(UserGroupRule(field: .place, value: ""))
                        } label: {
                            Label(String(localized: "Add condition"), systemImage: "plus")
                        }
                        Text(String(format: String(localized: "Matches now message"), matchCount))
                            .font(.caption)
                            .foregroundStyle(LibraryPalette.muted)
                    }
                }
            }
            .navigationTitle(isSmart ? String(localized: "Edit smart group") : String(localized: "Edit group"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismissEditor() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save")) { save() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
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
        }
        .frame(minWidth: 560, minHeight: 440)
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
        return result
    }
}
