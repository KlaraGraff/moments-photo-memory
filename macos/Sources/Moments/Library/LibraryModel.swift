import Foundation
import Observation
import SwiftData
import MomentsCore

enum LibrarySortOrder: String, CaseIterable, Sendable {
    case oldestFirst
    case newestFirst
}

enum LibraryMediaTypeFilter: String, CaseIterable, Sendable {
    case all
    case photo
    case video
    case live
    case screenshot
}

enum LibraryMemoryFilter: String, CaseIterable, Sendable {
    case all
    case hasMemory
    case noMemory
}

enum LibraryGrouping: String, CaseIterable, Sendable {
    case trip
    case place
    case type
    case month
}

enum LibraryLaunchState {
    static let appStorageKey = "moments.library.firstLaunchCompleted"

    static func shouldShowImportFlow(hasCompletedFirstLaunch: Bool, itemCount: Int) -> Bool {
        !hasCompletedFirstLaunch && itemCount == 0
    }
}

enum LibraryScreenshotFilter: String, CaseIterable, Sendable {
    case all
    case possibleOnly
}

struct LibraryPlaceOption: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

/// The filters that shape the Library before it is grouped.
///
/// The model deliberately stays separate from SwiftData. It makes the AND
/// semantics testable with synthetic models and leaves relationship-derived
/// values (favorites, overrides, and memories) out of schema predicates.
struct LibraryFilterCriteria: Equatable, Sendable {
    var fromDate: Date?
    var toDate: Date?
    var placeID: String?
    var mediaType: LibraryMediaTypeFilter
    var favoritesOnly: Bool
    var tripKey: String?
    var screenshotFilter: LibraryScreenshotFilter
    var memoryFilter: LibraryMemoryFilter
    /// Optional tag identifier or normalized/display name used by smart groups.
    var tagID: String?
    /// A local Person identifier. The relationship is intentionally resolved
    /// by the caller from FaceObservation records so the media schema stays
    /// independent from the private People data.
    var personID: String?

    init(
        fromDate: Date? = nil,
        toDate: Date? = nil,
        placeID: String? = nil,
        mediaType: LibraryMediaTypeFilter = .all,
        favoritesOnly: Bool = false,
        tripKey: String? = nil,
        screenshotFilter: LibraryScreenshotFilter = .all,
        memoryFilter: LibraryMemoryFilter = .all,
        tagID: String? = nil,
        personID: String? = nil
    ) {
        self.fromDate = fromDate
        self.toDate = toDate
        self.placeID = placeID
        self.mediaType = mediaType
        self.favoritesOnly = favoritesOnly
        self.tripKey = tripKey
        self.screenshotFilter = screenshotFilter
        self.memoryFilter = memoryFilter
        self.tagID = tagID
        self.personID = personID
    }

    static let `default` = LibraryFilterCriteria()

    var isFiltered: Bool {
        self != .default
    }
}

struct LibrarySection: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let itemIDs: [String]
    let startDate: Date?
    let endDate: Date?

    var count: Int { itemIDs.count }
}

struct LibraryMemorySnapshot: Equatable, Sendable {
    let id: String
    let text: String
    let updatedAt: Date
    let revision: Int
    let author: MemoryAuthor
    let authorAccountID: String?

    init(
        id: String,
        text: String,
        updatedAt: Date,
        revision: Int,
        author: MemoryAuthor = .me,
        authorAccountID: String? = nil
    ) {
        self.id = id
        self.text = text
        self.updatedAt = updatedAt
        self.revision = revision
        self.author = author
        self.authorAccountID = authorAccountID
    }

    init(memory: Memory) {
        self.id = memory.id
        self.text = memory.text
        self.updatedAt = memory.updatedAt
        self.revision = memory.revision
        self.author = memory.author
        self.authorAccountID = memory.authorAccountID
    }

    var isAuthoredByCurrentUser: Bool {
        if let authorAccountID {
            return authorAccountID == MomentsAccount.localID
        }
        return author == .me
    }
}

enum LibraryMemoryPersistenceDecision: Equatable {
    case noChange
    case conflict
    case insert
    case update
    case delete
}

