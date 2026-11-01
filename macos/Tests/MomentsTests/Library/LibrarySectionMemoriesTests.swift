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
}
