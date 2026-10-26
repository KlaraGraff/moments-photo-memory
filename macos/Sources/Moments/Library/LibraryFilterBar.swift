import SwiftData
import SwiftUI

/// The Library's filter chips (place, trip, date, memory, person) and the
/// row of active filters. The Library and the Map both show it; the filters
/// live in shared app storage, so changing one screen changes the other.
struct LibraryFilterChips: View {
    /// The Library also shows a one-off "Show in Library" scope as a chip.
    var showsScope = false

    @Environment(SelectionModel.self) private var selection
    @Query private var allItems: [MediaItem]
    @Query(sort: \Person.name) private var people: [Person]

    @AppStorage(LibraryFilterKeys.type) private var typeRaw = LibraryMediaTypeFilter.all.rawValue
    @AppStorage(LibraryFilterKeys.fromDate) private var fromDateInterval = 0.0
    @AppStorage(LibraryFilterKeys.toDate) private var toDateInterval = 0.0
    @AppStorage(LibraryFilterKeys.place) private var placeFilterID = ""
    @AppStorage(LibraryFilterKeys.trip) private var tripFilterKey = ""
    @AppStorage(LibraryFilterKeys.memory) private var memoryFilterRaw = LibraryMemoryFilter.all.rawValue
    @AppStorage(LibraryFilterKeys.person) private var personFilterID = ""
    @AppStorage(LibraryFilterKeys.dateMode) private var dateModeRaw = DateFilterMode.days.rawValue
    @State private var showingDatePicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Chips never truncate; when they do not fit, scroll rather than clip.
            ViewThatFits(in: .horizontal) {
                chipRow
                ScrollView(.horizontal) { chipRow }
                    .scrollIndicators(.hidden)
            }

