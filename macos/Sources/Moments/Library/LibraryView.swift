import SwiftUI
import SwiftData
import MomentsCore

struct LibraryView: View {
    @Environment(SelectionModel.self) private var selection
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(ImportController.self) private var importController

    @Query private var items: [MediaItem]
    let state: LibraryViewState

    @AppStorage("moments.library.density") private var density = 4
    @AppStorage("moments.library.sort") private var sortRaw = LibrarySortOrder.oldestFirst.rawValue
    @AppStorage("moments.library.fromDate") private var fromDateInterval = 0.0
    @AppStorage("moments.library.toDate") private var toDateInterval = 0.0
    @AppStorage("moments.library.place") private var placeFilterID = ""
    @AppStorage("moments.library.type") private var typeRaw = LibraryMediaTypeFilter.all.rawValue
    @AppStorage("moments.library.favoritesOnly") private var favoritesOnly = false
    @AppStorage("moments.library.trip") private var tripFilterKey = ""
    @AppStorage("moments.library.screenshotFilter") private var screenshotFilterRaw = LibraryScreenshotFilter.all.rawValue

    @State private var filtersAreVisible = false
    /// Grouping 5,000 items is too slow to redo on every render or selection
    /// change, so collections are rebuilt only when `groupingKey` changes.
    @State private var cachedCollections: [LibraryCollection] = []
    @State private var cachedVisibleCount = 0
    @State private var hasGrouped = false

    init(state: LibraryViewState) {
        self.state = state
    }

    private var criteria: LibraryFilterCriteria {
        LibraryFilterCriteria(
            fromDate: fromDateInterval == 0 ? nil : Date(timeIntervalSince1970: fromDateInterval),
            toDate: toDateInterval == 0 ? nil : Date(timeIntervalSince1970: toDateInterval),
            placeID: placeFilterID.isEmpty ? nil : placeFilterID,
            mediaType: LibraryMediaTypeFilter(rawValue: typeRaw) ?? .all,
            favoritesOnly: favoritesOnly,
            tripKey: tripFilterKey.isEmpty ? nil : tripFilterKey,
            screenshotFilter: LibraryScreenshotFilter(rawValue: screenshotFilterRaw) ?? .all
        )
    }

    private var filteredItems: [MediaItem] {
        LibraryFilterEngine.filteredItems(items, by: criteria)
    }

    private var collections: [LibraryCollection] {
        let candidates = filteredItems
        let itemByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        return LibraryFilterEngine.groupedItems(candidates, by: criteria, sortOrder: sortOrder)
            .map { LibraryCollection(core: $0, itemsByID: itemByID) }
            .filter { $0.cover != nil }
    }

    private var sortOrder: LibrarySortOrder {
        LibrarySortOrder(rawValue: sortRaw) ?? .oldestFirst
    }

    private var places: [LibraryPlaceOption] {
        var options: [String: LibraryPlaceOption] = [:]
        for item in items {
            if let place = item.place {
                options[place.id] = LibraryPlaceOption(id: place.id, name: place.name)
            }
            if let override = item.placeOverrideName?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
                options["override:\(override)"] = LibraryPlaceOption(id: "override:\(override)", name: override)
            }
        }
        return options.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var trips: [String] {
        Array(Set(items.compactMap(\.tripID))).sorted()
    }

    private var groupingKey: Int {
        var hasher = Hasher()
        hasher.combine(filterSignature)
        hasher.combine(sortRaw)
        for item in items {
            hasher.combine(item.id)
            hasher.combine(item.captureDate)
            hasher.combine(item.isFavorite)
            hasher.combine(item.isScreenshot)
            hasher.combine(item.width)
            hasher.combine(item.height)
            hasher.combine(item.place?.id)
            hasher.combine(item.placeOverrideName)
            hasher.combine(item.placeOverrideLatitude)
            hasher.combine(item.placeOverrideLongitude)
        }
        return hasher.finalize()
    }

    private func regroup() {
        let visible = filteredItems
        cachedVisibleCount = visible.count
        cachedCollections = collections
        hasGrouped = true
        selection.visibleItemIDs = Set(visible.map(\.id))
        synchronizeSelection(visible: Set(visible.map(\.id)))
    }