enum LibraryMemoryPersistence {
    static func decision(
        draft: String,
        wasEdited: Bool,
        baseline: LibraryMemorySnapshot?,
        stored: LibraryMemorySnapshot?
    ) -> LibraryMemoryPersistenceDecision {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard wasEdited else {
            if let stored { return draft == stored.text ? .noChange : .conflict }
            return trimmed.isEmpty ? .noChange : .conflict
        }

        if let stored, draft == stored.text {
            return .noChange
        }

        if let baseline {
            guard let stored,
                  stored.id == baseline.id,
                  stored.text == baseline.text,
                  stored.updatedAt == baseline.updatedAt,
                  stored.revision == baseline.revision else {
                return .conflict
            }
        } else if let stored {
            // A memory can arrive after the first edit (for example when the
            // import review sheet saves one for the same item). If it is
            // mine, merge the draft into that record; a partner's memory is
            // read-only and is handled by the editor instead of here.
            guard stored.isAuthoredByCurrentUser else { return .conflict }
            return trimmed.isEmpty ? .noChange : .update
        }

        guard let stored else {
            return trimmed.isEmpty ? .noChange : .insert
        }
        guard draft != stored.text else { return .noChange }
        return trimmed.isEmpty ? .delete : .update
    }
}

/// The app-layer mapping from SwiftData to the package's privacy-safe descriptor.
/// Explicit `true` is carried into the detector; `false` remains `nil` so a
/// heuristic can be presented as a possible screenshot without hiding the item.
enum MediaDescriptorMapper {
    static func descriptor(for item: MediaItem) -> MediaDescriptor {
        MediaDescriptor(
            id: item.id,
            captureDate: item.effectiveCaptureDate,
            pixelWidth: item.width,
            pixelHeight: item.height,
            isScreenshotFlag: item.isScreenshot ? true : nil,
            fileNameHint: item.title.isEmpty ? nil : item.title
        )
    }
}

/// Pure Library filtering and grouping logic, kept outside the view for XCTest.
enum LibraryFilterEngine {
    private static let detector = ScreenshotDetector()

    static func detection(for item: MediaItem) -> ScreenshotDetection {
        detector.detect(MediaDescriptorMapper.descriptor(for: item))
    }

    static func isPossibleScreenshot(_ item: MediaItem) -> Bool {
        !item.isScreenshot && detection(for: item).isScreenshot
    }

    static func filteredItems(
        _ items: [MediaItem],
        by criteria: LibraryFilterCriteria,
        calendar: Calendar = .current,
        personIDsByMediaID: [String: Set<String>] = [:]
    ) -> [MediaItem] {
        items.filter { matches($0, criteria: criteria, calendar: calendar, hidesScreenshots: true, personIDsByMediaID: personIDsByMediaID) }
    }

