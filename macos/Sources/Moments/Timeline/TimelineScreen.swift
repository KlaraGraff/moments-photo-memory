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

    private var visibleItems: [MediaItem] {
        items.filter { selection.isVisible($0.id) }
    }

    private var inputKey: Int {
        var hasher = Hasher()
        hasher.combine(store.revision)
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
                await rebuild()
                shownBuild = target
                #if DEBUG
                PageProbe.contentReady(token: probeToken)
                #endif
            }
            isBuilding = false
        }
    }

    /// Builds the page off the main thread and assigns it. Only one build runs
    /// at a time, so no older result can arrive late and overwrite a newer one.
    private func rebuild() async {
        // Everything read from SwiftData stays on the main actor; the build
        // below sees plain values only.
        let placeIndex = NearestPlaceIndex(places: places)
        let memoriesByPhotoID = Self.memoriesByPhotoID(memoryRecords)
        let sourceItems = visibleItems.map { item in
            TimelineItemSnapshot(item: item, placeHint: nil, memories: memoriesByPhotoID[item.persistentModelID] ?? [])
        }
        let libraryItems = items
        let libraryItemByID = store.itemsByID
        let stackDecisions = stackRecords
        var linksByItemID: [String: TripLink] = [:]
        for trip in trips {
            let link = TripLink(id: trip.id, name: trip.effectiveName)
            for item in trip.items { linksByItemID[item.id] = link }
        }
        let tripLinksByItemID = linksByItemID
        let calendar = Calendar.autoupdatingCurrent

        let built = await Task.detached(priority: .userInitiated) { () -> TimelineBuildResult in
            // The place lookup is per photo and pure, so it runs here too.
            let hinted = sourceItems.map { snapshot in
                snapshot.withPlaceHint(Self.placeHint(for: snapshot, index: placeIndex))
            }
            // No trips given: every photo lands in one stream, grouped by day and place.
            let document = TimelineBuilder(calendar: calendar).build(items: hinted, trips: [])
            let days = document.trips.flatMap(\.days)
            let dated = days.filter { $0.date != nil }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            let undated = days.filter { $0.date == nil }
            let months = TimelineMonth.group(dated, calendar: calendar)
                + (undated.isEmpty ? [] : [TimelineMonth(id: "undated", date: nil, days: undated)])
            // Every shot goes to the viewer, which folds bursts as the grid does.
            let viewerOrder = months.flatMap { month in
                month.days.flatMap { day in day.places.flatMap(\.itemIDs) }
            }
            return TimelineBuildResult(months: months, viewerOrder: viewerOrder)
        }.value
        months = built.months
        viewerOrder = built.viewerOrder
        stacks.update(items: libraryItems, decisions: stackDecisions)
        itemByID = libraryItemByID
        tripsByItemID = tripLinksByItemID
        isBuilt = true
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