    private var filterSignature: String {
        [
            String(fromDateInterval), String(toDateInterval), placeFilterID, typeRaw,
            String(favoritesOnly), tripFilterKey, screenshotFilterRaw, sortRaw, String(density)
        ].joined(separator: "|")
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

    private var densityBinding: Binding<Double> {
        Binding(
            get: { Double(density) },
            set: { density = Int($0.rounded()) }
        )
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 150), spacing: 20, alignment: .top), count: max(2, min(6, density)))
    }

    var body: some View {
        let displayedCollections = cachedCollections
        VStack(spacing: 0) {
            header(for: displayedCollections)
            toolbar
            ImportStatusView()
            if filtersAreVisible { filterPanel }

            if !hasGrouped {
                Spacer()
            } else if displayedCollections.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 28) {
                            ForEach(displayedCollections) { collection in
                                CollectionCard(collection: collection, state: state)
                                    .id(collection.id)
                                    .onAppear {
                                        if state.lastVisibleCollectionID != collection.id {
                                            state.lastVisibleCollectionID = collection.id
                                        }
                                        if !state.initializedCollectionIDs.contains(collection.id) {
                                            state.initializedCollectionIDs.insert(collection.id)
                                            if collection.items.contains(where: { $0.latestMemory != nil }) {
                                                state.expandedCollectionIDs.insert(collection.id)
                                            }
                                        }
                                    }
                            }
                        }
                        .padding(.horizontal, 28)
                        .padding(.vertical, 24)
                    }
                    .scrollIndicators(.visible)
                    .onChange(of: selection.focusedItemID, initial: true) { _, focus in
                        guard let focus,
                              let target = displayedCollections.first(where: { $0.core.itemIDs.contains(focus) }) else { return }
                        if reduceMotion {
                            proxy.scrollTo(target.id, anchor: .center)
                        } else {
                            withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(target.id, anchor: .center) }
                        }
                    }
                    .onAppear {
                        if let anchor = state.lastVisibleCollectionID,
                           displayedCollections.contains(where: { $0.id == anchor }) {
                            DispatchQueue.main.async { proxy.scrollTo(anchor, anchor: .center) }
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Library")
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

    private func header(for collections: [LibraryCollection]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Library")
                    .font(.system(.largeTitle, design: .serif).weight(.medium))
                HStack(spacing: 4) {
                    Text(cachedVisibleCount, format: .number)
                        .font(.caption.monospacedDigit())
                    Text("photos")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
            if !selection.selectedItemIDs.isEmpty {
                Button {
                    selection.clear()
                } label: {
                    Label("Selected", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderless)
            }
            HStack(spacing: 4) {
                Text(collections.count, format: .number)
                    .font(.caption.monospacedDigit())
                Text("collections")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            Button {
                filtersAreVisible.toggle()
            } label: {
                Label(filtersAreVisible ? "Hide filters" : "Show filters", systemImage: "line.3.horizontal.decrease.circle")
            }
            .buttonStyle(.borderless)

            Menu {
                Picker("Sort", selection: $sortRaw) {
                    Text("Oldest first").tag(LibrarySortOrder.oldestFirst.rawValue)
                    Text("Newest first").tag(LibrarySortOrder.newestFirst.rawValue)
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)

            Spacer(minLength: 8)
            Label("Columns", systemImage: "square.grid.2x2")
                .foregroundStyle(.secondary)
            Slider(value: densityBinding, in: 2...6, step: 1)
                .frame(width: 110)
                .accessibilityValue(Text("\(density)"))

            #if DEBUG
            Button {
                _ = try? DemoSeeder.generateSyntheticLibrary(context: modelContext)
            } label: {
                Label("Generate 5,000 synthetic items", systemImage: "speedometer")
            }
            .buttonStyle(.borderless)
            #endif
        }
        .font(.caption)
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var filterPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 18) {
                Toggle("From", isOn: Binding(
                    get: { fromDateInterval != 0 },
                    set: { if !$0 { fromDateInterval = 0 } else if fromDateInterval == 0 { fromDateInterval = Date.now.timeIntervalSince1970 } }
                ))
                .toggleStyle(.checkbox)
                DatePicker("", selection: fromDateBinding, displayedComponents: .date)
                    .labelsHidden()
                    .disabled(fromDateInterval == 0)

                Toggle("To", isOn: Binding(
                    get: { toDateInterval != 0 },
                    set: { if !$0 { toDateInterval = 0 } else if toDateInterval == 0 { toDateInterval = Date.now.timeIntervalSince1970 } }
                ))
                .toggleStyle(.checkbox)
                DatePicker("", selection: toDateBinding, displayedComponents: .date)
                    .labelsHidden()
                    .disabled(toDateInterval == 0)
            }

            HStack(spacing: 16) {
                Picker("Place", selection: $placeFilterID) {
                    Text("All places").tag("")
                    ForEach(places) { place in
                        Text(place.name).tag(place.id)
                    }
                }
                .frame(maxWidth: 220)

                Picker("Type", selection: $typeRaw) {
                    Text("All types").tag(LibraryMediaTypeFilter.all.rawValue)
                    Text("Photos").tag(LibraryMediaTypeFilter.photo.rawValue)
                    Text("Videos").tag(LibraryMediaTypeFilter.video.rawValue)
                    Text("Live Photos").tag(LibraryMediaTypeFilter.live.rawValue)
                }
                .frame(maxWidth: 170)

                Picker("Trip", selection: $tripFilterKey) {
                    Text("All trips").tag("")
                    ForEach(trips, id: \.self) { trip in Text(trip).tag(trip) }
                }
                .frame(maxWidth: 190)

                Picker("Screenshot filter", selection: $screenshotFilterRaw) {
                    Text("All visible media").tag(LibraryScreenshotFilter.all.rawValue)
                    Text("Possible screenshots").tag(LibraryScreenshotFilter.possibleOnly.rawValue)
                }
                .frame(maxWidth: 230)
            }

            HStack(spacing: 16) {
                Toggle("Favorites only", isOn: $favoritesOnly)
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Clear filters") { clearFilters() }
                    .buttonStyle(.link)
            }
        }
        .font(.caption)
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .background(.quaternary.opacity(0.25))
    }

    private var emptyState: some View {
        let isFiltered = criteria != .default
        return VStack(spacing: 14) {
            ContentUnavailableView(
                isFiltered ? "No matching photos" : "No photos yet",
                systemImage: isFiltered ? "line.3.horizontal.decrease.circle" : "photo.on.rectangle",
                description: Text(isFiltered ? "Try changing your filters." : "Add a photo or import a folder to begin.")
            )
            if !isFiltered {
                Button {
                    importController.chooseFolder()
                } label: {
                    Label("Import Folder…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func clearFilters() {
        fromDateInterval = 0
        toDateInterval = 0
        placeFilterID = ""
        typeRaw = LibraryMediaTypeFilter.all.rawValue
        favoritesOnly = false
        tripFilterKey = ""
        screenshotFilterRaw = LibraryScreenshotFilter.all.rawValue
    }

    private func synchronizeSelection(visible: Set<String>) {
        selection.selectedItemIDs.formIntersection(visible)
        if let focus = selection.focusedItemID, !visible.contains(focus) {
            selection.focusedItemID = selection.selectedItemIDs.first
        }
    }
}

private struct CollectionCard: View {
    @Environment(SelectionModel.self) private var selection
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let collection: LibraryCollection
    let state: LibraryViewState

    private var cover: MediaItem? { collection.cover }
    private var isExpanded: Bool { state.expandedCollectionIDs.contains(collection.id) }

    var body: some View {
        if let cover {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .topLeading) {
                    Button {
                        selection.select(cover.id)
                    } label: {
                        ThumbnailView(item: cover, width: 520, height: 360)
                            .frame(maxWidth: .infinity)
                            .aspectRatio(1.36, contentMode: .fit)
                    }
                    .buttonStyle(.plain)

                    HStack(spacing: 6) {
                        SelectionButton(item: cover)
                        Spacer()
                        FavoriteButton(item: cover)
                    }
                    .padding(10)

                    VStack {
                        Spacer()
                        HStack(spacing: 6) {
                            if collection.count > 1 {
                                Label {
                                    HStack(spacing: 3) {
                                        Text(collection.count, format: .number)
                                        Text("photos")
                                    }
                                } icon: {
                                    Image(systemName: "square.stack.3d.up")
                                }
                                    .font(.caption2.monospacedDigit())
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 5)
                                    .background(.black.opacity(0.52), in: Capsule())
                            }
                            if LibraryFilterEngine.isPossibleScreenshot(cover) {
                                Text("Possible screenshot")
                                    .font(.caption2)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 5)
                                    .background(.black.opacity(0.52), in: Capsule())
                            }
                            Spacer()
                        }
                        .foregroundStyle(.white)
                        .padding(10)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(selection.isSelected(cover.id) ? Color.accentColor : .clear, lineWidth: 2)
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(cover.title.isEmpty ? cover.id : cover.title)
                        .font(.headline)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    if let date = cover.captureDate {
                        Text(date, format: .dateTime.year().month().day())
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                PlaceEditor(item: cover)
                MemoryEditor(item: cover, state: state)
                TagEditor(item: cover)

                if collection.count > 1 {
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                            state.toggleExpanded(collection.id)
                        }
                    } label: {
                        Label(
                            isExpanded ? "Collapse collection" : "Expand collection",
                            systemImage: isExpanded ? "chevron.up" : "chevron.down"
                        )
                        .font(.caption)
                    }
                    .buttonStyle(.borderless)

                    if isExpanded {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 82), spacing: 8)], spacing: 8) {
                            ForEach(collection.items.dropFirst(), id: \.id) { item in
                                MemberPhotoCell(item: item)
                            }
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.quaternary, lineWidth: 1)
            }
            .onAppear {
                if !state.initializedCollectionIDs.contains(collection.id) {
                    state.initializedCollectionIDs.insert(collection.id)
                    if collection.items.contains(where: { $0.latestMemory != nil }) {
                        state.expandedCollectionIDs.insert(collection.id)
                    }
                }
            }
        }
    }
}

private struct SelectionButton: View {
    @Environment(SelectionModel.self) private var selection
    let item: MediaItem

    var body: some View {
        Button {
            selection.toggle(item.id)
        } label: {
            Image(systemName: selection.isSelected(item.id) ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.4))
                .shadow(radius: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Select")
    }
}

private struct FavoriteButton: View {
    @Environment(\.modelContext) private var modelContext
    let item: MediaItem

    var body: some View {
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
        .accessibilityLabel("Favorite")
    }
}

private struct MemberPhotoCell: View {
    @Environment(SelectionModel.self) private var selection
    @Environment(\.modelContext) private var modelContext
    let item: MediaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                selection.select(item.id)
            } label: {
                ZStack(alignment: .topTrailing) {
                    ThumbnailView(item: item, width: 220, height: 150)
                        .aspectRatio(1.4, contentMode: .fit)
                    if item.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                            .padding(5)
                    }
                }
            }
            .buttonStyle(.plain)
            Text(item.title.isEmpty ? item.id : item.title)
                .font(.caption2)
                .lineLimit(1)
        }
        .padding(4)
        .background(selection.isSelected(item.id) ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contextMenu {
            Button {
                item.setFavorite(!item.isFavorite, context: modelContext)
                try? modelContext.save()
            } label: {
                Text(LocalizedStringKey(item.isFavorite ? "Unfavorite" : "Favorite"))
            }
        }
    }
}

