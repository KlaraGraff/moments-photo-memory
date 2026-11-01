import Foundation
import SwiftData
import XCTest
@testable import Moments

@MainActor
final class LibrarySectionMemoriesTests: XCTestCase {
    private func section(_ id: String, itemIDs: [String]) -> LibrarySection {
        LibrarySection(id: id, title: id, itemIDs: itemIDs, startDate: nil, endDate: nil)
    }

    /// A memory model, never inserted: `make` only reads it.
    private func memory(
        _ id: String,
        scope: NoteMemoryScope,
        scopeKey: String,
        text: String,
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> CollectionMemory {
        CollectionMemory(id: id, scope: scope, scopeKey: scopeKey, text: text, createdAt: createdAt)
    }

    // MARK: 1

    func testTripSectionGetsOnlyItsTripsMemory() {
        let mine = memory("memory-1", scope: .trip, scopeKey: "trip-1", text: "Synthetic trip memory")
        let other = memory("memory-2", scope: .trip, scopeKey: "trip-2", text: "Synthetic other memory")
        let sections: [LibrarySection] = [
            section("trip:trip-1", itemIDs: ["photo-1"]),
            section("trip:trip-2", itemIDs: ["photo-2"]),
        ]
        let dayKeysBySection: [String: Set<String>] = [
            "trip:trip-1": ["2023-11-14"],
            "trip:trip-2": ["2023-11-14"],
        ]

        let result: [String: [CollectionMemory]] = LibrarySectionMemories.make(
            sections: sections,
            dayKeysBySection: dayKeysBySection,
            memories: [mine, other]
        )

        XCTAssertEqual(result["trip:trip-1"]?.map(\.id), ["memory-1"])
        XCTAssertEqual(result["trip:trip-2"]?.map(\.id), ["memory-2"])
        XCTAssertEqual(result.count, 2)
    }

    // MARK: 2

    func testDaySectionGetsDayAndPhotoMemoriesOfItsDaysOnly() {
        let dayMemory = memory("memory-1", scope: .day, scopeKey: "2023-11-14", text: "Synthetic day memory")
        let photoMemory = memory("memory-2", scope: .photo, scopeKey: "2023-11-15", text: "Synthetic photo memory")
        let anotherDay = memory("memory-3", scope: .day, scopeKey: "2023-11-16", text: "Synthetic other day")
        let anotherTrip = memory("memory-4", scope: .trip, scopeKey: "trip-1", text: "Synthetic trip memory")
        let sections: [LibrarySection] = [section("month:2023-11", itemIDs: ["photo-1", "photo-2"])]
        let dayKeysBySection: [String: Set<String>] = ["month:2023-11": ["2023-11-14", "2023-11-15"]]

        let result: [String: [CollectionMemory]] = LibrarySectionMemories.make(
            sections: sections,
            dayKeysBySection: dayKeysBySection,
            memories: [dayMemory, photoMemory, anotherDay, anotherTrip]
        )

        XCTAssertEqual(result["month:2023-11"]?.map(\.id), ["memory-1", "memory-2"])
        XCTAssertEqual(result.count, 1)
    }

    // MARK: 3

    func testOrderFollowsTheMemoriesItWasGiven() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // Given oldest created first, but the input order is what counts.
        let firstMemory = memory("memory-1", scope: .day, scopeKey: "2023-11-14", text: "Synthetic first",
                                 createdAt: base.addingTimeInterval(30))
        let secondMemory = memory("memory-2", scope: .day, scopeKey: "2023-11-14", text: "Synthetic second",
                                  createdAt: base.addingTimeInterval(10))
        let thirdMemory = memory("memory-3", scope: .photo, scopeKey: "2023-11-14", text: "Synthetic third",
                                 createdAt: base.addingTimeInterval(20))
        let sections: [LibrarySection] = [section("month:2023-11", itemIDs: ["photo-1"])]
        let dayKeysBySection: [String: Set<String>] = ["month:2023-11": ["2023-11-14"]]

        let result: [String: [CollectionMemory]] = LibrarySectionMemories.make(
            sections: sections,
            dayKeysBySection: dayKeysBySection,
            memories: [firstMemory, secondMemory, thirdMemory]
        )

        XCTAssertEqual(result["month:2023-11"]?.map(\.id), ["memory-1", "memory-2", "memory-3"])
    }

    // MARK: 4

    func testNoMemoriesGivesNoKeys() {
        let sections: [LibrarySection] = [section("month:2023-11", itemIDs: ["photo-1"])]
        let dayKeysBySection: [String: Set<String>] = ["month:2023-11": ["2023-11-14"]]

        let empty: [String: [CollectionMemory]] = LibrarySectionMemories.make(
            sections: sections,
            dayKeysBySection: dayKeysBySection,
            memories: []
        )

        XCTAssertTrue(empty.isEmpty)
    }

