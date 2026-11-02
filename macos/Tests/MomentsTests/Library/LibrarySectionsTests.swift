import Foundation
import SwiftData
import XCTest
@testable import Moments

/// `LibraryFilterEngine.sections(forVisibleItems:by:sortOrder:)` now reads each
/// photo's id, date and title once into a cached entry and sorts those instead
/// of the models. These tests hold it to the old behaviour: the same sections,
/// titles, item order and date spans for every grouping and sort order,
/// including date ties and undated photos.
@MainActor
final class LibrarySectionsTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private let day: TimeInterval = 86_400

    /// Kept for the length of a test, so its main context stays valid.
    private var container: ModelContainer?

    private func makeContext() throws -> ModelContext {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        self.container = container
        return container.mainContext
    }

    // MARK: Fixture

    /// About 60 synthetic photos: three trips plus photos without one, two
    /// places plus photos without one, photos, videos, Live Photos and
    /// screenshots, dates over four months, several shared dates, several
    /// missing dates and one user-corrected date.
    private func makeItems(context: ModelContext) throws -> [MediaItem] {
        let trips: [Trip] = [
            Trip(id: "trip-north", name: "Synthetic north trip"),
            Trip(id: "trip-south", name: "Synthetic south trip"),
            Trip(id: "trip-island", name: "Synthetic island trip")
        ]
        let places: [Place] = [
            Place(id: "place-harbour", name: "Synthetic harbour"),
            Place(id: "place-hill", name: "Synthetic hill")
        ]
        trips.forEach(context.insert)
        places.forEach(context.insert)

        // Three shared dates make id ties; nil dates exercise undated photos.
        let sharedDates: [Date] = [
            base.addingTimeInterval(day * 10),
            base.addingTimeInterval(day * 40),
            base.addingTimeInterval(day * 100)
        ]
        var items: [MediaItem] = []
        items.reserveCapacity(60)

        for index in 0..<60 {
            let id: String = "photo-\(String(format: "%02d", index))"
            let kind: MediaKind
            switch index % 3 {
            case 0: kind = .photo
            case 1: kind = .video
            default: kind = .live
            }
            let isScreenshot: Bool = index % 10 == 7

            // Every 9th photo has no date at all.
            var date: Date?
            if index % 9 == 8 {
                date = nil
            } else if index % 7 == 3 {
                let sharedIndex: Int = (index / 7) % sharedDates.count
                date = sharedDates[sharedIndex]
            } else {
                // Four months of spread, in uneven steps so order is not the
                // array order.
                let offset: TimeInterval = day * Double((index * 17) % 120)
                date = base.addingTimeInterval(offset)
            }

            let trip: Trip? = index % 4 == 3 ? nil : trips[index % 3]
            let place: Place? = index % 5 == 4 ? nil : places[index % 2]
            let item = MediaItem(
                id: id,
                captureDate: date,
                kind: kind,
                isScreenshot: isScreenshot,
                place: place,
                trip: trip
            )
            context.insert(item)
            items.append(item)
        }

        // The one user-corrected date: its effective date moves far forward,
        // so sorting must use the correction rather than `captureDate`.
        let corrected: MediaItem = items[0]
        corrected.userCorrectedCaptureDateUTC = base.addingTimeInterval(day * 300)

        try context.save()
        return items
    }

    // MARK: Reference: the algorithm before the caching change

    /// The body of `LibraryFilterEngine.sections(forVisibleItems:by:sortOrder:)`
    /// before it cached each photo's id and date, with `groupKey`,
    /// `groupTitle`, `typeKey`, `canonicalOrder` and `monthFormatter` copied
    /// from `LibraryModel.swift`.
    private func referenceSections(
        _ visible: [MediaItem],
        by grouping: LibraryGrouping,
        sortOrder: LibrarySortOrder
    ) -> [LibrarySection] {
        var buckets: [String: (title: String, items: [MediaItem])] = [:]

        for item in visible {
            let key: String = referenceGroupKey(for: item, grouping: grouping)
            let title: String = referenceGroupTitle(for: item, grouping: grouping)
            buckets[key, default: (title: title, items: [])].items.append(item)
        }

        let sections: [LibrarySection] = buckets.map { key, bucket -> LibrarySection in
            let ordered: [MediaItem] = bucket.items.sorted(by: referenceCanonicalOrder)
            let allDates: [Date] = ordered.compactMap({ (item: MediaItem) -> Date? in
                item.effectiveCaptureDate
            })
            return LibrarySection(
                id: key,
                title: bucket.title,
                itemIDs: ordered.map({ (item: MediaItem) -> String in item.id }),
                startDate: allDates.min(),
                endDate: allDates.max()
            )
        }

        return sections.sorted { (lhs: LibrarySection, rhs: LibrarySection) -> Bool in
            let left: Date = sortOrder == .oldestFirst ? (lhs.startDate ?? .distantPast) : (lhs.endDate ?? .distantPast)
            let right: Date = sortOrder == .oldestFirst ? (rhs.startDate ?? .distantPast) : (rhs.endDate ?? .distantPast)
            if left != right { return sortOrder == .oldestFirst ? left < right : left > right }
            return lhs.id < rhs.id
        }
    }

    private func referenceCanonicalOrder(_ lhs: MediaItem, _ rhs: MediaItem) -> Bool {
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

    private func referenceGroupKey(for item: MediaItem, grouping: LibraryGrouping) -> String {
        switch grouping {
        case .trip:
            let tripID: String = item.tripID ?? "unassigned"
            return "trip:\(tripID)"
        case .place:
            let name: String = item.displayPlaceName ?? ""
            return "place:\(name)"
        case .type:
            return "type:\(referenceTypeKey(for: item))"
        case .month:
            guard let date: Date = item.effectiveCaptureDate else { return "month:unknown" }
            return "month:\(Self.referenceMonthFormatter.string(from: date))"
        }
    }

    private func referenceGroupTitle(for item: MediaItem, grouping: LibraryGrouping) -> String {
        switch grouping {
        case .trip:
            return item.trip?.effectiveName ?? String(localized: "Unsorted")
        case .place:
            return item.displayPlaceName ?? String(localized: "No place")
        case .type:
            switch referenceTypeKey(for: item) {
            case "screenshot": return String(localized: "Screenshots")
            case MediaKind.video.rawValue: return String(localized: "Videos")
            case MediaKind.live.rawValue: return String(localized: "Live Photos")
            default: return String(localized: "Photos")
            }
        case .month:
            guard let date: Date = item.effectiveCaptureDate else { return String(localized: "Undated") }
            return date.formatted(.dateTime.year().month(.wide))
        }
    }

    private func referenceTypeKey(for item: MediaItem) -> String {
        item.isScreenshot ? "screenshot" : item.kind.rawValue
    }

    private static let referenceMonthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()

    // MARK: Comparison

    private func assertSectionsMatchReference(
        _ visible: [MediaItem],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for grouping in LibraryGrouping.allCases {
            for sortOrder in LibrarySortOrder.allCases {
                let actual: [LibrarySection] = LibraryFilterEngine.sections(
                    forVisibleItems: visible,
                    by: grouping,
                    sortOrder: sortOrder
                )
                let expected: [LibrarySection] = referenceSections(
                    visible,
                    by: grouping,
                    sortOrder: sortOrder
                )
                let context: String = "grouping \(grouping.rawValue), order \(sortOrder.rawValue)"
                XCTAssertEqual(actual.count, expected.count, "count differs: \(context)", file: file, line: line)
                XCTAssertEqual(
                    actual.map({ (section: LibrarySection) -> String in section.id }),
                    expected.map({ (section: LibrarySection) -> String in section.id }),
                    "section ids or order differ: \(context)",
                    file: file,
                    line: line
                )
                for (actualSection, expectedSection) in zip(actual, expected) {
                    let label: String = "\(context), section \(expectedSection.id)"
                    XCTAssertEqual(actualSection.id, expectedSection.id, label, file: file, line: line)
                    XCTAssertEqual(actualSection.title, expectedSection.title, label, file: file, line: line)
                    XCTAssertEqual(actualSection.itemIDs, expectedSection.itemIDs, label, file: file, line: line)
                    XCTAssertEqual(actualSection.startDate, expectedSection.startDate, label, file: file, line: line)
                    XCTAssertEqual(actualSection.endDate, expectedSection.endDate, label, file: file, line: line)
                }
            }
        }
    }

    // MARK: Tests

    func testSectionsMatchTheReferenceForEveryGroupingAndOrder() throws {
        let context = try makeContext()
        let items: [MediaItem] = try makeItems(context: context)
        XCTAssertEqual(items.count, 60)
        // The fixture must actually exercise what it claims to.
        XCTAssertTrue(items.contains(where: { (item: MediaItem) -> Bool in item.trip == nil }))
        XCTAssertTrue(items.contains(where: { (item: MediaItem) -> Bool in item.place == nil }))
        XCTAssertTrue(items.contains(where: { (item: MediaItem) -> Bool in item.effectiveCaptureDate == nil }))
        XCTAssertTrue(items.contains(where: { (item: MediaItem) -> Bool in item.isScreenshot }))
        XCTAssertTrue(items.contains(where: { (item: MediaItem) -> Bool in item.kind == .video }))
        XCTAssertTrue(items.contains(where: { (item: MediaItem) -> Bool in item.userCorrectedCaptureDateUTC != nil }))

        assertSectionsMatchReference(items, file: #filePath, line: #line)
    }

    func testSectionsMatchTheReferenceForUnorderedAndReversedInput() throws {
        let context = try makeContext()
        let items: [MediaItem] = try makeItems(context: context)
        let reversed: [MediaItem] = Array(items.reversed())
        assertSectionsMatchReference(reversed, file: #filePath, line: #line)
    }

    /// Two photos in one section key but with different titles: one carries the
    /// trip id without the trip relationship ("Unsorted"), the other has the
    /// trip. The section keeps the title of the photo that comes first.
    func testSectionsKeepTheFirstPhotosTitle() throws {
        let context = try makeContext()
        let trip = Trip(id: "trip-shared", name: "Synthetic shared trip")
        context.insert(trip)
        let withoutTrip = MediaItem(
            id: "photo-title-a",
            captureDate: base,
            kind: .photo,
            tripID: "trip-shared"
        )
        let withTrip = MediaItem(
            id: "photo-title-b",
            captureDate: base.addingTimeInterval(day),
            kind: .photo,
            trip: trip
        )
        context.insert(withoutTrip)
        context.insert(withTrip)
        try context.save()

        XCTAssertEqual(withoutTrip.tripID, "trip-shared")
        XCTAssertNil(withoutTrip.trip)

        let withoutFirst: [LibrarySection] = LibraryFilterEngine.sections(
            forVisibleItems: [withoutTrip, withTrip],
            by: .trip,
            sortOrder: .oldestFirst
        )
        XCTAssertEqual(withoutFirst.count, 1)
        XCTAssertEqual(withoutFirst.first?.id, "trip:trip-shared")
        XCTAssertEqual(withoutFirst.first?.title, "Unsorted")
        XCTAssertEqual(withoutFirst.first?.itemIDs, ["photo-title-a", "photo-title-b"])

        let withFirst: [LibrarySection] = LibraryFilterEngine.sections(
            forVisibleItems: [withTrip, withoutTrip],
            by: .trip,
            sortOrder: .oldestFirst
        )
        XCTAssertEqual(withFirst.count, 1)
        XCTAssertEqual(withFirst.first?.id, "trip:trip-shared")
        XCTAssertEqual(withFirst.first?.title, "Synthetic shared trip")

        // Both photos in the same place: the first one's title stands, and the
        // item order is still by date, not by the given order.
        let place = Place(id: "place-title", name: "Synthetic title place")
        context.insert(place)
        let earlier = MediaItem(id: "photo-place-a", captureDate: base, kind: .photo, place: place)
        let later = MediaItem(
            id: "photo-place-b",
            captureDate: base.addingTimeInterval(day),
            kind: .photo,
            place: place
        )
        context.insert(earlier)
        context.insert(later)
        try context.save()

        let places: [LibrarySection] = LibraryFilterEngine.sections(
            forVisibleItems: [later, earlier],
            by: .place,
            sortOrder: .oldestFirst
        )
        XCTAssertEqual(places.count, 1)
        XCTAssertEqual(places.first?.title, "Synthetic title place")
        XCTAssertEqual(places.first?.itemIDs, ["photo-place-a", "photo-place-b"])
    }
}
