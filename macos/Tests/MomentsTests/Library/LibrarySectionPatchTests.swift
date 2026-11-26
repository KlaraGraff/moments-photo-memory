import Foundation
import MomentsCore
import SwiftData
import XCTest
@testable import Moments

/// `LibrarySectionPatch` must give exactly what a full rebuild gives: the same
/// sections, titles, order, photo order and date spans, folded the same way.
@MainActor
final class LibrarySectionPatchTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private let day: TimeInterval = 86_400

    /// Kept for the length of a test, so its main context stays valid.
    private var container: ModelContainer?

    private struct Fixture {
        let context: ModelContext
        let items: [MediaItem]
        let trips: [Trip]
    }

    /// 80 synthetic photos over five months, a third of them in one of three
    /// trips, with shared dates (id ties) and a few undated photos.
    private func makeFixture() throws -> Fixture {
        let container: ModelContainer = try MomentsPersistence.makeContainer(inMemory: true)
        self.container = container
        let context: ModelContext = container.mainContext
        let trips: [Trip] = [
            Trip(id: "trip-north", name: "Synthetic north trip"),
            Trip(id: "trip-south", name: "Synthetic south trip"),
            Trip(id: "trip-island", name: "Synthetic island trip")
        ]
        trips.forEach(context.insert)
        var items: [MediaItem] = []
        for index in 0..<80 {
            let id: String = "photo-\(String(format: "%02d", index))"
            var date: Date?
            if index % 13 == 12 {
                date = nil
            } else if index % 7 == 3 {
                date = base.addingTimeInterval(day * 20)
            } else {
                let offset: TimeInterval = day * Double((index * 23) % 150)
                date = base.addingTimeInterval(offset)
            }
            let trip: Trip? = index % 3 == 0 ? trips[index % 9 / 3] : nil
            let item: MediaItem = MediaItem(id: id, captureDate: date, trip: trip)
            context.insert(item)
            items.append(item)
        }
        try context.save()
        return Fixture(context: context, items: items, trips: trips)
    }

    /// The order the Library hands its photos to the sections: the store's.
    private func storeOrder(_ items: [MediaItem]) -> [MediaItem] {
        items.sorted { (lhs: MediaItem, rhs: MediaItem) -> Bool in
            let left: Date = lhs.captureDate ?? .distantPast
            let right: Date = rhs.captureDate ?? .distantPast
            if left != right { return left < right }
            return lhs.id < rhs.id
        }
    }

    /// Groupings whose sections move when a photo's date or trip moves.
    /// `.story` is what the Library shows; the other two are its halves.
    private let groupings: [LibraryGrouping] = [.story, .trip, .month]

    private func full(
        _ items: [MediaItem],
        by grouping: LibraryGrouping = .trip,
        sortOrder: LibrarySortOrder = .newestFirst
    ) -> [LibrarySection] {
        LibraryFilterEngine.sections(forVisibleItems: storeOrder(items), by: grouping, sortOrder: sortOrder)
    }

    private func byID(_ items: [MediaItem]) -> [String: MediaItem] {
        var result: [String: MediaItem] = [:]
        for item in items { result[item.id] = item }
        return result
    }

    /// Runs `change` once and checks the patch against a full rebuild for
    /// every grouping in `groupings`, from sections built before the change.
    private func assertPatchMatchesFull(
        _ fixture: Fixture,
        sortOrder: LibrarySortOrder = .newestFirst,
        change: () -> Set<String>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var before: [LibraryGrouping: [LibrarySection]] = [:]
        for grouping in groupings {
            before[grouping] = full(fixture.items, by: grouping, sortOrder: sortOrder)
        }
        let changed: Set<String> = change()
        let items: [String: MediaItem] = byID(fixture.items)
        for grouping in groupings {
            let old: [LibrarySection] = before[grouping] ?? []
            let expected: [LibrarySection] = full(fixture.items, by: grouping, sortOrder: sortOrder)
            let patched: (sections: [LibrarySection], affectedIDs: Set<String>)? = LibrarySectionPatch.sections(
                old,
                itemByID: items,
                changedIDs: changed,
                grouping: grouping,
                sortOrder: sortOrder
            )
            guard let result = patched else {
                XCTFail("the patch gave up for \(grouping)", file: file, line: line)
                continue
            }
            XCTAssertEqual(result.sections, expected, "grouping \(grouping)", file: file, line: line)
        }
    }

    func testNoChangeKeepsTheSections() throws {
        let fixture: Fixture = try makeFixture()
        try assertPatchMatchesFull(fixture) { () -> Set<String> in [] }
    }

    func testDateMovedWithinItsMonth() throws {
        let fixture: Fixture = try makeFixture()
        try assertPatchMatchesFull(fixture) { () -> Set<String> in
            let item: MediaItem = fixture.items[1]
            item.captureDate = item.captureDate?.addingTimeInterval(3_600)
            return [item.id]
        }
    }

    func testDateMovedToAnotherMonthAndToAnEmptyMonth() throws {
        let fixture: Fixture = try makeFixture()
        try assertPatchMatchesFull(fixture) { () -> Set<String> in
            let moved: MediaItem = fixture.items[2]
            moved.captureDate = base.addingTimeInterval(day * 75)
            // A month no photo had: a new section.
            let alone: MediaItem = fixture.items[4]
            alone.captureDate = base.addingTimeInterval(day * 400)
            return [moved.id, alone.id]
        }
    }

    func testLastPhotoLeavesItsMonth() throws {
        let fixture: Fixture = try makeFixture()
        try assertPatchMatchesFull(fixture) { () -> Set<String> in
            let alone: MediaItem = fixture.items[4]
            alone.captureDate = base.addingTimeInterval(day * 400)
            return [alone.id]
        }
        // The month it made is emptied again: that section goes.
        try assertPatchMatchesFull(fixture) { () -> Set<String> in
            let back: MediaItem = fixture.items[4]
            back.captureDate = base.addingTimeInterval(day * 5)
            return [back.id]
        }
    }

    func testPhotosJoinAndLeaveTrips() throws {
        let fixture: Fixture = try makeFixture()
        try assertPatchMatchesFull(fixture) { () -> Set<String> in
            let joins: MediaItem = fixture.items[1]
            joins.trip = fixture.trips[2]
            joins.tripID = fixture.trips[2].id
            let leaves: MediaItem = fixture.items[0]
            leaves.trip = nil
            leaves.tripID = nil
            return [joins.id, leaves.id]
        }
    }

    func testDateTiesUndatedAndCorrectedDates() throws {
        let fixture: Fixture = try makeFixture()
        try assertPatchMatchesFull(fixture) { () -> Set<String> in
            // Onto the shared date, so the id breaks the tie.
            let tie: MediaItem = fixture.items[5]
            tie.captureDate = base.addingTimeInterval(day * 20)
            let undated: MediaItem = fixture.items[7]
            undated.captureDate = nil
            let dated: MediaItem = fixture.items[12]
            dated.captureDate = base.addingTimeInterval(day * 33)
            let corrected: MediaItem = fixture.items[8]
            corrected.userCorrectedCaptureDateUTC = base.addingTimeInterval(day * 140)
            return [tie.id, undated.id, dated.id, corrected.id]
        }
    }

    func testOldestFirst() throws {
        let fixture: Fixture = try makeFixture()
        try assertPatchMatchesFull(fixture, sortOrder: .oldestFirst) { () -> Set<String> in
            let moved: MediaItem = fixture.items[10]
            moved.captureDate = base.addingTimeInterval(-day * 30)
            let joins: MediaItem = fixture.items[11]
            joins.trip = fixture.trips[0]
            joins.tripID = fixture.trips[0].id
            return [moved.id, joins.id]
        }
    }

    func testRandomChangesMatchAFullRebuild() throws {
        let fixture: Fixture = try makeFixture()
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ bound: Int) -> Int {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Int(state % UInt64(bound))
        }
        for _ in 0..<40 {
            try assertPatchMatchesFull(fixture) { () -> Set<String> in
                var changed = Set<String>()
                let count: Int = 1 + next(6)
                for _ in 0..<count {
                    let item: MediaItem = fixture.items[next(fixture.items.count)]
                    switch next(4) {
                    case 0:
                        item.captureDate = base.addingTimeInterval(day * Double(next(200)))
                    case 1:
                        let trip: Trip = fixture.trips[next(fixture.trips.count)]
                        item.trip = trip
                        item.tripID = trip.id
                    case 2:
                        item.trip = nil
                        item.tripID = nil
                    default:
                        item.captureDate = nil
                    }
                    changed.insert(item.id)
                }
                return changed
            }
        }
    }

    func testUnknownPhotoGivesUp() throws {
        let fixture: Fixture = try makeFixture()
        let old: [LibrarySection] = full(fixture.items)
        let patched: (sections: [LibrarySection], affectedIDs: Set<String>)? = LibrarySectionPatch.sections(
            old,
            itemByID: byID(fixture.items),
            changedIDs: ["photo-not-shown"],
            grouping: .trip,
            sortOrder: .newestFirst
        )
        XCTAssertNil(patched)
    }

    func testFoldingMatchesAFullFold() throws {
        let fixture: Fixture = try makeFixture()
        let oldUnfolded: [LibrarySection] = full(fixture.items, by: .month)
        // Two bursts of synthetic photos that share a section today.
        let roomy: [LibrarySection] = oldUnfolded.filter { (section: LibrarySection) -> Bool in section.count >= 3 }
        XCTAssertGreaterThanOrEqual(roomy.count, 2, "the fixture needs two sections of three photos")
        let first: [String] = Array(roomy[0].itemIDs.prefix(3))
        let second: [String] = Array(roomy[1].itemIDs.prefix(2))
        let index: PhotoStackIndex = PhotoStackIndex([
            PhotoStack(id: "stack-a", memberIDs: first, coverID: first[0], isCoverChosen: false),
            PhotoStack(id: "stack-b", memberIDs: second, coverID: second[0], isCoverChosen: false)
        ])
        let oldFolded = LibraryFilterEngine.folding(oldUnfolded, with: index)

        // One burst photo moves to another month.
        let moved: MediaItem = try XCTUnwrap(fixture.items.first { (item: MediaItem) -> Bool in item.id == first[1] })
        moved.captureDate = base.addingTimeInterval(day * 400)
        let patchedOrNil: (sections: [LibrarySection], affectedIDs: Set<String>)? = LibrarySectionPatch.sections(
            oldUnfolded,
            itemByID: byID(fixture.items),
            changedIDs: [moved.id],
            grouping: .month,
            sortOrder: .newestFirst
        )
        let patched: (sections: [LibrarySection], affectedIDs: Set<String>) = try XCTUnwrap(patchedOrNil)
        let folded = LibrarySectionPatch.folding(
            unfolded: patched.sections,
            oldFolded: oldFolded.sections,
            oldStackCounts: oldFolded.stackCounts,
            affectedIDs: patched.affectedIDs,
            with: index
        )
        let expected = LibraryFilterEngine.folding(full(fixture.items, by: .month), with: index)
        XCTAssertEqual(folded.sections, expected.sections)
        XCTAssertEqual(folded.stackCounts, expected.stackCounts)
    }
}
