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
    @State private var showingPlacesEditor = false

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
        .onAppear {
            // A place filter saved by id before places were listed by name.
            if let migrated = PlaceNames.optionID(forLegacy: placeFilterID, items: allItems) { placeFilterID = migrated }
        }
    }

    /// One row per name: unnamed spots are listed under the area or city
    /// that names them, places with the same name are one row, and the
    /// filter matches all of them.
    private var places: [LibraryPlaceOption] {
        PlaceNames.options(for: allItems)
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
        selection.libraryScope = nil
    }

    private var chipRow: some View {
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
                if !places.isEmpty {
                    Divider()
                    Button {
                        showingPlacesEditor = true
                    } label: {
                        Label(String(localized: "Rename or Merge Places…"), systemImage: "pencil")
                    }
                }
            }
            .sheet(isPresented: $showingPlacesEditor) { PlacesEditorSheet() }

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
            personFilterMenu

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
        // Chip labels read as ink; the app accent would turn every chip red.
        .tint(LibraryPalette.ink)
        .fixedSize()
        .paperChip(selected: selected != nil)
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
        // Chip labels read as ink; the app accent would turn every chip red.
        .tint(LibraryPalette.ink)
        .fixedSize()
        .paperChip(selected: dateFilterLabel != nil)
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
            filterMenuTitle(String(localized: "Person"), selected: !personFilterID.isEmpty)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // Chip labels read as ink; the app accent would turn every chip red.
        .tint(LibraryPalette.ink)
        .fixedSize()
        .paperChip(selected: !personFilterID.isEmpty)
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

    private var criteria: LibraryFilterCriteria {
        LibraryFilterCriteria(
            fromDate: fromDateInterval == 0 ? nil : Date(timeIntervalSince1970: fromDateInterval),
            toDate: toDateInterval == 0 ? nil : Date(timeIntervalSince1970: toDateInterval),
            placeID: placeFilterID.isEmpty ? nil : placeFilterID,
            mediaType: LibraryMediaTypeFilter(rawValue: typeRaw) ?? .all,
            tripKey: tripFilterKey.isEmpty ? nil : tripFilterKey,
            memoryFilter: LibraryMemoryFilter(rawValue: memoryFilterRaw) ?? .all,
            personID: personFilterID.isEmpty ? nil : personFilterID
        )
    }

    private var key: Int {
        var hasher = Hasher()
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
