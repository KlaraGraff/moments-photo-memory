import SwiftUI
import SwiftData
import MomentsCore

/// Chapters: one cover card per stretch of life — trips, events,
/// celebrations, stretches of time and custom kinds. Opening one shows it
/// day by day and place by place, with its own and each day's memories
/// written right there. Browsing and filtering every photo stays in the
/// Library, so this screen ignores the Library filters.
///
/// A chapter's photos can be changed here: new dates re-sort them, a day
/// can be added or taken out, a trip split or merged. Each change shows a
/// short note at the bottom with Undo (also on ⌘Z).
///
/// Trips are `Trip`s (a photo is in at most one trip); the other kinds are
/// `UserGroup`s of kind `.chapter`, so a photo can be in a trip and in a
/// birthday at once. Their cards and pages use the id "chapter.<group id>".
struct TripsScreen: View {
    @Query(filter: #Predicate<MediaItem> { $0.deletedAt == nil }) private var items: [MediaItem]
    @Query private var trips: [Trip]
    @Query(filter: #Predicate<UserGroup> { $0.kindRaw == "chapter" }) private var chapterGroups: [UserGroup]
    @Query private var groupItems: [UserGroupItem]
    @Query private var places: [Place]
    @Query(sort: \CollectionMemory.createdAt) private var memories: [CollectionMemory]
    @Environment(SelectionModel.self) private var selection
    @Environment(\.modelContext) private var modelContext
    @Environment(\.undoManager) private var undoManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The card to scroll back to when leaving a trip.
    @State private var returnTripID: String?
    /// Rebuilt only when the inputs change, not on every selection change or render.
    @State private var document = TimelineDocument(trips: [])
    /// Thumbnails need the models; looked up by id, rebuilt with `document`.
    @State private var itemByID: [String: MediaItem] = [:]
    /// The last change, with its Undo.
    @State private var notice: TripNotice?
    /// Covers chosen by hand, by trip id; kept on this Mac.
    @AppStorage(TripCoverChoice.defaultsKey, store: TripAssignmentLocks.store) private var coverStore = ""
    @State private var isCreatingTrip = false
    /// Chapters that are not trips, built like trips, by "chapter.<id>".
    @State private var chapterDocs: [String: TimelineTrip] = [:]
    /// The kind shown, or every kind when empty.
    @State private var filterRaw = ""

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
        for group in chapterGroups {
            hasher.combine(group.id)
            hasher.combine(group.name)
            hasher.combine(group.rulesData)
        }
        for membership in groupItems {
            hasher.combine(membership.id)
            hasher.combine(membership.excluded)
        }
        return hasher.finalize()
    }

    static func chapterID(_ group: UserGroup) -> String { "chapter." + group.id }

    /// Each chapter that is not a trip, built from its own photos only, so
    /// photos it shares with a trip appear in both.
    private func buildChapters(snapshots: [String: TimelineItemSnapshot]) -> [String: TimelineTrip] {
        let membersByGroup = Dictionary(grouping: groupItems.filter { !$0.excluded }, by: \.groupID)
        var result: [String: TimelineTrip] = [:]
        let builder = TimelineBuilder(calendar: Calendar.autoupdatingCurrent)
        for group in chapterGroups {
            let id = Self.chapterID(group)
            let ids = Array(Set((membersByGroup[group.id] ?? []).map(\.mediaID)))
            let members = ids.compactMap { snapshots[$0] }
            let info = group.chapterInfo
            let source = TimelineSourceTrip(id: id, name: group.name, itemIDs: ids, startDate: info.startDate, endDate: info.endDate)
            let built = builder.build(items: members, trips: [source]).trips.first { $0.id == id }
            result[id] = built ?? TimelineTrip(id: id, name: group.name, days: [], startDate: info.startDate, plannedEndDate: info.endDate)
        }
        return result
    }

    private func buildDocument(_ sourceItems: [TimelineItemSnapshot]) -> TimelineDocument {
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

    /// Every chapter, newest first, like a photo album shelf; photos in no
    /// trip last. Chapters other than trips show even before they have photos.
    private var allChapters: [TimelineTrip] {
        // A trip someone made by hand keeps its card even before photos join.
        // Imports mark their trips as suggested or confirmed; hand-made ones carry no status.
        let planned = Set(trips.filter { $0.startDate != nil && $0.suggestionStatusRaw == nil }.map(\.id))
        let real = document.trips.filter { !$0.isUnsorted && ($0.itemCount > 0 || planned.contains($0.id)) } + Array(chapterDocs.values)
        let dated = real.filter { $0.startDate != nil }.sorted { ($0.startDate ?? .distantPast, $0.id) > ($1.startDate ?? .distantPast, $1.id) }
        let undated = real.filter { $0.startDate == nil }
        let unsorted = document.trips.filter { $0.isUnsorted && $0.itemCount > 0 }
        return dated + undated + unsorted
    }

    /// The shelf with the chosen kind only; photos in no trip go with Trips.
    private var shelf: [TimelineTrip] {
        guard !filterRaw.isEmpty else { return allChapters }
        return allChapters.filter { chapterType(of: $0).raw == filterRaw || ($0.isUnsorted && filterRaw == ChapterType.trip.raw) }
    }

    /// The kinds that have chapters, presets first, for the filter.
    private var typesPresent: [ChapterType] {
        let present = Set(allChapters.filter { !$0.isUnsorted }.map { chapterType(of: $0) })
        let custom = present.filter { if case .custom = $0 { return true } else { return false } }.sorted { $0.label < $1.label }
        return ChapterType.presets.filter(present.contains) + custom
    }

    private func chapterType(of chapter: TimelineTrip) -> ChapterType {
        target(of: chapter.id)?.type ?? .trip
    }

    private var openTrip: TimelineTrip? {
        guard let id = selection.openTripID else { return nil }
        return document.trips.first { $0.id == id } ?? chapterDocs[id]
    }

    private var tripByID: [String: Trip] {
        Dictionary(trips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func target(of id: String) -> ChapterTarget? {
        if let trip = tripByID[id] { return .trip(trip) }
        if id.hasPrefix("chapter."), let group = chapterGroups.first(where: { Self.chapterID($0) == id }) { return .group(group) }
        return nil
    }

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView(
                    "No chapters yet",
                    systemImage: "book.pages",
                    description: Text("Import photos and trips appear here on their own. Use + for an event, a celebration or any stretch of time.")
                )
            } else if document.trips.isEmpty && chapterDocs.isEmpty {
                // Built on appear; until then show the bare page, not "0 trips".
                Paper.canvas
            } else if let trip = openTrip {
                TripDetailView(
                    trip: trip,
                    target: target(of: trip.id),
                    otherTrips: mergeCandidates(for: trip),
                    around: daysAround(trip),
                    itemByID: itemByID,
                    memories: memories,
                    actions: actions,
                    onBack: closeTrip
                )
                .transition(.opacity)
            } else {
                TripShelfView(
                    trips: shelf,
                    types: typesPresent,
                    filterRaw: $filterRaw,
                    target: target(of:),
                    itemByID: itemByID,
                    covers: TripCoverChoice.decode(coverStore),
                    memories: memories,
                    returnTripID: returnTripID,
                    actions: actions,
                    onOpen: open,
                    onNew: { isCreatingTrip = true }
                )
                .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if let notice {
                TripNoticeBar(notice: notice, onUndo: { undo(notice) }, onAdopt: { adopt(notice) }, onClose: { self.notice = nil })
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.animation(Motion.settle, reduceMotion: reduceMotion), value: notice?.id)
        // ⌘Z already put things back; the note and its offer no longer apply.
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidUndoChange)) { _ in
            notice = nil
        }
        .task(id: notice?.id) {
            // A note without a question goes away by itself.
            guard let notice, notice.offer == nil else { return }
            try? await Task.sleep(for: .seconds(10))
            if self.notice?.id == notice.id { self.notice = nil }
        }
        .sheet(isPresented: $isCreatingTrip) {
            ChapterNewSheet(
                initialType: filterRaw.isEmpty ? .trip : ChapterType(raw: filterRaw),
                customTypes: typesPresent.filter { if case .custom = $0 { return true } else { return false } },
                onCreate: createChapter
            )
        }
        .task(id: inputKey) {
            let snapshots = items.map { item in
                TimelineItemSnapshot(item: item, placeHint: nearestPlaceName(for: item))
            }
            document = buildDocument(snapshots)
            chapterDocs = buildChapters(snapshots: Dictionary(snapshots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }))
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

    // MARK: Changes

    private var actions: TripActions {
        TripActions(
            changeDates: changeDates,
            makePreview: makePreview,
            addPhotos: { ids, target in
                edit(String(localized: "Added")) { session in
                    switch target {
                    case let .trip(trip): TripEdits.add(ids, to: trip, session: session)
                    case let .group(group): TripEdits.add(ids, to: group, session: session)
                    }
                }
            },
            removeDay: { day, target in
                edit(String(localized: "Day taken out")) { session in
                    switch target {
                    case let .trip(trip): TripEdits.removeDay(day, from: trip, session: session)
                    case let .group(group): TripEdits.removeDay(day, from: group, session: session)
                    }
                }
            },
            split: { day, trip in
                let session = TripEdits.Session(context: modelContext)
                guard let part = TripEdits.split(trip, at: day, session: session) else { return }
                post(TripNotice(message: String(localized: "Split off “\(part.effectiveName)”"), undo: session.undo))
            },
            merge: { other, trip in
                let name = other.effectiveName
                edit(String(localized: "Merged “\(name)” into this trip")) { TripEdits.merge(other, into: trip, session: $0) }
            },
            delete: { target in
                let name = target.name
                closeTrip()
                edit(String(localized: "Deleted “\(name)”")) { session in
                    switch target {
                    case let .trip(trip): TripEdits.delete(trip, session: session)
                    case let .group(group): TripEdits.delete(group, session: session)
                    }
                }
            },
            rename: { target, name in
                switch target {
                case let .trip(trip): TripRenaming.rename(trip, to: name, context: modelContext)
                case let .group(group):
                    let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.isEmpty, value != group.name else { return }
                    group.name = value
                    group.updatedAt = .now
                    try? modelContext.save()
                }
            },
            setCover: { tripID, itemID in
                var choices = TripCoverChoice.decode(coverStore)
                choices[tripID] = itemID
                coverStore = TripCoverChoice.encode(choices)
            }
        )
    }

    /// What new dates would do, from photos gathered once when the dates open.
    private func makePreview(_ target: ChapterTarget) -> (Date, Date) -> TripEdits.Plan {
        let calendar = Calendar.current
        switch target {
        case let .trip(trip):
            let members = TripEdits.members(context: modelContext)
            return { TripEdits.plan(for: trip, start: $0, end: $1, members: members, calendar: calendar) }
        case let .group(group):
            let members = TripEdits.members(of: group, context: modelContext)
            return { TripEdits.plan(for: group.id, start: $0, end: $1, members: members, calendar: calendar) }
        }
    }

    private func edit(_ message: String, _ change: (TripEdits.Session) -> Void) {
        let session = TripEdits.Session(context: modelContext)
        change(session)
        guard !session.undo.isEmpty else { return }
        post(TripNotice(message: message, undo: session.undo))
    }

    private func changeDates(_ target: ChapterTarget, start: Date, end: Date) {
        let session = TripEdits.Session(context: modelContext)
        guard case let .trip(trip) = target else {
            if case let .group(group) = target {
                let result = TripEdits.changeDates(of: group, start: start, end: end, session: session)
                post(TripNotice(message: String(localized: "Dates changed · \(result.joined) added · \(result.left) taken out"), undo: session.undo))
            }
            return
        }
        let outcome = TripEdits.changeDates(of: trip, start: start, end: end, session: session)
        var notice = TripNotice(
            message: String(localized: "Dates changed · \(outcome.joined) added · \(outcome.left) taken out"),
            undo: outcome.undo
        )
        let others = outcome.elsewhere.flatMap(\.itemIDs)
        if !others.isEmpty {
            let names = outcome.elsewhere.map { "“\($0.name)”" }.joined(separator: ", ")
            notice.offer = TripNotice.Offer(
                tripID: trip.id,
                text: String(localized: "Photos in these dates that belong to \(names): \(others.count)"),
                itemIDs: others
            )
        }
        post(notice)
    }

    private func createChapter(named name: String, type: ChapterType, symbol: String?, start: Date, end: Date) {
        guard type == .trip else {
            let session = TripEdits.Session(context: modelContext)
            let group = TripEdits.createChapter(named: name, type: type, symbol: symbol, start: start, end: end, session: session)
            let count = TripEdits.memberIDs(of: group, context: modelContext).count
            post(TripNotice(message: String(localized: "New chapter · \(count) photos"), undo: session.undo))
            withAnimation(Motion.animation(Motion.settle, reduceMotion: reduceMotion)) {
                selection.openTripID = Self.chapterID(group)
            }
            return
        }
        createTrip(named: name, start: start, end: end)
    }

    private func createTrip(named name: String, start: Date, end: Date) {
        let session = TripEdits.Session(context: modelContext)
        let created = TripEdits.create(named: name, start: start, end: end, session: session)
        var notice = TripNotice(
            message: String(localized: "New trip · \(created.outcome.joined) photos added"),
            undo: created.outcome.undo
        )
        let others = created.outcome.elsewhere.flatMap(\.itemIDs)
        if !others.isEmpty {
            let names = created.outcome.elsewhere.map { "“\($0.name)”" }.joined(separator: ", ")
            notice.offer = TripNotice.Offer(
                tripID: created.trip.id,
                text: String(localized: "Photos in these dates that belong to \(names): \(others.count)"),
                itemIDs: others
            )
        }
        post(notice)
        withAnimation(Motion.animation(Motion.settle, reduceMotion: reduceMotion)) {
            selection.openTripID = created.trip.id
        }
    }

    private func adopt(_ notice: TripNotice) {
        guard let offer = notice.offer, let trip = tripByID[offer.tripID] else { return }
        let session = TripEdits.Session(context: modelContext, continuing: notice.undo)
        TripEdits.add(offer.itemIDs, to: trip, session: session)
        post(TripNotice(message: String(localized: "Added to the trip"), undo: session.undo))
    }

    private func undo(_ notice: TripNotice) {
        undoManager?.removeAllActions(withTarget: selection)
        TripEdits.undo(notice.undo, context: modelContext)
        self.notice = nil
    }

    /// Shows the note and puts the change on ⌘Z, replacing the previous one.
    private func post(_ notice: TripNotice) {
        undoManager?.removeAllActions(withTarget: selection)
        let context = modelContext
        let undo = notice.undo
        undoManager?.registerUndo(withTarget: selection) { _ in
            MainActor.assumeIsolated { TripEdits.undo(undo, context: context) }
        }
        undoManager?.setActionName(notice.message)
        self.notice = notice
    }

    // MARK: Lookups

    /// Other trips, nearest in time first, for "Merge with".
    private func mergeCandidates(for trip: TimelineTrip) -> [TripLink] {
        guard !trip.isUnsorted else { return [] }
        let anchor = trip.startDate ?? .distantPast
        guard tripByID[trip.id] != nil else { return [] }
        return allChapters
            .filter { !$0.isUnsorted && $0.id != trip.id && tripByID[$0.id] != nil }
            .sorted { abs(($0.startDate ?? .distantPast).timeIntervalSince(anchor)) < abs(($1.startDate ?? .distantPast).timeIntervalSince(anchor)) }
            .prefix(8)
            .map { TripLink(id: $0.id, name: TripText.name($0)) }
    }

    /// Photos in no trip from the three days before and after the trip, by day.
    private func daysAround(_ trip: TimelineTrip) -> [TripNearbyDay] {
        guard !trip.isUnsorted, let start = trip.startDate ?? trip.orderedItems.compactMap(\.date).min() else { return [] }
        let end = trip.endDate ?? start
        let calendar = Calendar.autoupdatingCurrent
        guard let from = calendar.date(byAdding: .day, value: -3, to: calendar.startOfDay(for: start)),
              let to = calendar.date(byAdding: .day, value: 4, to: calendar.startOfDay(for: end)) else { return [] }
        let first = calendar.startOfDay(for: start)
        let last = TripEdits.endOfDay(end, calendar: calendar)
        var byDay: [Date: [MediaItem]] = [:]
        // Around a trip: photos in no trip. Around another chapter: photos not in it.
        let isTrip = tripByID[trip.id] != nil
        let inside = Set(trip.orderedItems.map(\.id))
        for item in items where isTrip ? (item.trip == nil && item.tripID == nil) : !inside.contains(item.id) {
            guard let date = item.effectiveCaptureDate, date >= from, date < to, date < first || date > last else { continue }
            byDay[calendar.startOfDay(for: date), default: []].append(item)
        }
        return byDay.keys.sorted().map { day in
            let photos = byDay[day, default: []].sorted { ($0.effectiveCaptureDate ?? .distantPast) < ($1.effectiveCaptureDate ?? .distantPast) }
            return TripNearbyDay(date: day, isBefore: day < first, itemIDs: photos.map(\.id))
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

/// What the Trips pages can change, handed down to the views that offer it.
struct TripActions {
    var changeDates: (ChapterTarget, Date, Date) -> Void
    /// Gathers the photos once and returns what given dates would do.
    var makePreview: (ChapterTarget) -> (Date, Date) -> TripEdits.Plan
    var addPhotos: ([String], ChapterTarget) -> Void
    /// Days by their `yyyy-MM-dd` key, as the page groups them.
    var removeDay: (String, ChapterTarget) -> Void
    var split: (String, Trip) -> Void
    /// The first trip merges into the second.
    var merge: (Trip, Trip) -> Void
    var delete: (ChapterTarget) -> Void
    var rename: (ChapterTarget, String) -> Void
    var setCover: (String, String) -> Void
}

/// The stored chapter behind a card or page: a trip, or another kind.
enum ChapterTarget {
    case trip(Trip)
    case group(UserGroup)

    var type: ChapterType {
        switch self {
        case .trip: .trip
        case let .group(group): group.chapterType
        }
    }

    var symbol: String {
        switch self {
        case .trip: ChapterType.trip.defaultSymbol
        case let .group(group): group.chapterSymbol
        }
    }

    var name: String {
        switch self {
        case let .trip(trip): trip.effectiveName
        case let .group(group): group.name
        }
    }

    var startDate: Date? {
        switch self {
        case let .trip(trip): trip.startDate
        case let .group(group): group.chapterInfo.startDate
        }
    }

    var endDate: Date? {
        switch self {
        case let .trip(trip): trip.endDate
        case let .group(group): group.chapterInfo.endDate
        }
    }

    var trip: Trip? {
        if case let .trip(trip) = self { return trip }
        return nil
    }
}

/// The last change to a trip, with its Undo and sometimes a question.
struct TripNotice: Identifiable {
    struct Offer {
        let tripID: String
        let text: String
        let itemIDs: [String]
    }

    let id = UUID()
    let message: String
    let undo: TripEdits.Undo
    var offer: Offer?
}

/// Photos in no trip from one day just before or after a trip.
struct TripNearbyDay: Identifiable {
    let date: Date
    let isBefore: Bool
    let itemIDs: [String]
    var id: Date { date }
}

/// A slim bar at the bottom of the page: what changed, Undo, and when
/// photos of other trips fall in the new dates, the offer to move them.
private struct TripNoticeBar: View {
    let notice: TripNotice
    let onUndo: () -> Void
    let onAdopt: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Paper.accent)
                Text(notice.message)
                    .foregroundStyle(Paper.ink)
                    .lineLimit(2)
                    .accessibilityIdentifier("trips.notice")
                Spacer(minLength: 8)
                Button(String(localized: "Undo"), action: onUndo)
                    .accessibilityIdentifier("trips.notice.undo")
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Paper.muted)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Close"))
                .accessibilityLabel(String(localized: "Close"))
            }
            if let offer = notice.offer {
                HStack(spacing: 12) {
                    Text(offer.text)
                        .font(.callout)
                        .foregroundStyle(Paper.muted)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Button(String(localized: "Move them here"), action: onAdopt)
                        .accessibilityIdentifier("trips.notice.adopt")
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(maxWidth: 560)
        .background(Paper.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: Paper.shadow.opacity(0.06), radius: 1, y: 1)
        .shadow(color: Paper.shadow.opacity(0.12), radius: 14, y: 5)
        .padding(.horizontal, 16)
    }
}

// MARK: - Shelf

private struct TripShelfView: View {
    let trips: [TimelineTrip]
    let types: [ChapterType]
    @Binding var filterRaw: String
    let target: (String) -> ChapterTarget?
    let itemByID: [String: MediaItem]
    let covers: [String: String]
    let memories: [CollectionMemory]
    let returnTripID: String?
    let actions: TripActions
    let onOpen: (TimelineTrip) -> Void
    let onNew: () -> Void

    private var chapterCount: Int { trips.filter { !$0.isUnsorted }.count }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .center, spacing: 18) {
                    if types.count > 1 || !filterRaw.isEmpty {
                        ChapterFilterBar(types: types, filterRaw: $filterRaw)
                            .frame(maxWidth: 880, alignment: .leading)
                    }
                    ForEach(trips) { trip in
                        TripCoverCard(
                            trip: trip,
                            target: target(trip.id),
                            covers: covers(for: trip),
                            photos: trip.orderedItems.compactMap { itemByID[$0.id] },
                            memory: memories.first { $0.scope == .trip && $0.scopeKey == trip.id }?.text,
                            actions: actions,
                            onOpen: { onOpen(trip) }
                        )
                        .id(trip.id)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, PaperMetrics.screenInset)
                .padding(.top, PaperMetrics.screenTopInset)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.automatic)
            .background(Paper.canvas)
            // The page's name lives in the window's title bar, not in the page.
            .navigationTitle(String(localized: "Chapters"))
            .navigationSubtitle(String(localized: "\(chapterCount) chapters"))
            .toolbar {
                // On Chapters, + starts a chapter.
                ToolbarItem(placement: .primaryAction) {
                    Button(action: onNew) {
                        Label(String(localized: "New chapter"), systemImage: "plus")
                    }
                    .help(String(localized: "New chapter"))
                    .accessibilityIdentifier("trips.new")
                }
            }
            .onAppear {
                if let returnTripID { proxy.scrollTo(returnTripID, anchor: .center) }
            }
        }
    }