    /// Evaluates a single item against the shared filter semantics. Screenshot
    /// hiding belongs to the Library's normal segment; callers such as smart
    /// groups can disable it while still using the same predicate.
    static func matches(
        _ item: MediaItem,
        criteria: LibraryFilterCriteria,
        calendar: Calendar = .current,
        hidesScreenshots: Bool = false,
        personIDsByMediaID: [String: Set<String>] = [:]
    ) -> Bool {
        if criteria.mediaType == .screenshot {
            guard item.isScreenshot else { return false }
        } else if hidesScreenshots {
            // The Library hides screenshots in every segment except Screenshots.
            guard !item.isScreenshot else { return false }
        }
        if criteria.screenshotFilter == .possibleOnly && !isPossibleScreenshot(item) { return false }
        if let from = criteria.fromDate.map(calendar.startOfDay(for:)) {
            guard let captureDate = item.effectiveCaptureDate, captureDate >= from else { return false }
        }
        if let to = criteria.toDate,
           let toExclusive = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: to)) {
            guard let captureDate = item.effectiveCaptureDate, captureDate < toExclusive else { return false }
        }
        if let placeID = criteria.placeID {
            if placeID.hasPrefix("override:") {
                let overrideName = String(placeID.dropFirst("override:".count))
                guard item.effectivePlaceName == overrideName else { return false }
            } else {
                guard PlaceDisplayName.place(item.place, isWithin: placeID) else { return false }
            }
        }
        if criteria.mediaType != .all,
           criteria.mediaType != .screenshot,
           item.kind.rawValue != criteria.mediaType.rawValue {
            return false
        }
        if criteria.favoritesOnly && !item.isFavorite { return false }
        if let tripKey = criteria.tripKey, item.tripID != tripKey { return false }
        if let tagID = criteria.tagID,
           !item.tags.contains(where: { $0.id == tagID || $0.normalizedName == tagID || $0.displayName == tagID }) {
            return false
        }
        if let personID = criteria.personID,
           !personIDsByMediaID[item.id, default: []].contains(personID) {
            return false
        }
        switch criteria.memoryFilter {
        case .all:
            break
        case .hasMemory:
            guard item.latestMemory?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return false }
        case .noMemory:
            guard item.latestMemory?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else { return false }
        }
        return true
    }

    static func filteredItems(
        _ items: [MediaItem],
        by criteria: LibraryFilterCriteria,
        preservingEditingItemID editingItemID: String?,
        calendar: Calendar = .current,
        personIDsByMediaID: [String: Set<String>] = [:]
    ) -> [MediaItem] {
        let filtered = filteredItems(items, by: criteria, calendar: calendar, personIDsByMediaID: personIDsByMediaID)
        guard criteria.memoryFilter != .all,
              let editingItemID,
              !filtered.contains(where: { $0.id == editingItemID }) else {
            return filtered
        }

        var withoutMemoryFilter = criteria
        withoutMemoryFilter.memoryFilter = .all
        guard let editingItem = items.first(where: { $0.id == editingItemID }),
              filteredItems([editingItem], by: withoutMemoryFilter, calendar: calendar, personIDsByMediaID: personIDsByMediaID).isEmpty == false else {
            return filtered
        }
        return filtered + [editingItem]
    }

    /// Screenshots are a Library-only segment. Other screens receive the same
    /// filters without the segment selector narrowing them to screenshots.
    static func publishedItems(_ items: [MediaItem], by criteria: LibraryFilterCriteria, personIDsByMediaID: [String: Set<String>] = [:]) -> [MediaItem] {
        guard criteria.mediaType == .screenshot else {
            return filteredItems(items, by: criteria, personIDsByMediaID: personIDsByMediaID)
        }
        var withoutScreenshotSegment = criteria
        withoutScreenshotSegment.mediaType = .all
        return filteredItems(items, by: withoutScreenshotSegment, personIDsByMediaID: personIDsByMediaID)
    }

    static func filteredItems(
        _ items: [MediaItem],
        by criteria: LibraryFilterCriteria,
        observations: [FaceObservation],
        calendar: Calendar = .current
    ) -> [MediaItem] {
        var ids: [String: Set<String>] = [:]
        for observation in observations {
            guard let personID = observation.personID else { continue }
            ids[observation.mediaID, default: []].insert(personID)
        }
        return filteredItems(items, by: criteria, calendar: calendar, personIDsByMediaID: ids)
    }

    /// The legacy burst groups remain available to older callers. LibraryView
    /// uses `sections` below so the visible group matches the selected popup.
    static func groupedItems(
        _ items: [MediaItem],
        by criteria: LibraryFilterCriteria,
        sortOrder: LibrarySortOrder = .oldestFirst
    ) -> [MediaCollection] {
        let descriptors = filteredItems(items, by: criteria).map(MediaDescriptorMapper.descriptor(for:))
        let groups = CollectionGrouper().group(descriptors)
        return sortOrder == .oldestFirst ? groups : Array(groups.reversed())
    }

    static func sections(
        _ items: [MediaItem],
        by grouping: LibraryGrouping,
        criteria: LibraryFilterCriteria = .default,
        sortOrder: LibrarySortOrder = .newestFirst
    ) -> [LibrarySection] {
        sections(
            forVisibleItems: filteredItems(items, by: criteria),
            by: grouping,
            sortOrder: sortOrder
        )
    }

    /// Builds sections from an already filtered result. LibraryView uses this
    /// overload so a large collection is filtered only once per state change.
    static func sections(
        forVisibleItems visible: [MediaItem],
        by grouping: LibraryGrouping,
        sortOrder: LibrarySortOrder = .newestFirst
    ) -> [LibrarySection] {
        var buckets: [String: (title: String, items: [MediaItem])] = [:]

        for item in visible {
            let key = groupKey(for: item, grouping: grouping)
            let title = groupTitle(for: item, grouping: grouping)
            buckets[key, default: (title: title, items: [])].items.append(item)
        }

        let sections = buckets.map { key, bucket in
            let ordered = bucket.items.sorted(by: canonicalOrder)
            return LibrarySection(
                id: key,
                title: bucket.title,
                itemIDs: ordered.map(\.id),
                startDate: ordered.compactMap(\.effectiveCaptureDate).min(),
                endDate: ordered.compactMap(\.effectiveCaptureDate).max()
            )
        }

        return sections.sorted { lhs, rhs in
            let left = sortOrder == .oldestFirst ? (lhs.startDate ?? .distantPast) : (lhs.endDate ?? .distantPast)
            let right = sortOrder == .oldestFirst ? (rhs.startDate ?? .distantPast) : (rhs.endDate ?? .distantPast)
            if left != right { return sortOrder == .oldestFirst ? left < right : left > right }
            return lhs.id < rhs.id
        }
    }

    private static func canonicalOrder(_ lhs: MediaItem, _ rhs: MediaItem) -> Bool {
        switch (lhs.effectiveCaptureDate, rhs.effectiveCaptureDate) {
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

    private static func groupKey(for item: MediaItem, grouping: LibraryGrouping) -> String {
        switch grouping {
        case .trip:
            return "trip:\(item.tripID ?? "unassigned")"
        case .place:
            return "place:\(item.displayPlaceName ?? "")"
        case .type:
            return "type:\(typeKey(for: item))"
        case .month:
            guard let date = item.effectiveCaptureDate else { return "month:unknown" }
            return "month:\(monthFormatter.string(from: date))"
        }
    }

    private static func groupTitle(for item: MediaItem, grouping: LibraryGrouping) -> String {
        switch grouping {
        case .trip:
            return item.trip?.effectiveName ?? String(localized: "Unsorted")
        case .place:
            return item.displayPlaceName ?? String(localized: "No place")
        case .type:
            switch typeKey(for: item) {
            case "screenshot": return String(localized: "Screenshots")
            case MediaKind.video.rawValue: return String(localized: "Videos")
            case MediaKind.live.rawValue: return String(localized: "Live Photos")
            default: return String(localized: "Photos")
            }
        case .month:
            guard let date = item.effectiveCaptureDate else { return String(localized: "Undated") }
            return date.formatted(.dateTime.year().month(.wide))
        }
    }

    private static func typeKey(for item: MediaItem) -> String {
        item.isScreenshot ? "screenshot" : item.kind.rawValue
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()
}

/// State owned above the sidebar's detail switch so drafts, editing focus, and
/// the last scroll anchor survive while the user visits Places, Timeline, or
/// Footprints.
@MainActor
@Observable
final class LibraryViewState {
    var memoryDrafts: [String: String] = [:]
    /// Unsaved words on a photo's note line, by media ID.
    var noteDrafts: [String: String] = [:]
    /// Scroll ID of the section at the top of the Library, restored on return.
    var topSectionScrollID: String?
    var focusedMemoryItemID: String?
    /// The card a reveal request is waiting for; lazy grids build cards only
    /// near the viewport, so the final scroll happens when this card appears.
    var pendingRevealItemID: String?
    var appearedRevealItemID: String?

    func draft(for item: MediaItem) -> String {
        memoryDrafts[item.id] ?? item.latestMemory?.text ?? ""
    }

    func setDraft(_ text: String, for item: MediaItem) {
        memoryDrafts[item.id] = text
    }

    func clearDraft(for item: MediaItem) {
        memoryDrafts.removeValue(forKey: item.id)
    }
}

extension MediaItem {
    var latestMemory: Memory? {
        memories.max { lhs, rhs in
            lhs.updatedAt < rhs.updatedAt
        }
    }
}
