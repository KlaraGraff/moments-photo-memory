import SwiftUI
import SwiftData
import MomentsCore

/// Trips: one cover card per trip. Opening a trip shows it day by day and
/// place by place, with the trip's and each day's memories written right
/// there. Browsing and filtering every photo stays in the Library, so this
/// screen ignores the Library filters.
struct TripsScreen: View {
    @Query private var items: [MediaItem]
    @Query private var trips: [Trip]
    @Query private var places: [Place]
    @Query(sort: \CollectionMemory.createdAt) private var memories: [CollectionMemory]
    @Environment(SelectionModel.self) private var selection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The card to scroll back to when leaving a trip.
    @State private var returnTripID: String?
    /// Rebuilt only when the inputs change, not on every selection change or render.
    @State private var document = TimelineDocument(trips: [])
    /// Thumbnails need the models; looked up by id, rebuilt with `document`.
    @State private var itemByID: [String: MediaItem] = [:]

    private var inputKey: Int {
        var hasher = Hasher()
        for item in items {
            hasher.combine(item.id)
            hasher.combine(item.captureDate)
            hasher.combine(item.localDayKey)
            hasher.combine(item.latitude)
            hasher.combine(item.longitude)
            hasher.combine(item.tripID)
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
        hasher.combine(places.count)
        return hasher.finalize()
    }

    private func buildDocument() -> TimelineDocument {
        let sourceItems = items.map { item in
            TimelineItemSnapshot(item: item, placeHint: nearestPlaceName(for: item))
        }
        let sourceTrips = trips.map { trip in
            TimelineSourceTrip(
                id: trip.id,
                name: trip.effectiveName,
                itemIDs: trip.items.map(\.id),
                startDate: trip.startDate,
                endDate: trip.endDate
            )
        }
        return TimelineBuilder(calendar: Calendar.autoupdatingCurrent).build(
            items: sourceItems,
            trips: sourceTrips
        )
    }

    /// Newest trip first, like a photo album shelf; photos in no trip last.
    private var shelf: [TimelineTrip] {
        let real = document.trips.filter { !$0.isUnsorted && $0.itemCount > 0 }
        let dated = real.filter { $0.startDate != nil }.reversed()
        let undated = real.filter { $0.startDate == nil }
        let unsorted = document.trips.filter { $0.isUnsorted && $0.itemCount > 0 }
        return Array(dated) + undated + unsorted
    }

    private var openTrip: TimelineTrip? {
        guard let id = selection.openTripID else { return nil }
        return document.trips.first { $0.id == id }
    }

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView(
                    "No trips yet",
                    systemImage: "suitcase",
                    description: Text("Import photos and each trip gets its own card here.")
                )
            } else if let trip = openTrip {
                TripDetailView(
                    trip: trip,
                    itemByID: itemByID,
                    memories: memories,
                    onBack: closeTrip
                )
                .transition(.opacity)
            } else {
                TripShelfView(
                    trips: shelf,
                    itemByID: itemByID,
                    memories: memories,
                    returnTripID: returnTripID,
                    onOpen: open
                )
                .transition(.opacity)
            }
        }
        .task(id: inputKey) {
            document = buildDocument()
            itemByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
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

    private func nearestPlaceName(for item: MediaItem) -> String? {
        guard let latitude = item.latitude, let longitude = item.longitude else { return nil }
        let coordinate = GeoPoint(latitude: latitude, longitude: longitude)
        let nearest = places.compactMap { place -> (name: String, distance: Double)? in
            guard let placeLatitude = place.latitude, let placeLongitude = place.longitude,
                  let name = PlaceDisplayName.resolvedName(of: place) else { return nil }
            let distance = coordinate.distance(to: GeoPoint(latitude: placeLatitude, longitude: placeLongitude))
            return (name, distance)
        }
        .min { $0.distance < $1.distance }
        guard let nearest, nearest.distance <= 100_000 else { return nil }
        return nearest.name
    }
}

