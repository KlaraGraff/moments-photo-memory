import Foundation
import MomentsCore

/// What the Library's filters and sections read from one photo, copied out of
/// SwiftData once. The grid's filtering and grouping then runs on these plain
/// values off the main thread, and a photo is read again only when it, its
/// memory or its place correction changed (`LibraryPhotoFactsCache`).
///
/// Place names are not copied here: they come from one table per place
/// (`LibraryPlaceFacts`), so a renamed place does not make every photo of it
/// be read again, and no photo's name is worked out per keystroke.
struct LibraryPhotoFacts: Equatable, Sendable {
    let id: String
    let captureDate: Date?
    let isScreenshot: Bool
    /// `MediaItem.kind.rawValue`.
    let kindRaw: String
    let isFavorite: Bool
    let tripID: String?
    let placeID: String?
    /// This person's own name for the photo's place, trimmed; nil when there
    /// is none or it is empty.
    let placeOverrideName: String?
    let hasWrittenMemory: Bool
    /// `PhotoNoteDay.key(for:)`: the day a day memory is matched by.
    let dayKey: String?
    /// The capture month as `yyyy-MM` (Gregorian, current time zone): the
    /// key of the month section a photo outside any chapter lands in.
    let monthKey: String?

    init(
        id: String,
        captureDate: Date?,
        isScreenshot: Bool = false,
        kindRaw: String = MediaKind.photo.rawValue,
        isFavorite: Bool = false,
        tripID: String? = nil,
        placeID: String? = nil,
        placeOverrideName: String? = nil,
        hasWrittenMemory: Bool = false,
        dayKey: String? = nil,
        monthKey: String? = nil
    ) {
        self.id = id
        self.captureDate = captureDate
        self.isScreenshot = isScreenshot
        self.kindRaw = kindRaw
        self.isFavorite = isFavorite
        self.tripID = tripID
        self.placeID = placeID
        self.placeOverrideName = placeOverrideName
        self.hasWrittenMemory = hasWrittenMemory
        self.dayKey = dayKey
        self.monthKey = monthKey
    }

    /// Reads one photo. Main actor: SwiftData models belong to the main
    /// context.
    @MainActor
    init(item: MediaItem, monthFormatter: DateFormatter) {
        let date: Date? = item.effectiveCaptureDate
        let override: String? = item.placeOverrideName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(
            id: item.id,
            captureDate: date,
            isScreenshot: item.isScreenshot,
            kindRaw: item.kind.rawValue,
            isFavorite: item.isFavorite,
            tripID: item.tripID,
            placeID: item.place?.id,
            placeOverrideName: override?.isEmpty == false ? override : nil,
            hasWrittenMemory: item.hasWrittenMemory,
            dayKey: PhotoNoteDay.key(for: item),
            monthKey: date.map { monthFormatter.string(from: $0) }
        )
    }
}

/// One place as the filters see it, read once per change to the places
/// instead of once per photo per pass.
struct LibraryPlaceFacts: Equatable, Sendable {
    /// `Place.name` as stored: what `effectivePlaceName` shows without a
    /// correction.
    let name: String
    /// `PlaceDisplayName.ownName(of:)`: this person's rename, else the
    /// import's name unless it is only a placeholder.
    let ownName: String?
    let parentID: String?

    @MainActor
    init(place: Place) {
        name = place.name
        ownName = PlaceDisplayName.ownName(of: place)
        parentID = place.parent?.id
    }

    init(name: String, ownName: String?, parentID: String?) {
        self.name = name
        self.ownName = ownName
        self.parentID = parentID
    }
}

/// The Library's filters and sections on `LibraryPhotoFacts`, for a run off
/// the main thread. Each rule is the one `LibraryFilterEngine` applies to a
/// `MediaItem`; `LibraryRegroupEngineTests` hold the two to the same result.
enum LibraryRegroupEngine {
    struct Input: Sendable {
        /// The Library's photos (no screenshots), in the store's order.
        let items: [LibraryPhotoFacts]
        /// The screenshots, for the ids the maps show while the Screenshots
        /// segment or a scope is on.
        let screenshots: [LibraryPhotoFacts]
        /// One person's or one place's photos, when a face or a place name was
        /// clicked.
        let scopeIDs: Set<String>?
        let criteria: LibraryFilterCriteria
        let editingItemID: String?
        let personIDsByMediaID: [String: Set<String>]
        /// The photos the typed words find, worked out from the search index.
        /// Nil only while nothing is typed.
        let searchMatches: Set<String>?
        let places: [String: LibraryPlaceFacts]
        /// `Trip.effectiveName` by trip id.
        let tripNames: [String: String]
        let stackIndex: PhotoStackIndex
        let calendar: Calendar
    }