private struct MemoryEditor: View {
    @Environment(\.modelContext) private var modelContext

    let item: MediaItem
    let state: LibraryViewState

    @State private var saveTask: Task<Void, Never>?
    @State private var didSave = false

    private var text: String { state.draft(for: item) }
    private var textBinding: Binding<String> {
        Binding(
            get: { state.draft(for: item) },
            set: {
                state.setDraft($0, for: item)
                didSave = false
                scheduleSave($0)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Memory", systemImage: "pencil.and.scribble")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let memory = item.latestMemory {
                    Text(LocalizedStringKey(authorLabel(memory.author)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if didSave { Text("Saved").font(.caption2).foregroundStyle(.green) }
                }
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: textBinding)
                    .font(.body)
                    .frame(minHeight: 68, maxHeight: 150)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                if text.isEmpty {
                    Text("Write a memory…")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
            }
        }
        .onDisappear {
            saveTask?.cancel()
            persist(text)
        }
    }

    private func authorLabel(_ author: MemoryAuthor) -> String {
        switch author {
        case .me: return "Me"
        case .partner: return "Partner"
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
        let hasText = !newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if let memory = item.latestMemory {
            if hasText {
                memory.text = newText
                memory.updatedAt = .now
                memory.updatedBy = MomentsAccount.localID
                memory.revision += 1
            } else {
                modelContext.delete(memory)
            }
        } else if hasText {
            modelContext.insert(Memory(
                text: newText,
                author: .me,
                authorAccountID: MomentsAccount.localID,
                updatedBy: MomentsAccount.localID,
                mediaItem: item
            ))
        }
        try? modelContext.save()
        didSave = hasText || item.latestMemory != nil
    }
}

private struct PlaceEditor: View {
    @Environment(\.modelContext) private var modelContext
    let item: MediaItem

    @State private var isEditing = false
    @State private var name = ""
    @State private var mapLink = ""
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if isEditing {
                TextField("Place name", text: $name)
                TextField("Map link", text: $mapLink)
                HStack {
                    TextField("Latitude", text: $latitude)
                    TextField("Longitude", text: $longitude)
                }
                if let errorMessage {
                    Text(LocalizedStringKey(errorMessage)).font(.caption2).foregroundStyle(.red)
                }
                HStack {
                    Button("Save place") { save() }
                    Button("Cancel") { load() }
                        .buttonStyle(.borderless)
                }
                .font(.caption)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "mappin.and.ellipse")
                        .foregroundStyle(.secondary)
                    if let placeName = item.effectivePlaceName, !placeName.isEmpty {
                        Text(placeName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("No place")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit place") {
                        load()
                        isEditing = true
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                }
            }
        }
        .onAppear { load() }
    }