            if hasActiveFilters || (showsScope && selection.libraryScope != nil) {
                HStack(spacing: 7) {
                    if showsScope, let scope = selection.libraryScope {
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
                        .accessibilityIdentifier("filter.date-chip")
                    }
                    if selectedMemoryFilter != .all {
                        filterChip(memoryFilterLabel(selectedMemoryFilter)) { memoryFilterRaw = LibraryMemoryFilter.all.rawValue }
                    }
                    if let selectedPersonName {
                        filterChip("\(String(localized: "Person:")) \(selectedPersonName)") { personFilterID = "" }
                    }
                    Button(String(localized: "Clear filters")) { clearFilters() }
                        .buttonStyle(.link)
                        .font(.caption)
                        .foregroundStyle(LibraryPalette.muted)
                }
            }
        }
        .onChange(of: people.map(\.id), initial: true) { _, ids in
            if !personFilterID.isEmpty && !ids.contains(personFilterID) { personFilterID = "" }
        }
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
        guard !placeFilterID.isEmpty else { return nil }
        return places.first(where: { $0.id == placeFilterID })?.name
    }

    private var selectedTripName: String? {
        guard !tripFilterKey.isEmpty else { return nil }
        return selectedTripName(for: tripFilterKey)
    }

    private func selectedTripName(for tripID: String) -> String {
        allItems.first(where: { $0.tripID == tripID })?.trip?.effectiveName ?? tripID
    }

    private var selectedMemoryFilter: LibraryMemoryFilter {
        LibraryMemoryFilter(rawValue: memoryFilterRaw) ?? .all
    }

    private var visiblePeople: [Person] {
        people.filter { !$0.hidden && ($0.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) }
    }

    private var selectedPersonName: String? {
        guard !personFilterID.isEmpty else { return nil }
        return people.first(where: { $0.id == personFilterID })?.name
    }

    private var dateFilterLabel: String? {
        DateFilterMode.label(
            from: fromDateInterval == 0 ? nil : Date(timeIntervalSince1970: fromDateInterval),
            to: toDateInterval == 0 ? nil : Date(timeIntervalSince1970: toDateInterval),
            modeRaw: dateModeRaw
        ).map { "\(String(localized: "Date:")) \($0)" }
    }

    /// Days with photos, for the dots in the date picker.
    private var photoDays: Set<Date> {
        let calendar = Calendar.current
        return Set(allItems.compactMap { $0.effectiveCaptureDate.map(calendar.startOfDay(for:)) })
    }

    private var hasActiveFilters: Bool {
        !placeFilterID.isEmpty || !tripFilterKey.isEmpty || dateFilterLabel != nil || selectedMemoryFilter != .all || !personFilterID.isEmpty
    }

    private func memoryFilterLabel(_ filter: LibraryMemoryFilter) -> String {
        switch filter {
        case .all: return String(localized: "All memories")
        case .hasMemory: return String(localized: "Has memory")
        case .noMemory: return String(localized: "No memory")
        }
    }

    private func clearFilters() {
        fromDateInterval = 0
        toDateInterval = 0
        placeFilterID = ""
        tripFilterKey = ""
        memoryFilterRaw = LibraryMemoryFilter.all.rawValue
        personFilterID = ""
        typeRaw = LibraryMediaTypeFilter.all.rawValue
        UserDefaults.standard.removeObject(forKey: LibraryFilterKeys.query)
        selection.libraryScope = nil
    }

    private var chipRow: some View {
        HStack(spacing: 8) {
            filterMenu(label: String(localized: "Place"), systemImage: "mappin.and.ellipse", identifier: "filter.place", selected: selectedPlaceName) {
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

            filterMenu(label: String(localized: "Trip"), systemImage: "airplane.departure", identifier: "filter.trip", selected: selectedTripName) {
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
            personFilterMenu

            Spacer(minLength: 0)
        }
    }

    private func filterMenu<Content: View>(label: String, systemImage: String, identifier: String, selected: String?, @ViewBuilder content: () -> Content) -> some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .imageScale(.small)
                    .accessibilityHidden(true)
                Text(selected.map(Self.chipTitle) ?? label)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // Chip labels read as ink; the app accent would turn every chip red.
        .tint(LibraryPalette.ink)
        .fixedSize()
        .paperChip(selected: selected != nil)
        .foregroundStyle(LibraryPalette.ink)
        .accessibilityIdentifier(identifier)
    }

    /// A long place or trip name would push the other chips out of the row;
    /// the full name stays in the menu and in the active-filter chip below.
    static func chipTitle(_ name: String) -> String {
        name.count > 22 ? String(name.prefix(21)) + "…" : name
    }

    private func filterMenuLabel(_ text: String, selected: Bool) -> some View {
        Label(text, systemImage: selected ? "checkmark" : "circle")
    }

    /// A calendar in a popover rather than a menu: picking a day must not
    /// apply anything until a day is actually clicked.
    private var dateFilterMenu: some View {
        Button {
            showingDatePicker.toggle()
        } label: {
            filterMenuTitle(String(localized: "Date"), systemImage: "calendar", selected: dateFilterLabel != nil)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .paperChip(selected: dateFilterLabel != nil)
        .accessibilityIdentifier("filter.date")
        .popover(isPresented: $showingDatePicker, arrowEdge: .bottom) {
            DateFilterPicker(
                fromInterval: $fromDateInterval,
                toInterval: $toDateInterval,
                modeRaw: $dateModeRaw,
                photoDays: photoDays
            )
        }
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
            filterMenuTitle(String(localized: "Memory"), systemImage: "quote.bubble", selected: selectedMemoryFilter != .all)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // Chip labels read as ink; the app accent would turn every chip red.
        .tint(LibraryPalette.ink)
        .fixedSize()
        .paperChip(selected: selectedMemoryFilter != .all)
    }

    private var personFilterMenu: some View {
        Menu {
            Button { personFilterID = "" } label: {
                filterMenuLabel(String(localized: "All people"), selected: personFilterID.isEmpty)
            }
            if !visiblePeople.isEmpty { Divider() }
            ForEach(visiblePeople, id: \.id) { person in
                Button { personFilterID = person.id } label: {
                    filterMenuLabel(person.name ?? String(localized: "Unnamed person"), selected: person.id == personFilterID)
                }
            }
        } label: {
            filterMenuTitle(String(localized: "Person"), systemImage: "person", selected: !personFilterID.isEmpty)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // Chip labels read as ink; the app accent would turn every chip red.
        .tint(LibraryPalette.ink)
        .fixedSize()
        .paperChip(selected: !personFilterID.isEmpty)
    }

    private func filterMenuTitle(_ label: String, systemImage: String, selected: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .imageScale(.small)
                .accessibilityHidden(true)
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

}

/// Where the Library filters are kept. Every screen that filters by them
/// reads the same keys, so they stay in step.
enum LibraryFilterKeys {
    static let type = "moments.library.type"
    static let fromDate = "moments.library.fromDate"
    static let toDate = "moments.library.toDate"
    static let place = "moments.library.place"
    static let trip = "moments.library.trip"
    static let memory = "moments.library.memory"
    static let person = "moments.library.person"
    /// Date filter as picked: a day, a range, after/before a day, a month or a
    /// year. The engine only reads fromDate/toDate; this names the choice.
    static let dateMode = "moments.library.dateMode"
    static let query = "moments.library.query"

    /// Clears every filter (not the media type) on every screen.
    static func clearAll(_ defaults: UserDefaults = .standard) {
        for key in [fromDate, toDate, place, trip, memory, person, dateMode, query] {
            defaults.removeObject(forKey: key)
        }
    }
}

/// Publishes the ids that pass the Library filters into `SelectionModel`
/// for screens other than the Library (the Library publishes its own while
/// it is open). Put it in the background of a screen that reads them.
struct LibraryFilterPublisher: View {
    @Environment(SelectionModel.self) private var selection
    @Query private var items: [MediaItem]
    @Query private var faceObservations: [FaceObservation]

    @AppStorage(LibraryFilterKeys.type) private var typeRaw = LibraryMediaTypeFilter.all.rawValue
    @AppStorage(LibraryFilterKeys.fromDate) private var fromDateInterval = 0.0
    @AppStorage(LibraryFilterKeys.toDate) private var toDateInterval = 0.0
    @AppStorage(LibraryFilterKeys.place) private var placeFilterID = ""
    @AppStorage(LibraryFilterKeys.trip) private var tripFilterKey = ""
    @AppStorage(LibraryFilterKeys.memory) private var memoryFilterRaw = LibraryMemoryFilter.all.rawValue
    @AppStorage(LibraryFilterKeys.person) private var personFilterID = ""
    @AppStorage(LibraryFilterKeys.query) private var query = ""

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

    private var key: Int {
        var hasher = Hasher()
        hasher.combine(query)
        hasher.combine(typeRaw)
        hasher.combine(fromDateInterval)
        hasher.combine(toDateInterval)
        hasher.combine(placeFilterID)
        hasher.combine(tripFilterKey)
        hasher.combine(memoryFilterRaw)
        hasher.combine(personFilterID)
        for item in items {
            hasher.combine(item.id)
            hasher.combine(item.updatedAt)
        }
        for observation in faceObservations {
            hasher.combine(observation.id)
            hasher.combine(observation.personID)
        }
        return hasher.finalize()
    }

    var body: some View {
        Color.clear
            .accessibilityHidden(true)
            .task(id: key) {
                let personIndex = UserGroupRuleEngine.makePersonIndex(faceObservations)
                let visible = Set(LibraryFilterEngine.publishedItems(items, by: criteria, personIDsByMediaID: personIndex).map(\.id))
                if selection.visibleItemIDs != visible { selection.visibleItemIDs = visible }
            }
    }
}

/// The light way into the shared filters for screens other than the Library:
/// a search field and a Filter button in the toolbar. The button opens the
/// same chips as the Library in a popover and shows how many are on.
struct CompactLibraryFilters: ViewModifier {
    @AppStorage(LibraryFilterKeys.query) private var query = ""
    @AppStorage(LibraryFilterKeys.fromDate) private var fromDateInterval = 0.0
    @AppStorage(LibraryFilterKeys.toDate) private var toDateInterval = 0.0
    @AppStorage(LibraryFilterKeys.place) private var placeFilterID = ""
    @AppStorage(LibraryFilterKeys.trip) private var tripFilterKey = ""
    @AppStorage(LibraryFilterKeys.memory) private var memoryFilterRaw = LibraryMemoryFilter.all.rawValue
    @AppStorage(LibraryFilterKeys.person) private var personFilterID = ""
    @State private var showingFilters = false

    private var activeCount: Int {
        [
            fromDateInterval != 0 || toDateInterval != 0,
            !placeFilterID.isEmpty,
            !tripFilterKey.isEmpty,
            memoryFilterRaw != LibraryMemoryFilter.all.rawValue,
            !personFilterID.isEmpty,
        ].filter { $0 }.count
    }

    func body(content: Content) -> some View {
        content
            .background { LibraryFilterPublisher() }
            .searchable(text: $query, placement: .toolbar, prompt: Text(String(localized: "Search places, trips, notes")))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingFilters.toggle()
                    } label: {
                        Label(
                            activeCount == 0 ? String(localized: "Filter") : String(format: String(localized: "Filter (%lld)"), activeCount),
                            systemImage: activeCount == 0 ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill"
                        )
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(activeCount == 0 ? Paper.ink : Paper.accent)
                    }
                    .help(String(localized: "Filter by place, trip, date, memory or person"))
                    .accessibilityIdentifier("toolbar.filter")
                    .popover(isPresented: $showingFilters, arrowEdge: .bottom) {
                        LibraryFilterChips()
                            .fixedSize()
                            .padding(16)
                    }
                }
            }
    }
}

extension View {
    func compactLibraryFilters() -> some View {
        modifier(CompactLibraryFilters())
    }
}