    /// The chosen cover in front, if it is still in the trip; the usual pair otherwise.
    private func covers(for trip: TimelineTrip) -> [MediaItem] {
        let automatic = trip.covers.compactMap { itemByID[$0.id] }
        guard let chosenID = covers[trip.id],
              trip.orderedItems.contains(where: { $0.id == chosenID }),
              let chosen = itemByID[chosenID] else { return automatic }
        let second = automatic.first { $0.id != chosenID }
        return [chosen] + (second.map { [$0] } ?? [])
    }
}

/// One trip as a card in three parts: two photos laid on each other like
/// prints; the dates, the serif name, the route and the counts; and a small
/// drawn map of the route. One tone lighter than the page, no outline.
/// Narrow windows drop the map first, then shrink the prints.
private struct TripCoverCard: View {
    let trip: TimelineTrip
    let target: ChapterTarget?
    let covers: [MediaItem]
    let photos: [MediaItem]
    let memory: String?
    let actions: TripActions
    let onOpen: () -> Void
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @State private var isPickingCover = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 8, style: .continuous) }
    private var stops: [TripRouteStop] { trip.routeStops }
    private var type: ChapterType { target?.type ?? .trip }

    /// Trips and events show where; a celebration its date; other stretches
    /// of time how the photos spread over the days.
    private var hasSideView: Bool {
        switch type {
        case .trip, .event: !stops.isEmpty
        case .celebration: trip.startDate != nil
        case .period, .custom: trip.itemCount > 0
        }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            content(printScale: 0.8, showsMap: hasSideView)
            content(printScale: 0.8, showsMap: false)
            content(printScale: 0.62, showsMap: false)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: 880, alignment: .leading)
        .background(trip.isUnsorted ? Paper.well.opacity(0.6) : Paper.raised, in: shape)
        .contentShape(shape)
        .onTapGesture(perform: onOpen)
        .shadow(color: Paper.shadow.opacity(isHovering ? 0.07 : 0.04), radius: 1, y: 1)
        .shadow(color: Paper.shadow.opacity(isHovering ? 0.08 : 0.03), radius: isHovering ? 12 : 6, y: isHovering ? 4 : 2)
        .onHover { hovering in
            withAnimation(Motion.animation(Motion.settle, reduceMotion: reduceMotion)) { isHovering = hovering }
        }
        .help(String(localized: "Open this trip"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(TripText.name(trip)))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onOpen() }
        .accessibilityIdentifier("trips.card.\(trip.id)")
    }

    private func content(printScale: CGFloat, showsMap: Bool) -> some View {
        HStack(alignment: .top, spacing: 22 * printScale) {
            prints(scale: printScale)

            VStack(alignment: .leading, spacing: 7) {
                if let span = TripText.dateSpan(trip, locale: locale) {
                    dates(span: span)
                }
                Text(TripText.name(trip))
                    .font(.system(size: 22, weight: .medium, design: .serif))
                    .foregroundStyle(Paper.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.bottom, 4)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .stroke(Paper.rule, style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                            .frame(height: 1)
                    }
                    .accessibilityIdentifier("trips.card.name.\(trip.id)")
                if !trip.cityNames.isEmpty {
                    Text(trip.cityNames.joined(separator: " → "))
                        .font(.subheadline)
                        .foregroundStyle(Paper.ink)
                        .lineLimit(2)
                }
                Text(TripText.counts(trip))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Paper.muted)
                    .lineLimit(1)
                if let memory {
                    Text(memory)
                        .font(.system(.footnote, design: .serif).italic())
                        .foregroundStyle(Paper.muted)
                        .lineLimit(2)
                        .padding(.top, 2)
                }
            }
            .padding(.top, 4)
            // A fixed ideal width lets ViewThatFits judge by the layout, not by how long the name is.
            .frame(minWidth: 210, idealWidth: 230, maxWidth: .infinity, alignment: .leading)

            if showsMap {
                sideView
                    .frame(width: 200, height: 148 * printScale / 0.8)
            }
        }
    }

    @ViewBuilder
    private var sideView: some View {
        switch type {
        case .trip, .event:
            TripRouteMap(stops: stops)
        case .celebration:
            ChapterAnniversary(date: trip.startDate ?? .now)
        case .period, .custom:
            ChapterDensityStrip(trip: trip)
        }
    }

    /// The prints; clicking them picks another cover.
    @ViewBuilder
    private func prints(scale: CGFloat) -> some View {
        let printsView = TripPrints(covers: covers, lifted: isHovering, scale: scale)
            .frame(width: 262 * scale, height: 186 * scale)
        if trip.isUnsorted || photos.count < 2 {
            printsView
        } else {
            Button { isPickingCover = true } label: { printsView.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help(String(localized: "Choose the cover"))
                .accessibilityLabel(String(localized: "Choose the cover"))
                .accessibilityIdentifier("trips.cover.\(trip.id)")
                .popover(isPresented: $isPickingCover, arrowEdge: .trailing) {
                    TripCoverPicker(photos: photos, current: covers.first?.id) { item in
                        actions.setCover(trip.id, item.id)
                        isPickingCover = false
                    }
                }
        }
    }

    @ViewBuilder
    private func dates(span: String) -> some View {
        let line = HStack(spacing: 6) {
            if type != .trip, let target {
                Label(type.label, systemImage: target.symbol)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(Paper.accent)
                Text(verbatim: "·")
            }
            Text(TripText.dateLine(span: span, trip: trip))
        }
        .font(.footnote)
        .foregroundStyle(Paper.muted)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        if let target {
            TripDatesControl(
                startDate: target.startDate,
                endDate: target.endDate,
                photoDates: trip.orderedItems.compactMap(\.date),
                identifier: "trips.card.dates.\(trip.id)",
                makePreview: { actions.makePreview(target) },
                onApply: { actions.changeDates(target, $0, $1) }
            ) { line }
        } else {
            line
        }
    }
}