    func testSectionWithNoMatchHasNoKey() {
        let memory = self.memory("memory-1", scope: .day, scopeKey: "2023-11-14", text: "Synthetic day memory")
        let sections: [LibrarySection] = [
            section("month:2023-11", itemIDs: ["photo-1"]),
            section("month:2023-12", itemIDs: ["photo-2"]),
        ]
        let dayKeysBySection: [String: Set<String>] = [
            "month:2023-11": ["2023-11-14"],
            "month:2023-12": ["2023-12-02"],
        ]

        let result: [String: [CollectionMemory]] = LibrarySectionMemories.make(
            sections: sections,
            dayKeysBySection: dayKeysBySection,
            memories: [memory]
        )

        XCTAssertEqual(result["month:2023-11"]?.map(\.id), ["memory-1"])
        XCTAssertNil(result["month:2023-12"])
        XCTAssertEqual(result.count, 1)
    }

    // MARK: 5

    /// The page assigns a fresh match only when `sameIDs` says it differs, so
    /// an unchanged match must not look different: a second match over the same
    /// sections and memories, and a match whose memories are new objects with
    /// the same ids, both compare equal. A changed day-key set, an added memory
    /// or a different order per section must compare unequal.
    func testSameIDsComparesTheMemoryIDsPerSection() {
        let dayMemory = memory("memory-1", scope: .day, scopeKey: "2023-11-14", text: "Synthetic day memory")
        let photoMemory = memory("memory-2", scope: .photo, scopeKey: "2023-11-15", text: "Synthetic photo memory")
        let sections: [LibrarySection] = [
            section("month:2023-11", itemIDs: ["photo-1", "photo-2"]),
            section("month:2023-12", itemIDs: ["photo-3"]),
        ]
        let dayKeysBySection: [String: Set<String>] = [
            "month:2023-11": ["2023-11-14", "2023-11-15"],
            "month:2023-12": ["2023-12-02"],
        ]
        let first: [String: [CollectionMemory]] = LibrarySectionMemories.make(
            sections: sections,
            dayKeysBySection: dayKeysBySection,
            memories: [dayMemory, photoMemory]
        )
        XCTAssertEqual(first["month:2023-11"]?.map(\.id), ["memory-1", "memory-2"])
        XCTAssertEqual(first.count, 1)
        let matchedAgain: [String: [CollectionMemory]] = LibrarySectionMemories.make(
            sections: sections,
            dayKeysBySection: dayKeysBySection,
            memories: [dayMemory, photoMemory]
        )
        XCTAssertTrue(LibrarySectionMemories.sameIDs(first, matchedAgain))

        let sameIDsOtherObjects: [String: [CollectionMemory]] = [
            "month:2023-11": [
                memory("memory-1", scope: .day, scopeKey: "2023-11-14", text: "Synthetic rewritten text"),
                memory("memory-2", scope: .photo, scopeKey: "2023-11-15", text: "Synthetic rewritten text"),
            ]
        ]
        XCTAssertTrue(LibrarySectionMemories.sameIDs(first, sameIDsOtherObjects))

        // One of the section's days no longer matches the photo memory.
        let dayKeysWithoutMatch: [String: Set<String>] = [
            "month:2023-11": ["2023-11-14"],
            "month:2023-12": ["2023-12-02"],
        ]
        let fewerMemories: [String: [CollectionMemory]] = LibrarySectionMemories.make(
            sections: sections,
            dayKeysBySection: dayKeysWithoutMatch,
            memories: [dayMemory, photoMemory]
        )
        XCTAssertEqual(fewerMemories["month:2023-11"]?.map(\.id), ["memory-1"])
        XCTAssertFalse(LibrarySectionMemories.sameIDs(first, fewerMemories))

        // A memory added to a section.
        let withExtraMemory: [String: [CollectionMemory]] = [
            "month:2023-11": [dayMemory, photoMemory, memory("memory-3", scope: .day, scopeKey: "2023-11-14", text: "Synthetic extra")],
        ]
        XCTAssertFalse(LibrarySectionMemories.sameIDs(first, withExtraMemory))

        // The same memories in a different order.
        let reversed: [String: [CollectionMemory]] = ["month:2023-11": [photoMemory, dayMemory]]
        XCTAssertFalse(LibrarySectionMemories.sameIDs(first, reversed))

        // Empty against empty is the common first build.
        let empty: [String: [CollectionMemory]] = [:]
        XCTAssertTrue(LibrarySectionMemories.sameIDs(empty, empty))
        XCTAssertFalse(LibrarySectionMemories.sameIDs(empty, first))
    }
}