// MARK: - Shelf

private struct TripShelfView: View {
    let trips: [TimelineTrip]
    let itemByID: [String: MediaItem]
    let memories: [CollectionMemory]
    let returnTripID: String?
    let onOpen: (TimelineTrip) -> Void

    private let columns = [GridItem(.adaptive(minimum: 250, maximum: 360), spacing: 24, alignment: .top)]

    private var tripCount: Int { trips.filter { !$0.isUnsorted }.count }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                PaperScreenHeader(String(localized: "Trips")) {
                    Text(String(localized: "\(tripCount) trips"))
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 28) {
                    ForEach(trips) { trip in
                        TripCoverCard(
                            trip: trip,
                            cover: trip.cover.flatMap { itemByID[$0.id] },
                            memory: memories.first { $0.scope == .trip && $0.scopeKey == trip.id }?.text,
                            onOpen: { onOpen(trip) }
                        )
                        .id(trip.id)
                    }
                }
                .padding(.horizontal, PaperMetrics.screenInset)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.automatic)
            .background(Paper.canvas)
            .onAppear {
                if let returnTripID { proxy.scrollTo(returnTripID, anchor: .center) }
            }
        }
    }
}

private struct TripCoverCard: View {
    let trip: TimelineTrip
    let cover: MediaItem?
    let memory: String?
    let onOpen: () -> Void
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 14, style: .continuous) }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 0) {
                coverImage
                    .frame(height: 176)
                    .frame(maxWidth: .infinity)
                    .clipped()
                VStack(alignment: .leading, spacing: 5) {
                    Text(TripText.name(trip))
                        .font(.system(size: 19, weight: .medium, design: .serif))
                        .foregroundStyle(Paper.ink)
                        .lineLimit(1)
                    if let span = TripText.dateSpan(trip, locale: locale) {
                        Text(span)
                            .font(.caption)
                            .foregroundStyle(Paper.muted)
                    }
                    Text(TripText.summary(trip))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Paper.muted)
                        .lineLimit(1)
                    if let memory {
                        Text(memory)
                            .font(.system(.callout, design: .serif))
                            .foregroundStyle(Paper.ink)
                            .lineLimit(2)
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(trip.isUnsorted ? Paper.well : Paper.raised)
            .clipShape(shape)
            .contentShape(shape)
            .shadow(color: Paper.shadow.opacity(isHovering ? 0.08 : 0.05), radius: 1, y: 1)
            .shadow(color: Paper.shadow.opacity(isHovering ? 0.10 : 0.04), radius: isHovering ? 14 : 8, y: isHovering ? 6 : 3)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Motion.animation(Motion.settle, reduceMotion: reduceMotion)) { isHovering = hovering }
        }
        .help(String(localized: "Open this trip"))
        .accessibilityLabel(Text(TripText.name(trip)))
        .accessibilityIdentifier("trips.card.\(trip.id)")
    }

    @ViewBuilder
    private var coverImage: some View {
        if let cover {
            ThumbnailView(item: cover, width: 720, height: 440)
        } else {
            Rectangle()
                .fill(Paper.well)
                .overlay {
                    Image(systemName: "suitcase")
                        .font(.title2)
                        .foregroundStyle(Paper.muted)
                }
        }
    }
}

// MARK: - One trip

private struct TripDetailView: View {
    let trip: TimelineTrip
    let itemByID: [String: MediaItem]
    let memories: [CollectionMemory]
    let onBack: () -> Void
    @Environment(SelectionModel.self) private var selection
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

