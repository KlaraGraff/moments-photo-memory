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
            hasher.combine(item.effectiveCaptureDate)
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
            hasher.combine(trip.startDate)
            hasher.combine(trip.endDate)
        }
        for place in places {
            hasher.combine(place.id)
            hasher.combine(PlaceDisplayName.resolvedName(of: place))
        }
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
            } else if document.trips.isEmpty {
                // Built on appear; until then show the bare page, not "0 trips".
                Paper.canvas
            } else if let trip = openTrip {
                TripDetailView(
                    trip: trip,
                    model: trips.first { $0.id == trip.id },
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

    private var tripCount: Int { trips.filter { !$0.isUnsorted }.count }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(trips) { trip in
                        TripCoverCard(
                            trip: trip,
                            covers: trip.covers.compactMap { itemByID[$0.id] },
                            memory: memories.first { $0.scope == .trip && $0.scopeKey == trip.id }?.text,
                            onOpen: { onOpen(trip) }
                        )
                        .id(trip.id)
                    }
                }
                .padding(.horizontal, PaperMetrics.screenInset)
                .padding(.top, PaperMetrics.screenTopInset)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.automatic)
            .background(Paper.canvas)
            // The page's name lives in the window's title bar, not in the page.
            .navigationTitle(String(localized: "Trips"))
            .navigationSubtitle(String(localized: "\(tripCount) trips"))
            .onAppear {
                if let returnTripID { proxy.scrollTo(returnTripID, anchor: .center) }
            }
        }
    }
}

/// One trip as a wide card, like the import's suggested trips: two photos
/// laid on top of each other like prints on the left; dates and length, the
/// serif name, the route and the counts on the right; the trip's first
/// memory in a quiet column at the end. One tone lighter than the page, no
/// outline.
private struct TripCoverCard: View {
    let trip: TimelineTrip
    let covers: [MediaItem]
    let memory: String?
    let onOpen: () -> Void
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 8, style: .continuous) }

    var body: some View {
        Button(action: onOpen) {
            // Narrow windows drop the memory column first, then use smaller
            // prints, so the text never runs under them.
            ViewThatFits(in: .horizontal) {
                content(printScale: 1, showsMemory: true)
                content(printScale: 1, showsMemory: false)
                content(printScale: 0.72, showsMemory: false)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(trip.isUnsorted ? Paper.well.opacity(0.6) : Paper.raised, in: shape)
            .contentShape(shape)
            .shadow(color: Paper.shadow.opacity(isHovering ? 0.07 : 0.04), radius: 1, y: 1)
            .shadow(color: Paper.shadow.opacity(isHovering ? 0.08 : 0.03), radius: isHovering ? 12 : 6, y: isHovering ? 4 : 2)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Motion.animation(Motion.settle, reduceMotion: reduceMotion)) { isHovering = hovering }
        }
        .help(String(localized: "Open this trip"))
        .accessibilityLabel(Text(TripText.name(trip)))
        .accessibilityIdentifier("trips.card.\(trip.id)")
    }

    private func content(printScale: CGFloat, showsMemory: Bool) -> some View {
        HStack(alignment: .top, spacing: 26 * printScale) {
            TripPrints(covers: covers, lifted: isHovering, scale: printScale)
                .frame(width: 262 * printScale, height: 186 * printScale)

            VStack(alignment: .leading, spacing: 9) {
                if let span = TripText.dateSpan(trip, locale: locale) {
                    Text(TripText.dateLine(span: span, trip: trip))
                        .font(.callout)
                        .foregroundStyle(Paper.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                Text(TripText.name(trip))
                    .font(.system(size: 28, weight: .medium, design: .serif))
                    .foregroundStyle(Paper.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.bottom, 5)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .stroke(Paper.rule, style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                            .frame(height: 1)
                    }
                if !trip.cityNames.isEmpty {
                    Text(trip.cityNames.joined(separator: " → "))
                        .font(.callout)
                        .foregroundStyle(Paper.ink)
                        .lineLimit(2)
                }
                Text(TripText.counts(trip))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(Paper.muted)
                    .lineLimit(1)
            }
            .padding(.top, 6)
            // A fixed ideal width lets ViewThatFits judge by the layout, not by how long the name is.
            .frame(minWidth: 220, idealWidth: 220, maxWidth: .infinity, alignment: .leading)

            if showsMemory, let memory {
                Text(memory)
                    .font(.system(.callout, design: .serif))
                    .foregroundStyle(Paper.ink)
                    .lineLimit(5)
                    .frame(width: 220, alignment: .topLeading)
                    .padding(.top, 8)
            }
        }
    }
}

/// Two photos as prints with a white border, the second laid over the first,
/// each turned a little. Hovering the card spreads them slightly apart.
private struct TripPrints: View {
    let covers: [MediaItem]
    let lifted: Bool
    var scale: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topLeading) {
            if covers.count > 1 {
                printed(covers[1])
                    .frame(width: 186 * scale, height: 150 * scale)
                    .rotationEffect(.degrees(lifted ? -4 : -2.5))
                    .offset(x: (lifted ? 0 : 4) * scale, y: (6) * scale)
                printed(covers[0])
                    .frame(width: 192 * scale, height: 156 * scale)
                    .rotationEffect(.degrees(lifted ? 2.5 : 1.5))
                    .offset(x: (70) * scale, y: (lifted ? 22 : 24) * scale)
            } else if let only = covers.first {
                printed(only)
                    .frame(width: 214 * scale, height: 164 * scale)
                    .rotationEffect(.degrees(-1.5))
                    .offset(x: (22) * scale, y: (10) * scale)
            } else {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Paper.well)
                    .overlay {
                        Image(systemName: "suitcase")
                            .font(.title2)
                            .foregroundStyle(Paper.muted)
                    }
                    .frame(width: 214 * scale, height: 164 * scale)
                    .offset(x: (22) * scale, y: (10) * scale)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityHidden(true)
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
    /// The stored trip, for editing its dates; `nil` for photos in no trip.
    let model: Trip?
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
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    // The trip's name is in the title bar; its dates lead the page.
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        if let span = TripText.dateSpan(trip, locale: locale) {
                            Text(span)
                                .font(.system(size: 21, weight: .medium, design: .serif))
                                .foregroundStyle(Paper.ink)
                        }
                        if let model {
                            TripDatesButton(trip: model, photoDates: trip.orderedItems.compactMap(\.date))
                        }
                    }
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
            .padding(.top, PaperMetrics.screenTopInset)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.automatic)
        .background(Paper.canvas)
        .navigationTitle(TripText.name(trip))
        .navigationSubtitle(String(localized: "Trips"))
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

