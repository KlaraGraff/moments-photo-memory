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
}

enum LibraryScreenshotFilter: String, CaseIterable, Sendable {
    case all
    case possibleOnly
}

struct LibraryPlaceOption: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

/// The filters that shape the Library before collections are grouped.
struct LibraryFilterCriteria: Equatable, Sendable {
    var fromDate: Date?
    var toDate: Date?
    var placeID: String?
    var mediaType: LibraryMediaTypeFilter
    var favoritesOnly: Bool
    var tripKey: String?
    var screenshotFilter: LibraryScreenshotFilter

    static let `default` = LibraryFilterCriteria(
        fromDate: nil,
        toDate: nil,
        placeID: nil,
        mediaType: .all,
        favoritesOnly: false,
        tripKey: nil,
        screenshotFilter: .all
    )
}

/// The app-layer mapping from SwiftData to the package's privacy-safe descriptor.
/// Explicit `true` is carried into the detector; `false` remains `nil` so a
/// heuristic can be presented as a possible screenshot without hiding the item.
enum MediaDescriptorMapper {
    static func descriptor(for item: MediaItem) -> MediaDescriptor {
        MediaDescriptor(
            id: item.id,
            captureDate: item.captureDate,
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

    static func filteredItems(_ items: [MediaItem], by criteria: LibraryFilterCriteria) -> [MediaItem] {
        let calendar = Calendar.current
        let from = criteria.fromDate.map(calendar.startOfDay(for:))
        let toExclusive = criteria.toDate.flatMap {
            calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0))
        }

        return items.filter { item in
            guard !item.isScreenshot else { return false }
            if criteria.screenshotFilter == .possibleOnly && !isPossibleScreenshot(item) { return false }
            if let from {
                guard let captureDate = item.captureDate, captureDate >= from else { return false }
            }
            if let toExclusive {
                guard let captureDate = item.captureDate, captureDate < toExclusive else { return false }
            }
            if let placeID = criteria.placeID {
                if placeID.hasPrefix("override:") {
                    let overrideName = String(placeID.dropFirst("override:".count))
                    if item.effectivePlaceName != overrideName { return false }
                } else if item.place?.id != placeID { return false }
            }
            if criteria.mediaType != .all, item.kind.rawValue != criteria.mediaType.rawValue { return false }
            if criteria.favoritesOnly && !item.isFavorite { return false }
            if let tripKey = criteria.tripKey, item.tripKey != tripKey { return false }
            return true
        }
    }

    static func groupedItems(
        _ items: [MediaItem],
        by criteria: LibraryFilterCriteria,
        sortOrder: LibrarySortOrder = .oldestFirst
    ) -> [MediaCollection] {
        let descriptors = filteredItems(items, by: criteria).map(MediaDescriptorMapper.descriptor(for:))
        let groups = CollectionGrouper().group(descriptors)
        return sortOrder == .oldestFirst ? groups : Array(groups.reversed())
    }
}

/// State owned above the sidebar's detail switch so drafts and the last scroll
/// anchor survive while the user visits Places, Timeline, or Footprints.
@MainActor
@Observable
final class LibraryViewState {
    var memoryDrafts: [String: String] = [:]
    var expandedCollectionIDs: Set<String> = []
    var initializedCollectionIDs: Set<String> = []
    var lastVisibleCollectionID: String?

    func draft(for item: MediaItem) -> String {
        memoryDrafts[item.id] ?? item.latestMemory?.text ?? ""
    }

    func setDraft(_ text: String, for item: MediaItem) {
        memoryDrafts[item.id] = text
    }

    func toggleExpanded(_ collectionID: String) {
        if expandedCollectionIDs.contains(collectionID) {
            expandedCollectionIDs.remove(collectionID)
        } else {
            expandedCollectionIDs.insert(collectionID)
        }
    }
}

extension MediaItem {
    var latestMemory: Memory? {
        memories.max { lhs, rhs in
            lhs.updatedAt < rhs.updatedAt
        }
    }
}

struct LibraryCollection: Identifiable {
    let core: MediaCollection
    let itemsByID: [String: MediaItem]

    var id: String { core.id }
    var items: [MediaItem] { core.itemIDs.compactMap { itemsByID[$0] } }
    var cover: MediaItem? { itemsByID[core.coverID] }
    var count: Int { core.count }
}
