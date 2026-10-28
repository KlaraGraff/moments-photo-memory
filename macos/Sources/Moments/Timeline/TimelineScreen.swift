import SwiftUI
import SwiftData
import MomentsCore

/// Every photo by day, newest first, trips or not: everyday moments sit
/// next to travel. Each day has its memory line and its places, the same
/// as a day inside a trip, plus a link to the trip it belongs to. Follows
/// the Library filters, like the maps.
struct TimelineScreen: View {
    @Query(filter: #Predicate<MediaItem> { $0.deletedAt == nil }) private var items: [MediaItem]
    @Query private var trips: [Trip]
    @Query private var places: [Place]
    @Query(sort: \CollectionMemory.createdAt) private var memories: [CollectionMemory]
    @Query(filter: #Predicate<UserGroup> { $0.kindRaw == "stack" }) private var stackRecords: [UserGroup]
    @Environment(SelectionModel.self) private var selection
    @Environment(PhotoStackModel.self) private var stacks
    @Environment(LibraryProjectionStore.self) private var projectionStore
    /// Rebuilt only when the inputs change, not on every selection change or render.
    @State private var months: [TimelineMonth] = []
    @State private var itemByID: [String: MediaItem] = [:]
    @State private var tripsByItemID: [String: TripLink] = [:]
    @State private var viewerOrder: [String] = []
    @State private var isBuilt = false

    private var visibleItems: [MediaItem] {
        items.filter { selection.isVisible($0.id) }
    }

    private var inputKey: Int {
        var hasher = Hasher()
        for item in visibleItems {
            hasher.combine(item.id)
            hasher.combine(item.effectiveCaptureDate)
            hasher.combine(item.localDayKey)
            hasher.combine(item.latitude)
            hasher.combine(item.longitude)
            for memory in item.memories {
                hasher.combine(memory.text)
                hasher.combine(memory.updatedAt)
            }
        }
        for trip in trips {
            hasher.combine(trip.id)
            hasher.combine(trip.effectiveName)
            hasher.combine(trip.items.count)
        }
        for place in places {
            hasher.combine(place.id)
            hasher.combine(PlaceDisplayName.resolvedName(of: place))
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
            } else if visibleItems.isEmpty {
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
        .task(id: inputKey) { rebuild() }
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

    private func rebuild() {
        let projection = projectionStore.projection
        let snapshots = visibleItems.map { item in
            TimelineItemSnapshot(item: item, placeHint: projection.photoByID[item.id]?.placeName ?? nearestPlaceName(for: item))
        }
        // No trips given: every photo lands in one stream, grouped by day and place.
        let document = TimelineBuilder(calendar: Calendar.autoupdatingCurrent).build(items: snapshots, trips: [])
        let days = document.trips.flatMap(\.days)
        let dated = days.filter { $0.date != nil }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        let undated = days.filter { $0.date == nil }
        months = TimelineMonth.group(dated, calendar: .autoupdatingCurrent)
            + (undated.isEmpty ? [] : [TimelineMonth(id: "undated", date: nil, days: undated)])
        // Every shot goes to the viewer, which folds bursts as the grid does.
        stacks.update(items: items, decisions: stackRecords)
        viewerOrder = months.flatMap { $0.days.flatMap { $0.places.flatMap(\.itemIDs) } }
        itemByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var links: [String: TripLink] = [:]
        for trip in trips {
            let link = TripLink(id: trip.id, name: trip.effectiveName)
            for item in trip.items { links[item.id] = link }
        }
        tripsByItemID = links
        isBuilt = true
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

    private func nearestPlaceName(for item: MediaItem) -> String? {
        // Imported items already carry their resolved place (including this
        // person's override). Use it directly; scanning every Place for every
        // item makes a 5,000-photo timeline quadratic before it can render.
        if let name = item.effectivePlaceName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        guard let latitude = item.latitude, let longitude = item.longitude else { return nil }
        let coordinate = GeoPoint(latitude: latitude, longitude: longitude)
        return projectionStore.projection.placeIndex.nearestName(to: coordinate, within: 100_000)
    }
}

/// The days of one calendar month, newest first.
struct TimelineMonth: Identifiable {
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
