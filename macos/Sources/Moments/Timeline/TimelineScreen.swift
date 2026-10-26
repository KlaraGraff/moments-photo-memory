import SwiftUI
import SwiftData
import MomentsCore

struct TimelineScreen: View {
    @Query private var items: [MediaItem]
    @Query private var trips: [Trip]
    @Query private var places: [Place]
    @Environment(SelectionModel.self) private var selection
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var collapsedPlaceIDs: Set<String> = []
    /// Rebuilt only when the inputs change, not on every selection change or render.
    @State private var document = TimelineDocument(trips: [])
    /// Thumbnails need the models; looked up by id, rebuilt with `document`.
    @State private var itemByID: [String: MediaItem] = [:]

    private var inputKey: Int {
        var hasher = Hasher()
        for item in visibleItems {
            hasher.combine(item.id)
            hasher.combine(item.captureDate)
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
        hasher.combine(places.count)
        return hasher.finalize()
    }

    private var visibleItems: [MediaItem] {
        items.filter { selection.isVisible($0.id) }
    }

    private var timeline: TimelineDocument {
        let sourceItems = visibleItems.map { item in
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

    var body: some View {
        Group {
            if visibleItems.isEmpty && trips.isEmpty {
                ContentUnavailableView(
                    "No memories yet",
                    systemImage: "calendar.badge.plus",
                    description: Text("Add a photo or import a synthetic demo to begin.")
                )
            } else if document.trips.isEmpty {
                ContentUnavailableView(
                    "No timeline entries",
                    systemImage: "calendar",
                    description: Text("Photos without dates will appear after a date is added.")
                )
            } else {
                timelineScroll
            }
        }
        .navigationTitle("Timeline")
        .task(id: inputKey) {
            document = timeline
            itemByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    private var timelineScroll: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(document.trips) { trip in
                    tripSections(for: trip)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.automatic)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func tripSections(for trip: TimelineTrip) -> some View {
        if trip.days.isEmpty {
            Section {
                TimelineEmptyTripRow()
                    .padding(.bottom, 24)
            } header: {
                TimelineTripHeader(trip: trip, locale: locale)
            }
        } else {
            ForEach(Array(trip.days.enumerated()), id: \.element.id) { index, day in
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        if index == 0 {
                            TimelineTripSummary(trip: trip, locale: locale)
                                .padding(.bottom, 4)
                        }
                        ForEach(day.events) { event in
                            eventView(event)
                        }
                    }
                    .padding(.bottom, 24)
                } header: {
                    TimelineDayHeader(day: day, locale: locale)
                }
            }
        }
    }

    @ViewBuilder
    private func eventView(_ event: TimelineEvent) -> some View {
        switch event {
        case let .place(place):
            TimelinePlaceCard(
                place: place,
                locale: locale,
                isExpanded: !collapsedPlaceIDs.contains(place.id),
                isSelected: !selection.selectedItemIDs.isDisjoint(with: place.itemIDs),
                reduceMotion: reduceMotion,
                itemByID: itemByID,
                onSelect: { select(place) },
                onOpen: { open($0, in: place) },
                onToggle: { toggle(placeID: place.id) }
            )
        case let .travel(travel):
            TimelineTravelRow(travel: travel, locale: locale)
        }
    }

    /// The place name opens its photos on their own in the Library.
    private func select(_ place: TimelinePlace) {
        selection.showInLibrary(
            place.itemIDs,
            title: place.name ?? String(localized: "Unknown place", locale: locale)
        )
    }

    private func open(_ itemID: String, in place: TimelinePlace) {
        selection.select(itemID)
        selection.openViewer(itemID, in: place.itemIDs)
    }

    private func toggle(placeID: String) {
        let update = {
            if collapsedPlaceIDs.contains(placeID) {
                collapsedPlaceIDs.remove(placeID)
            } else {
                collapsedPlaceIDs.insert(placeID)
            }
        }
        if reduceMotion {
            update()
        } else {
            withAnimation(.snappy(duration: 0.24), update)
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

private struct TimelineTripHeader: View {
    let trip: TimelineTrip
    let locale: Locale

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "suitcase")
                .foregroundStyle(.tint)
            Text(displayName)
                .font(.headline)
            Spacer()
            if trip.itemCount > 0 {
                Text(photoCount(trip.itemCount))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 20)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }

    private func photoCount(_ count: Int) -> String {
        let label = count == 1 ? String(localized: "photo", locale: locale) : String(localized: "photos", locale: locale)
        return "\(count) \(label)"
    }

    private var displayName: String {
        trip.name == "Unsorted memories" ? String(localized: "Unsorted memories", locale: locale) : trip.name
    }
}

private struct TimelineTripSummary: View {
    let trip: TimelineTrip
    let locale: Locale

    var body: some View {
        HStack(spacing: 8) {
            Text(displayName)
                .font(.subheadline.weight(.semibold))
            Text("·")
                .foregroundStyle(.tertiary)
            Text(photoCount(trip.itemCount))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 4)
    }

    private func photoCount(_ count: Int) -> String {
        let label = count == 1 ? String(localized: "photo", locale: locale) : String(localized: "photos", locale: locale)
        return "\(count) \(label)"
    }

    private var displayName: String {
        trip.name == "Unsorted memories" ? String(localized: "Unsorted memories", locale: locale) : trip.name
    }
}

private struct TimelineDayHeader: View {
    let day: TimelineDay
    let locale: Locale

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "calendar")
                .foregroundStyle(.secondary)
            if let date = day.date {
                Text(date, format: .dateTime.weekday(.wide).month(.wide).day().locale(locale))
                    .font(.subheadline.weight(.semibold))
                Text(date, format: .dateTime.year().locale(locale))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text("Date to add")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }
}

private struct TimelineEmptyTripRow: View {
    var body: some View {
        Label("No photos in this trip", systemImage: "photo.on.rectangle.angled")
            .foregroundStyle(.secondary)
            .padding(.vertical, 18)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct TimelinePlaceCard: View {
    let place: TimelinePlace
    let locale: Locale
    let isExpanded: Bool
    let isSelected: Bool
    let reduceMotion: Bool
    let itemByID: [String: MediaItem]
    let onSelect: () -> Void
    let onOpen: (String) -> Void
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Button(action: onSelect) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(place.name ?? String(localized: "Unknown place", locale: locale))
                            .font(.headline)
                            .foregroundStyle(.primary)
                        HStack(spacing: 5) {
                            Text(photoCount(place.photoCount))
                            if place.memoryCount > 0 {
                                Text("·")
                                Text(memoryCount(place.memoryCount))
                            }
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("timeline.place.\(place.id)")
                .help("Show these photos in the Library")
                .accessibilityLabel("Show \(place.photoCount) photos at \(place.name ?? String(localized: "Unknown place", locale: locale)) in the Library")

                Button(action: onToggle) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Collapse place" : "Expand place")
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 7) {
                        ForEach(place.items.prefix(4)) { item in
                            Button { onOpen(item.id) } label: {
                                TimelineThumbnail(item: item, media: itemByID[item.id])
                            }
                            .buttonStyle(.plain)
                            .help("Open photo")
                            .accessibilityLabel(item.title.isEmpty ? item.id : item.title)
                            .accessibilityIdentifier("timeline.thumbnail.\(item.id)")
                        }
                    }
                    ForEach(place.items) { item in
                        Button { onOpen(item.id) } label: {
                            TimelineItemRow(item: item, locale: locale)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("timeline.item.\(item.id)")
                    }
                }
                .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .background(isSelected ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(isSelected ? Color.accentColor.opacity(0.42) : Color.primary.opacity(0.08), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func photoCount(_ count: Int) -> String {
        let label = count == 1 ? String(localized: "photo", locale: locale) : String(localized: "photos", locale: locale)
        return "\(count) \(label)"
    }

    private func memoryCount(_ count: Int) -> String {
        let label = count == 1 ? String(localized: "memory", locale: locale) : String(localized: "memories", locale: locale)
        return "\(count) \(label)"
    }
}

private struct TimelineThumbnail: View {
    let item: TimelineItemSnapshot
    let media: MediaItem?

    var body: some View {
        if let media {
            ThumbnailView(item: media, width: 128, height: 96)
                .frame(width: 64, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    LinearGradient(
                        colors: [.teal.opacity(0.18), .orange.opacity(0.16)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: item.kindRaw == MediaKind.video.rawValue ? "video" : "photo")
                .foregroundStyle(.secondary)
        }
        .frame(width: 64, height: 48)
        .accessibilityHidden(true)
    }
}

private struct TimelineItemRow: View {
    let item: TimelineItemSnapshot
    let locale: Locale

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.kindRaw == MediaKind.video.rawValue ? "video" : "photo")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title.isEmpty ? item.id : item.title)
                    .font(.subheadline)
                if let date = item.date {
                    Text(date, format: .dateTime.hour().minute().locale(locale))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ForEach(item.memories) { memory in
                    Text(memory.text)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .padding(.top, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }
}

private struct TimelineTravelRow: View {
    let travel: TimelineTravel
    let locale: Locale

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.swap")
                .foregroundStyle(.orange)
            Text("Travel")
                .fontWeight(.semibold)
            Text("·")
                .foregroundStyle(.tertiary)
            Text(travel.fromName ?? String(localized: "Unknown place", locale: locale))
            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(travel.toName ?? String(localized: "Unknown place", locale: locale))
            Spacer(minLength: 8)
            Text(distanceLabel(travel.distanceMeters))
                .font(.caption.monospacedDigit())
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .foregroundStyle(Color.orange.opacity(0.45))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Travel from \(travel.fromName ?? String(localized: "Unknown place", locale: locale)) to \(travel.toName ?? String(localized: "Unknown place", locale: locale)), \(distanceLabel(travel.distanceMeters))")
    }

    private func distanceLabel(_ meters: Double) -> String {
        let measurement = Measurement(value: meters, unit: UnitLength.meters)
        let formatter = MeasurementFormatter()
        formatter.locale = locale
        formatter.unitStyle = .short
        formatter.unitOptions = .naturalScale
        return formatter.string(from: measurement)
    }
}