/// One day: its heading, its memory line, then its places and travel.
/// Shared by a trip ("Day 2") and the Timeline (the date as the heading,
/// with the trips that day belongs to).
struct TripDaySection: View {
    let day: TimelineDay
    let number: Int?
    let memories: [CollectionMemory]
    let itemByID: [String: MediaItem]
    let onOpen: (String) -> Void
    /// Trips this day belongs to, shown as links on the Timeline.
    var trips: [TripLink] = []
    var onOpenTrip: (String) -> Void = { _ in }
    @Environment(\.locale) private var locale

    private var photoCount: Int { day.places.reduce(0) { $0 + $1.photoCount } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let number {
                    Text("Day \(number)")
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
                ForEach(trips) { trip in
                    Button { onOpenTrip(trip.id) } label: {
                        Label(trip.name, systemImage: "suitcase")
                            .font(.caption)
                            .foregroundStyle(Paper.accent)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Open this trip"))
                    .accessibilityIdentifier("timeline.trip.\(trip.id)")
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

struct TripPlaceBlock: View {
    let place: TimelinePlace
    let itemByID: [String: MediaItem]
    let onOpen: (String) -> Void
    @Environment(SelectionModel.self) private var selection
    @Environment(\.locale) private var locale

    private let columns = [GridItem(.adaptive(minimum: 128, maximum: 200), spacing: 8, alignment: .top)]

    private var placeName: String { place.name ?? String(localized: "Unknown place") }

    /// Photo memories written before notes existed stay readable here.
    private var photoMemories: [TimelineMemorySnippet] { place.items.flatMap(\.memories) }

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

/// The trip's start and end, changed in a small popover. They start as the
/// first and last photo's days; "Use photo dates" goes back to those.
private struct TripDatesButton: View {
    @Environment(\.modelContext) private var modelContext
    let trip: Trip
    let photoDates: [Date]
    @State private var isEditing = false

    private var calendar: Calendar { .current }

    private var start: Binding<Date> {
        Binding(
            get: { trip.startDate ?? photoDates.min() ?? .now },
            set: { value in
                let day = calendar.startOfDay(for: value)
                trip.startDate = day
                if let end = trip.endDate, end < day { trip.endDate = endOfDay(day) }
                saved()
            }
        )
    }

    private var end: Binding<Date> {
        Binding(
            get: { trip.endDate ?? photoDates.max() ?? start.wrappedValue },
            set: { value in
                trip.endDate = endOfDay(max(value, start.wrappedValue))
                saved()
            }
        )
    }

    var body: some View {
        Button {
            isEditing.toggle()
        } label: {
            Image(systemName: "calendar.badge.clock")
                .foregroundStyle(Paper.accent)
        }
        .buttonStyle(.plain)
        .help(String(localized: "Change the trip's dates"))
        .accessibilityLabel(String(localized: "Change the trip's dates"))
        .accessibilityIdentifier("trips.dates")
        .popover(isPresented: $isEditing, arrowEdge: .bottom) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    PaperFormLabel(String(localized: "Starts"))
                    DatePicker("", selection: start, displayedComponents: .date)
                        .labelsHidden()
                        .accessibilityIdentifier("trips.dates.start")
                }
                GridRow {
                    PaperFormLabel(String(localized: "Ends"))
                    DatePicker("", selection: end, in: start.wrappedValue..., displayedComponents: .date)
                        .labelsHidden()
                        .accessibilityIdentifier("trips.dates.end")
                }
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Button(String(localized: "Use photo dates")) {
                        trip.startDate = photoDates.min()
                        trip.endDate = photoDates.max()
                        saved()
                    }
                    .disabled(photoDates.isEmpty)
                }
            }
            .padding(16)
        }
    }

    private func endOfDay(_ date: Date) -> Date {
        let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) ?? date
        return next.addingTimeInterval(-1)
    }

    private func saved() {
        trip.updatedAt = .now
        try? modelContext.save()
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