    struct Output: Sendable {
        let filteredIDs: Set<String>
        /// The grid's photos in the order they were tested, the photo being
        /// edited last when only it is kept.
        let visibleIDs: [String]
        let publishedIDs: Set<String>
        /// The sections before bursts were folded.
        let unfolded: [LibrarySection]
        let sections: [LibrarySection]
        let stackCounts: [String: Int]
        let sectionDayKeys: [String: Set<String>]
    }

    /// False for what only other screens ask of the filters (possible
    /// screenshots, a tag) and for a search that the index could not answer;
    /// the caller then runs the old pass on the main thread.
    static func canRun(criteria: LibraryFilterCriteria, searchMatches: Set<String>?) -> Bool {
        criteria.screenshotFilter == .all
            && criteria.tagID == nil
            && (criteria.searchText.isEmpty || searchMatches != nil)
    }

    static func run(_ input: Input) -> Output {
        let criteria: LibraryFilterCriteria = input.criteria
        let scoped: [LibraryPhotoFacts]
        if let scopeIDs = input.scopeIDs {
            scoped = input.items.filter { scopeIDs.contains($0.id) }
        } else {
            scoped = input.items
        }
        let filtered: [LibraryPhotoFacts] = scoped.filter { matches($0, criteria: criteria, hidesScreenshots: true, input: input) }

        // Keeping a photo that the memory filter drops: only while someone
        // edits that photo's memory, and only when it passes without that
        // filter.
        var visible: [LibraryPhotoFacts] = filtered
        if criteria.memoryFilter != .all,
           let editingID = input.editingItemID,
           !filtered.contains(where: { $0.id == editingID }),
           let editing = scoped.first(where: { $0.id == editingID }) {
            var withoutMemoryFilter = criteria
            withoutMemoryFilter.memoryFilter = .all
            if matches(editing, criteria: withoutMemoryFilter, hidesScreenshots: true, input: input) {
                visible.append(editing)
            }
        }

        // The maps show the regular filters, so a scope does not shrink them;
        // the Screenshots segment is a Library-only choice.
        let publishedIDs: Set<String>
        if input.scopeIDs == nil && criteria.mediaType != .screenshot {
            publishedIDs = Set(filtered.map(\.id))
        } else {
            var published = criteria
            if published.mediaType == .screenshot { published.mediaType = .all }
            let all: [LibraryPhotoFacts] = input.items + input.screenshots
            publishedIDs = Set(all.lazy.filter { matches($0, criteria: published, hidesScreenshots: true, input: input) }.map(\.id))
        }

        let unfolded: [LibrarySection] = storySections(visible, tripNames: input.tripNames)
        let folded = LibraryFilterEngine.folding(unfolded, with: input.stackIndex)

        var dayKeyByID: [String: String] = [:]
        dayKeyByID.reserveCapacity(visible.count)
        for facts in visible {
            if let key = facts.dayKey { dayKeyByID[facts.id] = key }
        }
        var sectionDayKeys: [String: Set<String>] = [:]
        sectionDayKeys.reserveCapacity(folded.sections.count)
        for section in folded.sections {
            sectionDayKeys[section.id] = Set(section.itemIDs.compactMap { dayKeyByID[$0] })
        }

        return Output(
            filteredIDs: Set(filtered.map(\.id)),
            visibleIDs: visible.map(\.id),
            publishedIDs: publishedIDs,
            unfolded: unfolded,
            sections: folded.sections,
            stackCounts: folded.stackCounts,
            sectionDayKeys: sectionDayKeys
        )
    }