    var body: some View {
        ScrollView {
            PaperScreenHeader(TripText.name(trip)) {
                if let span = TripText.dateSpan(trip, locale: locale) {
                    Text(span)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(TripText.summary(trip))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Paper.muted)
                    if !trip.cityNames.isEmpty {
                        Text(trip.cityNames.joined(separator: " → "))
                            .font(.callout)
                            .foregroundStyle(Paper.ink)
                    }
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
                .padding(.bottom, 30)

                LazyVStack(alignment: .leading, spacing: 40) {
                    ForEach(trip.days) { day in
                        TripDaySection(
                            day: day,
                            number: dayNumbers[day.id],
                            memories: day.memoryKey.map { key in
                                memories.filter { $0.scope != .trip && $0.scopeKey == key }
                            } ?? [],
                            itemByID: itemByID,
                            onOpen: open
                        )
                    }
                }
            }
            .padding(.horizontal, PaperMetrics.screenInset)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.automatic)
        .background(Paper.canvas)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: onBack) {
                    Label(String(localized: "All trips"), systemImage: "chevron.left")
                }
                .help(String(localized: "All trips"))
                .keyboardShortcut("[", modifiers: .command)
                .accessibilityIdentifier("trips.back")
            }
        }
    }

    /// A photo opens in the large viewer, paging through the whole trip.
    private func open(_ itemID: String) {
        selection.select(itemID)
        selection.openViewer(itemID, in: trip.orderedItems.map(\.id))
    }
}

private struct TripDaySection: View {
    let day: TimelineDay
    let number: Int?
    let memories: [CollectionMemory]
    let itemByID: [String: MediaItem]
    let onOpen: (String) -> Void
    @Environment(\.locale) private var locale

    private var photoCount: Int { day.places.reduce(0) { $0 + $1.photoCount } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let number {
                    Text("Day \(number)")
                        .font(.system(size: 21, weight: .medium, design: .serif))
                        .foregroundStyle(Paper.ink)
                } else {
                    Text("Date to add")
                        .font(.system(size: 21, weight: .medium, design: .serif))
                        .foregroundStyle(Paper.muted)
                }
                if let date = day.date {
                    Text(date, format: .dateTime.weekday(.wide).month(.wide).day().year().locale(locale))
                        .font(.caption)
                        .foregroundStyle(Paper.muted)
                }
                Spacer()
                Text(String(localized: "\(photoCount) photos"))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Paper.muted)
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

private struct TripPlaceBlock: View {
    let place: TimelinePlace
    let itemByID: [String: MediaItem]
    let onOpen: (String) -> Void
    @Environment(SelectionModel.self) private var selection
    @Environment(\.locale) private var locale

    private let columns = [GridItem(.adaptive(minimum: 128, maximum: 200), spacing: 8, alignment: .top)]

    /// Photo memories written before notes existed stay readable here.
    private var photoMemories: [TimelineMemorySnippet] { place.items.flatMap(\.memories) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "mappin")
                    .font(.caption)
                    .foregroundStyle(Paper.accent)
                Text(place.name ?? String(localized: "Unknown place"))
                    .font(.headline)
                    .foregroundStyle(Paper.ink)
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
                ForEach(place.items) { item in
                    Button { onOpen(item.id) } label: {
                        thumbnail(for: item)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Open photo"))
                    .accessibilityLabel(item.title.isEmpty ? item.id : item.title)
                    .accessibilityIdentifier("trips.photo.\(item.id)")
                }
            }

            if !photoMemories.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(photoMemories) { memory in
                        Text(memory.text)
                            .font(.system(.callout, design: .serif))
                            .foregroundStyle(Paper.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private func thumbnail(for item: TimelineItemSnapshot) -> some View {
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

private struct TripTravelRow: View {
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

// MARK: - Text

private enum TripText {
    static func name(_ trip: TimelineTrip) -> String {
        if trip.isUnsorted || trip.name == "Unsorted memories" { return String(localized: "Not in a trip") }
        return trip.name
    }

    static func dateSpan(_ trip: TimelineTrip, locale: Locale) -> String? {
        guard let start = trip.orderedItems.compactMap(\.date).min() ?? trip.startDate else { return nil }
        let formatter = DateIntervalFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: start, to: max(trip.endDate ?? start, start))
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