/// Every photo of the trip, to pick the one in front.
private struct TripCoverPicker: View {
    let photos: [MediaItem]
    let current: String?
    let onPick: (MediaItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PaperFormLabel(String(localized: "Choose the cover"))
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(76), spacing: 6), count: 4), spacing: 6) {
                    ForEach(photos, id: \.id) { item in
                        Button { onPick(item) } label: {
                            ThumbnailView(item: item, width: 76, height: 76)
                                .frame(width: 76, height: 76)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                .overlay {
                                    if item.id == current {
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .stroke(Paper.accent, lineWidth: 2.5)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(item.title)
                        .accessibilityIdentifier("trips.cover.pick.\(item.id)")
                    }
                }
            }
            .frame(width: 4 * 76 + 3 * 6, height: min(CGFloat((photos.count + 3) / 4) * 82, 330))
        }
        .padding(14)
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
                        Image(systemName: "book.pages")
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
    /// The stored chapter, for changing it; `nil` for photos in no trip.
    let target: ChapterTarget?
    let otherTrips: [TripLink]
    let around: [TripNearbyDay]
    let itemByID: [String: MediaItem]
    let memories: [CollectionMemory]
    let actions: TripActions
    let onBack: () -> Void
    @Environment(SelectionModel.self) private var selection
    @Environment(\.modelContext) private var modelContext
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

    private var firstDatedDayID: String? { trip.days.first { $0.date != nil }?.id }

    private var model: Trip? { target?.trip }

    /// A long chapter, like a summer, gets a heading at each new month.
    private var monthStarts: Set<String> {
        guard trip.datedDayCount > 45 else { return [] }
        var starts: Set<String> = []
        var previous: String?
        for day in trip.days {
            guard let key = day.memoryKey else { continue }
            let month = String(key.prefix(7))
            if month != previous { starts.insert(day.id) }
            previous = month
        }
        return starts
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    // The trip's name is in the title bar; its dates lead the page
                    // and change when clicked.
                    if let span = TripText.dateSpan(trip, locale: locale) {
                        let heading = HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(span)
                                .font(.system(size: 21, weight: .medium, design: .serif))
                                .foregroundStyle(Paper.ink)
                            if target != nil {
                                Image(systemName: "calendar")
                                    .font(.callout)
                                    .foregroundStyle(Paper.accent)
                            }
                        }
                        if let target {
                            TripDatesControl(
                                startDate: target.startDate,
                                endDate: target.endDate,
                                photoDates: trip.orderedItems.compactMap(\.date),
                                identifier: "trips.dates",
                                makePreview: { actions.makePreview(target) },
                                onApply: { actions.changeDates(target, $0, $1) }
                            ) { heading }
                        } else {
                            heading
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
                        if monthStarts.contains(day.id), let date = day.date {
                            Text(date, format: .dateTime.month(.wide).year().locale(locale))
                                .font(.caption.weight(.semibold))
                                .textCase(.uppercase)
                                .foregroundStyle(Paper.muted)
                                .padding(.bottom, -24)
                        }
                        TripDaySection(
                            day: day,
                            number: dayNumbers[day.id],
                            memories: day.memoryKey.map { key in
                                memories.filter { $0.scope != .trip && $0.scopeKey == key }
                            } ?? [],
                            itemByID: itemByID,
                            onOpen: open,
                            dayActions: dayActions(for: day)
                        )
                    }
                }

                if let target, !around.isEmpty {
                    TripAroundSection(days: around, isTrip: model != nil, itemByID: itemByID) { day in
                        actions.addPhotos(day.itemIDs, target)
                    }
                    .padding(.top, 48)
                }
            }
            .padding(.horizontal, PaperMetrics.screenInset)
            .padding(.top, PaperMetrics.screenTopInset)
            .padding(.bottom, 80)
        }
        .scrollIndicators(.automatic)
        .background(Paper.canvas)
        // The title bar holds the trip's name; double-click it to rename.
        .modifier(TripWindowTitle(name: TripText.name(trip), target: target, rename: actions.rename))
        .navigationSubtitle(target.map { $0.type.label } ?? String(localized: "Chapters"))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: onBack) {
                    Label(String(localized: "All chapters"), systemImage: "chevron.left")
                }
                .help(String(localized: "All chapters"))
                .keyboardShortcut("[", modifiers: .command)
                .accessibilityIdentifier("trips.back")
            }
            if let target {
                ToolbarItem {
                    Menu {
                        if let model, !otherTrips.isEmpty {
                            Section(String(localized: "Merge with")) {
                                ForEach(otherTrips) { other in
                                    Button(other.name) { merge(other, into: model) }
                                        .accessibilityIdentifier("trips.merge.\(other.id)")
                                }
                            }
                        }
                        Button(String(localized: "Delete this chapter"), role: .destructive) {
                            actions.delete(target)
                        }
                        .accessibilityIdentifier("trips.delete")
                    } label: {
                        Label(String(localized: "More"), systemImage: "ellipsis.circle")
                    }
                    .help(String(localized: "Merge or delete"))
                    .accessibilityIdentifier("trips.more")
                }
            }
        }
    }

    private func dayActions(for day: TimelineDay) -> TripDayActions? {
        guard let target, day.date != nil, let key = day.memoryKey else { return nil }
        return TripDayActions(
            remove: { actions.removeDay(key, target) },
            split: day.id == firstDatedDayID || model == nil ? nil : { if let model { actions.split(key, model) } }
        )
    }

    private func merge(_ link: TripLink, into model: Trip) {
        guard let other = try? modelContext.fetch(FetchDescriptor<Trip>()).first(where: { $0.id == link.id }) else { return }
        actions.merge(other, model)
    }

    /// A photo opens in the large viewer, paging through the whole trip.
    private func open(_ itemID: String) {
        selection.select(itemID)
        selection.openViewer(itemID, in: trip.orderedItems.map(\.id))
    }
}