    /// `LibraryFilterEngine.matches` for one photo's facts.
    static func matches(
        _ facts: LibraryPhotoFacts,
        criteria: LibraryFilterCriteria,
        hidesScreenshots: Bool,
        input: Input
    ) -> Bool {
        if criteria.mediaType == .screenshot {
            guard facts.isScreenshot else { return false }
        } else if hidesScreenshots {
            guard !facts.isScreenshot else { return false }
        }
        let calendar: Calendar = input.calendar
        if let from = criteria.fromDate.map(calendar.startOfDay(for:)) {
            guard let date = facts.captureDate, date.isOnOrAfter(from) else { return false }
        }
        if let to = criteria.toDate,
           let toExclusive = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: to)) {
            guard let date = facts.captureDate, date < toExclusive else { return false }
        }
        if let placeID = criteria.placeID {
            guard matchesPlace(facts, filterID: placeID, places: input.places) else { return false }
        }
        if criteria.mediaType != .all,
           criteria.mediaType != .screenshot,
           facts.kindRaw != criteria.mediaType.rawValue {
            return false
        }
        if criteria.favoritesOnly && !facts.isFavorite { return false }
        if let tripKey = criteria.tripKey, facts.tripID != tripKey { return false }
        if let personID = criteria.personID,
           !input.personIDsByMediaID[facts.id, default: []].contains(personID) {
            return false
        }
        if !criteria.searchText.isEmpty {
            guard let matches = input.searchMatches, matches.contains(facts.id) else { return false }
        }
        switch criteria.memoryFilter {
        case .all:
            break
        case .hasMemory:
            guard facts.hasWrittenMemory else { return false }
        case .noMemory:
            guard !facts.hasWrittenMemory else { return false }
        }
        return true
    }

    /// The place filter's three kinds of id, as `LibraryFilterEngine.matches`
    /// reads them: a place name, an old "override:" name, or a place id that
    /// the photo's place is or is under.
    static func matchesPlace(_ facts: LibraryPhotoFacts, filterID: String, places: [String: LibraryPlaceFacts]) -> Bool {
        if filterID.hasPrefix(PlaceNames.optionPrefix) {
            let key = String(filterID.dropFirst(PlaceNames.optionPrefix.count))
            if let override = facts.placeOverrideName { return PlaceNames.key(override) == key }
            var current: String? = facts.placeID
            var depth = 0
            while let id = current, let place = places[id], depth < 4 {
                if let name = place.ownName, PlaceNames.key(name) == key { return true }
                current = place.parentID
                depth += 1
            }
            return false
        }
        if filterID.hasPrefix("override:") {
            let overrideName = String(filterID.dropFirst("override:".count))
            let effective: String? = facts.placeOverrideName ?? facts.placeID.flatMap { places[$0]?.name }
            return effective == overrideName
        }
        var current: String? = facts.placeID
        var depth = 0
        while let id = current, depth < 4 {
            if id == filterID { return true }
            current = places[id]?.parentID
            depth += 1
        }
        return false
    }

    /// `LibraryFilterEngine.sections(forVisibleItems:by: .story, sortOrder:
    /// .newestFirst)`: each chapter a section, the other photos by month.
    static func storySections(_ visible: [LibraryPhotoFacts], tripNames: [String: String]) -> [LibrarySection] {
        var bucketIndexByKey: [String: Int] = [:]
        var buckets: [(key: String, first: LibraryPhotoFacts, entries: [(id: String, date: Date?)])] = []
        bucketIndexByKey.reserveCapacity(min(visible.count, 64))
        for facts in visible {
            let key: String
            if let tripID = facts.tripID {
                key = "trip:\(tripID)"
            } else if let month = facts.monthKey {
                key = "month:\(month)"
            } else {
                key = "month:unknown"
            }
            if let index = bucketIndexByKey[key] {
                buckets[index].entries.append((id: facts.id, date: facts.captureDate))
            } else {
                bucketIndexByKey[key] = buckets.count
                buckets.append((key: key, first: facts, entries: [(id: facts.id, date: facts.captureDate)]))
            }
        }
        let sections: [LibrarySection] = buckets.map { bucket -> LibrarySection in
            let ordered = bucket.entries.sorted { lhs, rhs in
                switch (lhs.date, rhs.date) {
                case let (left?, right?) where left != right:
                    return left < right
                case (nil, .some):
                    return false
                case (.some, nil):
                    return true
                default:
                    return lhs.id < rhs.id
                }
            }
            var startDate: Date?
            var endDate: Date?
            for entry in ordered {
                guard let date = entry.date else { continue }
                if startDate == nil || date < startDate! { startDate = date }
                if endDate == nil || date > endDate! { endDate = date }
            }
            return LibrarySection(
                id: bucket.key,
                title: storyTitle(for: bucket.first, tripNames: tripNames),
                itemIDs: ordered.map(\.id),
                startDate: startDate,
                endDate: endDate
            )
        }
        return sections.sorted { lhs, rhs in
            let left = lhs.endDate ?? .distantPast
            let right = rhs.endDate ?? .distantPast
            if left != right { return left > right }
            return lhs.id < rhs.id
        }
    }

    private static func storyTitle(for facts: LibraryPhotoFacts, tripNames: [String: String]) -> String {
        if let tripID = facts.tripID { return tripNames[tripID] ?? String(localized: "Unsorted") }
        guard let date = facts.captureDate else { return String(localized: "Undated") }
        return date.formatted(.dateTime.year().month(.wide))
    }

    /// The formatter `monthKey` is written with: the same as the one
    /// `LibraryFilterEngine` keys month sections by.
    static func makeMonthFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }
}
