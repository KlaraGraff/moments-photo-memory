import Foundation
import SwiftData
import XCTest
@testable import Moments

/// The Timeline's build key is the one number the page and, later, an
/// app-level pre-builder both use to find a finished build. A fetch from a
/// second `ModelContext` may return the same rows in another order, so the
/// key must not depend on that order; changing what a row says must still
/// change the key.
@MainActor
final class TimelineBuildKeyTests: XCTestCase {
    private let base: Date = Date(timeIntervalSince1970: 1_700_000_000)

    /// An in-memory store, so nothing here touches the real library.
    private func makeContext() throws -> ModelContext {
        let container: ModelContainer = try MomentsPersistence.makeContainer(inMemory: true)
        self.container = container
        return container.mainContext
    }

    /// Kept for the length of a test, so its main context stays valid.
    private var container: ModelContainer?

    private func makeStore(context: ModelContext) -> LibraryStore {
        let store: LibraryStore = LibraryStore()
        store.start(context: context)
        return store
    }

    private func makeStacks() -> PhotoStackModel {
        PhotoStackModel(analysis: PhotoStackAnalysisStore(fileURL: nil))
    }

    /// Three synthetic photos in one synthetic trip, three memories and two
    /// stack records: the rows the key hashes.
    private func makeRows(context: ModelContext) throws -> (trips: [Trip], memories: [Memory], stackRecords: [UserGroup]) {
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
        let firstStack: UserGroup = UserGroup(id: "stack-a", name: "Stack A", kind: .stack)
        let secondStack: UserGroup = UserGroup(id: "stack-b", name: "Stack B", kind: .stack)
        context.insert(firstStack)
        context.insert(secondStack)
        try context.save()

        let trips: [Trip] = try context.fetch(FetchDescriptor<Trip>())
        let memories: [Memory] = try context.fetch(FetchDescriptor<Memory>())
        let stackRecords: [UserGroup] = try context.fetch(FetchDescriptor<UserGroup>(predicate: #Predicate { $0.kindRaw == "stack" }))
        XCTAssertEqual(trips.count, 2)
        XCTAssertEqual(memories.count, 3)
        XCTAssertEqual(stackRecords.count, 2)
        return (trips: trips, memories: memories, stackRecords: stackRecords)
    }

    private func key(
        store: LibraryStore,
        selection: SelectionModel,
        memories: [Memory],
        trips: [Trip],
        stacks: PhotoStackModel,
        stackRecords: [UserGroup]
    ) -> Int {
        TimelineScreen.buildKey(
            store: store,
            selection: selection,
            memories: memories,
            trips: trips,
            stacks: stacks,
            stackRecords: stackRecords,
            calendar: Calendar(identifier: .gregorian)
        )
    }

    /// A fetch from another `ModelContext` may hand the same rows over in
    /// another order; the key must stay the same.
    func testTheSameRowsInAnotherOrderGiveTheSameKey() throws {
        let context: ModelContext = try makeContext()
        let store: LibraryStore = makeStore(context: context)
        let selection: SelectionModel = SelectionModel()
        let stacks: PhotoStackModel = makeStacks()
        let rows: (trips: [Trip], memories: [Memory], stackRecords: [UserGroup]) = try makeRows(context: context)

        let forward: Int = key(
            store: store,
            selection: selection,
            memories: rows.memories,
            trips: rows.trips,
            stacks: stacks,
            stackRecords: rows.stackRecords
        )
        let reversedMemories: [Memory] = rows.memories.reversed()
        let reversedTrips: [Trip] = rows.trips.reversed()
        let reversedStacks: [UserGroup] = rows.stackRecords.reversed()
        let reversed: Int = key(
            store: store,
            selection: selection,
            memories: reversedMemories,
            trips: reversedTrips,
            stacks: stacks,
            stackRecords: reversedStacks
        )

        XCTAssertEqual(forward, reversed)
        XCTAssertNotEqual(reversedMemories.first?.id, rows.memories.first?.id)
        XCTAssertNotEqual(reversedTrips.first?.id, rows.trips.first?.id)
    }

    /// A renamed trip shows another name on the page, so it must rebuild.
    func testRenamingATripChangesTheKey() throws {
        let context: ModelContext = try makeContext()
        let store: LibraryStore = makeStore(context: context)
        let selection: SelectionModel = SelectionModel()
        let stacks: PhotoStackModel = makeStacks()
        let rows: (trips: [Trip], memories: [Memory], stackRecords: [UserGroup]) = try makeRows(context: context)

        let before: Int = key(
            store: store,
            selection: selection,
            memories: rows.memories,
            trips: rows.trips,
            stacks: stacks,
            stackRecords: rows.stackRecords
        )
        let trip: Trip = try XCTUnwrap(rows.trips.first { (candidate: Trip) -> Bool in candidate.id == "trip-b" })
        trip.overrideName = "Synthetic Harbour, renamed"
        try context.save()
        let after: Int = key(
            store: store,
            selection: selection,
            memories: rows.memories,
            trips: rows.trips,
            stacks: stacks,
            stackRecords: rows.stackRecords
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
        let selection: SelectionModel = SelectionModel()
        let stacks: PhotoStackModel = makeStacks()
        let rows: (trips: [Trip], memories: [Memory], stackRecords: [UserGroup]) = try makeRows(context: context)

        let before: Int = key(
            store: store,
            selection: selection,
            memories: rows.memories,
            trips: rows.trips,
            stacks: stacks,
            stackRecords: rows.stackRecords
        )
        let memory: Memory = try XCTUnwrap(rows.memories.first { (candidate: Memory) -> Bool in candidate.id == "memory-1" })
        memory.text = "Synthetic memory, edited"
        memory.updatedAt = base.addingTimeInterval(3_600)
        try context.save()
        let after: Int = key(
            store: store,
            selection: selection,
            memories: rows.memories,
            trips: rows.trips,
            stacks: stacks,
            stackRecords: rows.stackRecords
        )

        XCTAssertEqual(memory.text, "Synthetic memory, edited")
        XCTAssertNotEqual(before, after)
    }

    /// The key never reads the row order it was handed, so the same rows in
    /// another order keep the same key even when only one array is shuffled.
    func testEachArrayIsOrderIndependent() throws {
        let context: ModelContext = try makeContext()
        let store: LibraryStore = makeStore(context: context)
        let selection: SelectionModel = SelectionModel()
        let stacks: PhotoStackModel = makeStacks()
        let rows: (trips: [Trip], memories: [Memory], stackRecords: [UserGroup]) = try makeRows(context: context)

        let baseline: Int = key(
            store: store,
            selection: selection,
            memories: rows.memories,
            trips: rows.trips,
            stacks: stacks,
            stackRecords: rows.stackRecords
        )
        let shuffledMemories: [Memory] = [rows.memories[2], rows.memories[0], rows.memories[1]]
        let onlyMemories: Int = key(
            store: store,
            selection: selection,
            memories: shuffledMemories,
            trips: rows.trips,
            stacks: stacks,
            stackRecords: rows.stackRecords
        )
        XCTAssertEqual(baseline, onlyMemories)

        let shuffledTrips: [Trip] = [rows.trips[1], rows.trips[0]]
        let onlyTrips: Int = key(
            store: store,
            selection: selection,
            memories: rows.memories,
            trips: shuffledTrips,
            stacks: stacks,
            stackRecords: rows.stackRecords
        )
        XCTAssertEqual(baseline, onlyTrips)

        let shuffledStacks: [UserGroup] = [rows.stackRecords[1], rows.stackRecords[0]]
        let onlyStacks: Int = key(
            store: store,
            selection: selection,
            memories: rows.memories,
            trips: rows.trips,
            stacks: stacks,
            stackRecords: shuffledStacks
        )
        XCTAssertEqual(baseline, onlyStacks)
    }
}
