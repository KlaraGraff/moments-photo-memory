import Foundation
import SwiftData
import XCTest
@testable import Moments

/// The Chapters build key is the one number the page and, later, an
/// app-level pre-builder both use to find a finished build. A fetch from a
/// second `ModelContext` may return the same rows in another order, so the
/// key must not depend on that order; changing what a row says must still
/// change the key.
@MainActor
final class ChaptersBuildKeyTests: XCTestCase {
    private let base: Date = Date(timeIntervalSince1970: 1_700_000_000)

    /// Kept for the length of a test, so its main context stays valid.
    private var container: ModelContainer?

    /// An in-memory store, so nothing here touches the real library.
    private func makeContext() throws -> ModelContext {
        let container: ModelContainer = try MomentsPersistence.makeContainer(inMemory: true)
        self.container = container
        return container.mainContext
    }

    private func makeStore(context: ModelContext) -> LibraryStore {
        let store: LibraryStore = LibraryStore()
        store.start(context: context)
        return store
    }

    /// Three synthetic photos in one synthetic trip, three memories, two
    /// chapter groups and two memberships: the rows the key hashes.
    private func makeRows(
        context: ModelContext
    ) throws -> (trips: [Trip], memories: [Memory], chapterGroups: [UserGroup], groupItems: [UserGroupItem]) {
        let trip: Trip = Trip(id: "trip-b", name: "Synthetic Harbour")
        context.insert(trip)
        for index in 0..<3 {
            let photo: MediaItem = MediaItem(
                id: "photo-\(index)",
                captureDate: base.addingTimeInterval(Double(index)),
                latitude: 0.001,
                longitude: 0.002,
                title: "Synthetic photo \(index)"
            )
            context.insert(photo)
            photo.trip = trip
            let memory: Memory = Memory(
                id: "memory-\(index)",
                text: "Synthetic memory \(index)",
                createdAt: base.addingTimeInterval(Double(index)),
                updatedAt: base.addingTimeInterval(Double(index)),
                mediaItem: photo
            )
            context.insert(memory)
        }
        let secondTrip: Trip = Trip(id: "trip-a", name: "Synthetic Hills")
        context.insert(secondTrip)
        let firstGroup: UserGroup = UserGroup(id: "group-a", name: "Synthetic Birthday", kind: .chapter)
        let secondGroup: UserGroup = UserGroup(id: "group-b", name: "Synthetic Reunion", kind: .chapter)
        context.insert(firstGroup)
        context.insert(secondGroup)
        let firstMember: UserGroupItem = UserGroupItem(id: "member-a", groupID: "group-a", mediaID: "photo-0")
        let secondMember: UserGroupItem = UserGroupItem(id: "member-b", groupID: "group-a", mediaID: "photo-1")
        context.insert(firstMember)
        context.insert(secondMember)
        try context.save()

        let trips: [Trip] = try context.fetch(FetchDescriptor<Trip>())
        let memories: [Memory] = try context.fetch(FetchDescriptor<Memory>())
        let chapterGroups: [UserGroup] = try context.fetch(
            FetchDescriptor<UserGroup>(predicate: #Predicate { $0.kindRaw == "chapter" })
        )
        let groupItems: [UserGroupItem] = try context.fetch(FetchDescriptor<UserGroupItem>())
        XCTAssertEqual(trips.count, 2)
        XCTAssertEqual(memories.count, 3)
        XCTAssertEqual(chapterGroups.count, 2)
        XCTAssertEqual(groupItems.count, 2)
        return (trips: trips, memories: memories, chapterGroups: chapterGroups, groupItems: groupItems)
    }

    private var calendar: Calendar {
        var calendar: Calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func key(
        store: LibraryStore,
        memories: [Memory],
        trips: [Trip],
        chapterGroups: [UserGroup],
        groupItems: [UserGroupItem]
    ) -> Int {
        TripsScreen.buildKey(
            store: store,
            memories: memories,
            trips: trips,
            chapterGroups: chapterGroups,
            groupItems: groupItems,
            calendar: calendar
        )
    }

    /// A fetch from another `ModelContext` may hand the same rows over in
    /// another order; the key must stay the same.
    func testTheSameRowsInReversedOrderGiveTheSameKey() throws {
        let context: ModelContext = try makeContext()
        let store: LibraryStore = makeStore(context: context)
        let rows: (trips: [Trip], memories: [Memory], chapterGroups: [UserGroup], groupItems: [UserGroupItem]) = try makeRows(context: context)

        let forward: Int = key(
            store: store,
            memories: rows.memories,
            trips: rows.trips,
            chapterGroups: rows.chapterGroups,
            groupItems: rows.groupItems
        )
        let reversedMemories: [Memory] = Array(rows.memories.reversed())
        let reversedTrips: [Trip] = Array(rows.trips.reversed())
        let reversedGroups: [UserGroup] = Array(rows.chapterGroups.reversed())
        let reversedMembers: [UserGroupItem] = Array(rows.groupItems.reversed())
        let reversed: Int = key(
            store: store,
            memories: reversedMemories,
            trips: reversedTrips,
            chapterGroups: reversedGroups,
            groupItems: reversedMembers
        )

        XCTAssertEqual(forward, reversed)
        XCTAssertNotEqual(reversedMemories.first?.id, rows.memories.first?.id)
        XCTAssertNotEqual(reversedTrips.first?.id, rows.trips.first?.id)
        XCTAssertNotEqual(reversedGroups.first?.id, rows.chapterGroups.first?.id)
        XCTAssertNotEqual(reversedMembers.first?.id, rows.groupItems.first?.id)
    }

    /// A renamed trip shows another name on the page, so it must rebuild.
    func testRenamingATripChangesTheKey() throws {
        let context: ModelContext = try makeContext()
        let store: LibraryStore = makeStore(context: context)
        let rows: (trips: [Trip], memories: [Memory], chapterGroups: [UserGroup], groupItems: [UserGroupItem]) = try makeRows(context: context)

        let before: Int = key(
            store: store,
            memories: rows.memories,
            trips: rows.trips,
            chapterGroups: rows.chapterGroups,
            groupItems: rows.groupItems
        )
        let trip: Trip = try XCTUnwrap(rows.trips.first { (candidate: Trip) -> Bool in candidate.id == "trip-b" })
        trip.overrideName = "Synthetic Harbour, renamed"
        try context.save()
        let after: Int = key(
            store: store,
            memories: rows.memories,
            trips: rows.trips,
            chapterGroups: rows.chapterGroups,
            groupItems: rows.groupItems
        )

        XCTAssertEqual(trip.effectiveName, "Synthetic Harbour, renamed")
        XCTAssertNotEqual(before, after)
    }

    /// A memory's words appear on the page, so an edit must rebuild. Every
    /// edit path also moves `updatedAt` (the field the key hashes), exactly
    /// as the app's save does here.
    func testChangingAMemoryTextChangesTheKey() throws {
        let context: ModelContext = try makeContext()
        let store: LibraryStore = makeStore(context: context)
        let rows: (trips: [Trip], memories: [Memory], chapterGroups: [UserGroup], groupItems: [UserGroupItem]) = try makeRows(context: context)

        let before: Int = key(
            store: store,
            memories: rows.memories,
            trips: rows.trips,
            chapterGroups: rows.chapterGroups,
            groupItems: rows.groupItems
        )
        let memory: Memory = try XCTUnwrap(rows.memories.first { (candidate: Memory) -> Bool in candidate.id == "memory-1" })
        memory.text = "Synthetic memory, edited"
        memory.updatedAt = base.addingTimeInterval(3_600)
        try context.save()
        let after: Int = key(
            store: store,
            memories: rows.memories,
            trips: rows.trips,
            chapterGroups: rows.chapterGroups,
            groupItems: rows.groupItems
        )

        XCTAssertEqual(memory.text, "Synthetic memory, edited")
        XCTAssertNotEqual(before, after)
    }

    /// A membership taken out of a chapter changes which photos it shows, so
    /// flipping `excluded` must rebuild.
    func testFlippingOneMembershipsExcludedChangesTheKey() throws {
        let context: ModelContext = try makeContext()
        let store: LibraryStore = makeStore(context: context)
        let rows: (trips: [Trip], memories: [Memory], chapterGroups: [UserGroup], groupItems: [UserGroupItem]) = try makeRows(context: context)

        let before: Int = key(
            store: store,
            memories: rows.memories,
            trips: rows.trips,
            chapterGroups: rows.chapterGroups,
            groupItems: rows.groupItems
        )
        let membership: UserGroupItem = try XCTUnwrap(
            rows.groupItems.first { (candidate: UserGroupItem) -> Bool in candidate.id == "member-b" }
        )
        membership.excluded = true
        try context.save()
        let after: Int = key(
            store: store,
            memories: rows.memories,
            trips: rows.trips,
            chapterGroups: rows.chapterGroups,
            groupItems: rows.groupItems
        )

        XCTAssertTrue(membership.excluded)
        XCTAssertNotEqual(before, after)
    }
}