    private func load() {
        name = item.placeOverrideName ?? item.place?.name ?? ""
        mapLink = item.placeOverrideMapLink ?? item.place?.mapLink ?? ""
        latitude = item.placeOverrideLatitude.map { String(describing: $0) } ?? ""
        longitude = item.placeOverrideLongitude.map { String(describing: $0) } ?? ""
        errorMessage = nil
        isEditing = false
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLink = mapLink.trimmingCharacters(in: .whitespacesAndNewlines)
        let latText = latitude.trimmingCharacters(in: .whitespacesAndNewlines)
        let lonText = longitude.trimmingCharacters(in: .whitespacesAndNewlines)
        if !latText.isEmpty || !lonText.isEmpty {
            guard let lat = Double(latText), let lon = Double(lonText), (-90...90).contains(lat), (-180...180).contains(lon) else {
                errorMessage = "Enter valid coordinates"
                return
            }
        }
        let existing = item.localPlaceOverride
        if let existing {
            if trimmedName.isEmpty && trimmedLink.isEmpty && latText.isEmpty && lonText.isEmpty {
                modelContext.delete(existing)
            } else {
                existing.nameOverride = trimmedName.isEmpty ? nil : trimmedName
                existing.mapLinkOverride = trimmedLink.isEmpty ? nil : trimmedLink
                if !latText.isEmpty, let lat = Double(latText), let lon = Double(lonText) {
                    existing.latitude = lat
                    existing.longitude = lon
                } else {
                    existing.latitude = nil
                    existing.longitude = nil
                }
                existing.updatedAt = .now
                existing.updatedBy = MomentsAccount.localID
            }
        } else if !trimmedName.isEmpty || !trimmedLink.isEmpty || !latText.isEmpty || !lonText.isEmpty {
            let override = PlaceOverride(
                placeID: item.place?.id,
                mediaID: item.id,
                accountID: MomentsAccount.localID,
                nameOverride: trimmedName.isEmpty ? nil : trimmedName,
                mapLinkOverride: trimmedLink.isEmpty ? nil : trimmedLink,
                latitude: latText.isEmpty ? nil : Double(latText),
                longitude: lonText.isEmpty ? nil : Double(lonText),
                updatedBy: MomentsAccount.localID,
                place: item.place,
                mediaItem: item
            )
            modelContext.insert(override)
        }
        try? modelContext.save()
        isEditing = false
    }
}

private struct TagEditor: View {
    @Environment(\.modelContext) private var modelContext
    let item: MediaItem
    @State private var tagDraft = ""

    var body: some View {
        HStack(spacing: 6) {
            ForEach(item.tags.sorted { $0.displayName < $1.displayName }, id: \.id) { tag in
                HStack(spacing: 3) {
                    Text(tag.displayName)
                    Button {
                        item.removeTag(tag, context: modelContext)
                        try? modelContext.save()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
            }
            TextField("Add tag", text: $tagDraft)
                .textFieldStyle(.roundedBorder)
                .font(.caption2)
                .onSubmit(addTag)
        }
    }

    private func addTag() {
        let name = tagDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = Tag.normalize(name)
        guard !normalizedName.isEmpty, !item.tags.contains(where: { $0.normalizedName == normalizedName }) else { return }
        let tag: Tag
        do {
            tag = try Tag.lookupOrCreate(displayName: name, in: modelContext)
        } catch {
            return
        }
        item.addTag(tag, context: modelContext)
        tagDraft = ""
        try? modelContext.save()
    }
}