/// What a day inside a trip offers in its menu.
struct TripDayActions {
    let remove: () -> Void
    /// `nil` on the first day, which cannot start a new trip.
    let split: (() -> Void)?
}

/// The days just before and after the trip whose photos are in no trip,
/// each with a button to add it.
private struct TripAroundSection: View {
    let days: [TripNearbyDay]
    /// Around a trip: photos in no trip. Around another chapter: photos not in it.
    let isTrip: Bool
    let itemByID: [String: MediaItem]
    let onAdd: (TripNearbyDay) -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(isTrip ? LocalizedStringKey("Around this trip") : LocalizedStringKey("Around this chapter"))
                    .font(.system(size: 17, weight: .medium, design: .serif))
                    .foregroundStyle(Paper.ink)
                Text(isTrip ? LocalizedStringKey("Photos from the days just before and after that are in no trip.") : LocalizedStringKey("Photos from the days just before and after."))
                    .font(.caption)
                    .foregroundStyle(Paper.muted)
            }
            ForEach(days) { day in
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(day.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().locale(locale))
                            .font(.callout)
                            .foregroundStyle(Paper.ink)
                        Text(day.isBefore ? String(localized: "chapter.around.before", defaultValue: "Before") : String(localized: "chapter.around.after", defaultValue: "After"))
                            .font(.caption2)
                            .foregroundStyle(Paper.muted)
                    }
                    .frame(width: 92, alignment: .leading)
                    HStack(spacing: 4) {
                        ForEach(day.itemIDs.prefix(6), id: \.self) { id in
                            if let item = itemByID[id] {
                                ThumbnailView(item: item, width: 44, height: 44)
                                    .frame(width: 44, height: 44)
                                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                            }
                        }
                        if day.itemIDs.count > 6 {
                            Text(verbatim: "+\(day.itemIDs.count - 6)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Paper.muted)
                                .padding(.leading, 4)
                        }
                    }
                    .accessibilityHidden(true)
                    Spacer(minLength: 8)
                    Button {
                        onAdd(day)
                    } label: {
                        Label(isTrip ? String(localized: "Add to trip") : String(localized: "Add"), systemImage: "plus")
                    }
                    .accessibilityIdentifier("trips.around.add.\(TripAroundSection.key(day.date))")
                }
                .padding(10)
                .background(Paper.well.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
    }

    static func key(_ date: Date) -> String {
        let parts = Calendar.autoupdatingCurrent.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
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
    /// Inside a trip: take the day out, or start a new trip from it.
    var dayActions: TripDayActions? = nil
    @Environment(\.locale) private var locale

    private var photoCount: Int { day.places.reduce(0) { $0 + $1.photoCount } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let number {
                    Text(String(localized: "Day \(number)"))
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
                        Label(trip.name, systemImage: "airplane.departure")
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
                if let dayActions {
                    Menu {
                        Button(String(localized: "Take this day out of the trip"), action: dayActions.remove)
                        if let split = dayActions.split {
                            Button(String(localized: "Start a new trip from this day"), action: split)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(Paper.muted)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(String(localized: "Change this day"))
                    .accessibilityLabel(String(localized: "Change this day"))
                    .accessibilityIdentifier("trips.day.menu.\(day.memoryKey ?? day.id)")
                }
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
    @Environment(PhotoStackModel.self) private var stacks
    @Environment(\.locale) private var locale

    private let columns = [GridItem(.adaptive(minimum: 128, maximum: 200), spacing: 8, alignment: .top)]

    /// A burst shows once, as a stack with its cover.
    private var shownItems: [(item: TimelineItemSnapshot, count: Int)] {
        let byID = Dictionary(place.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return stacks.collapse(place.items.map(\.id)).compactMap { entry in
            byID[entry.id].map { ($0, entry.isStack ? entry.count : 1) }
        }
    }

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
                ForEach(shownItems, id: \.item.id) { shown in
                    let item = shown.item
                    Button { onOpen(item.id) } label: {
                        thumbnail(for: item, stackCount: shown.count)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Open photo"))
                    .accessibilityLabel(item.title.isEmpty ? item.id : item.title)
                    .accessibilityIdentifier("trips.photo.\(item.id)")
                    // Outside the button, so the count is its own element.
                    .overlay(alignment: .bottomTrailing) {
                        if shown.count > 1 {
                            StackCountBadge(count: shown.count)
                                .accessibilityIdentifier("trips.stack.\(item.id)")
                                .allowsHitTesting(false)
                        }
                    }
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

    private func thumbnail(for item: TimelineItemSnapshot, stackCount: Int) -> some View {
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
        // Rows here are close together: thin edges, like the dense Library grid.
        .stackedPaper(stackCount, isCompact: true, cornerRadius: 10)
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

/// The trip's dates, shown as the label and changed in a popover: pick a
/// start and an end, see which photos would join or leave, then Apply.
/// Nothing changes until Apply; Escape or clicking away cancels.
private struct TripDatesControl<Content: View>: View {
    let startDate: Date?
    let endDate: Date?
    let photoDates: [Date]
    let identifier: String
    let makePreview: () -> (Date, Date) -> TripEdits.Plan
    let onApply: (Date, Date) -> Void
    @ViewBuilder let label: () -> Content
    @State private var isEditing = false
    @State private var start = Date.now
    @State private var end = Date.now
    /// Made when the popover opens, so the preview follows the pickers cheaply.
    @State private var preview: ((Date, Date) -> TripEdits.Plan)?

    var body: some View {
        Button {
            start = startDate ?? photoDates.min() ?? .now
            end = endDate ?? photoDates.max() ?? start
            preview = makePreview()
            isEditing = true
        } label: {
            label().contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "Change the dates"))
        .accessibilityIdentifier(identifier)
        .popover(isPresented: $isEditing, arrowEdge: .bottom) {
            popover
        }
    }

    private var calendar: Calendar { .current }

    private var isUnchanged: Bool {
        guard let current = startDate, let currentEnd = endDate else { return false }
        return calendar.isDate(current, inSameDayAs: start) && calendar.isDate(currentEnd, inSameDayAs: end)
    }

    private var popover: some View {
        let plan = preview?(start, max(start, end)) ?? TripEdits.Plan()
        let elsewhere = plan.elsewhere.values.reduce(0) { $0 + $1.count }
        return VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    PaperFormLabel(String(localized: "Starts"))
                    DatePicker("", selection: $start, displayedComponents: .date)
                        .labelsHidden()
                        .accessibilityIdentifier("trips.dates.start")
                }
                GridRow {
                    PaperFormLabel(String(localized: "Ends"))
                    DatePicker("", selection: $end, in: start..., displayedComponents: .date)
                        .labelsHidden()
                        .accessibilityIdentifier("trips.dates.end")
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                if plan.joining.isEmpty && plan.leaving.isEmpty {
                    Text("No photos change")
                } else {
                    Text(String(localized: "Will add \(plan.joining.count) · will take out \(plan.leaving.count)"))
                }
                if elsewhere > 0 {
                    Text(String(localized: "\(elsewhere) in other trips stay there"))
                        .foregroundStyle(Paper.muted)
                }
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(Paper.ink)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("trips.dates.preview")
            HStack {
                Button(String(localized: "Use photo dates")) {
                    if let first = photoDates.min(), let last = photoDates.max() {
                        start = first
                        end = last
                    }
                }
                .disabled(photoDates.isEmpty)
                Spacer(minLength: 16)
                Button(String(localized: "Cancel")) { isEditing = false }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Apply")) {
                    isEditing = false
                    onApply(start, max(start, end))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isUnchanged)
                .accessibilityIdentifier("trips.dates.apply")
            }
        }
        .padding(16)
        .frame(minWidth: 320)
    }
}

/// The window title is the trip's name, editable in place like a document
/// title; photos in no trip get a plain title.
private struct TripWindowTitle: ViewModifier {
    let name: String
    let target: ChapterTarget?
    let rename: (ChapterTarget, String) -> Void

    func body(content: Content) -> some View {
        if let target {
            content.navigationTitle(Binding(
                get: { name },
                set: { rename(target, $0) }
            ))
        } else {
            content.navigationTitle(name)
        }
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
