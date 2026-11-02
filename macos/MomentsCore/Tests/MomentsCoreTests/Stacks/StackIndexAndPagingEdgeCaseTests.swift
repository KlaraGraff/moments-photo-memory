import Foundation
import XCTest
@testable import MomentsCore

final class StackIndexAndPagingEdgeCaseTests: XCTestCase {
    private func stack(_ id: String, _ members: [String], cover: String, chosen: Bool = false) -> PhotoStack {
        PhotoStack(id: id, memberIDs: members, coverID: cover, isCoverChosen: chosen)
    }

    // MARK: - 1

    func testEmptyIndexCollapsesEveryIDToAnOrdinaryEntry() {
        XCTAssertTrue(PhotoStackIndex.empty.isEmpty)
        let entries = PhotoStackIndex.empty.collapse(["a", "b", "c"])
        XCTAssertEqual(entries, [
            StackedEntry(id: "a", stackID: nil, count: 1),
            StackedEntry(id: "b", stackID: nil, count: 1),
            StackedEntry(id: "c", stackID: nil, count: 1),
        ])
        XCTAssertTrue(entries.allSatisfy { !$0.isStack })
        XCTAssertEqual(PhotoStackIndex.empty.collapse([]), [])
    }

    // MARK: - 2

    func testCollapseShowsTheCoverWhereTheFirstVisiblePhotoSitsOrThatPhotoWhenTheCoverIsNotInTheOrder() {
        let index = PhotoStackIndex([
            stack("s1", ["a", "b", "c"], cover: "c"),
            stack("s2", ["d", "e", "f"], cover: "f"),
        ])

        // Both covers are in the order, so each entry sits at the first member
        // of its stack and shows the cover.
        let withCovers = index.collapse(["f", "d", "b", "a", "c", "e"])
        XCTAssertEqual(withCovers, [
            StackedEntry(id: "f", stackID: "s2", count: 3),
            StackedEntry(id: "c", stackID: "s1", count: 3),
        ])

        // Neither cover is in the order, so each entry shows the photo of its
        // stack that comes first in the order.
        let withoutCovers = index.collapse(["e", "x", "b", "a", "d"])
        XCTAssertEqual(withoutCovers, [
            StackedEntry(id: "e", stackID: "s2", count: 2),
            StackedEntry(id: "x", stackID: nil, count: 1),
            StackedEntry(id: "b", stackID: "s1", count: 2),
        ])
    }

    // MARK: - 3

    func testAStackWithOnlyOnePhotoInTheOrderIsAnOrdinaryEntry() {
        let index = PhotoStackIndex([stack("s", ["a", "b"], cover: "b")])
        let entries = index.collapse(["a", "x"])
        XCTAssertEqual(entries, [
            StackedEntry(id: "a", stackID: nil, count: 1),
            StackedEntry(id: "x", stackID: nil, count: 1),
        ])
        XCTAssertFalse(entries[0].isStack)
        XCTAssertNil(entries[0].stackID)
        XCTAssertEqual(entries[0].count, 1)
    }

    // MARK: - 4

    func testExpandPutsEveryMemberInPlaceAndNeverRepeatsAnID() {
        let index = PhotoStackIndex([
            stack("s1", ["a", "b"], cover: "a"),
            stack("s2", ["c", "d"], cover: "d"),
        ])
        XCTAssertEqual(index.expand(["x", "a", "y", "c"]), ["x", "a", "b", "y", "c", "d"])
        // The second occurrence of a member stands for nothing new, and ids
        // that are in no stack are kept as they are.
        XCTAssertEqual(index.expand(["a", "b", "x", "a"]), ["a", "b", "x"])
        XCTAssertEqual(index.expand([]), [])
    }

    func testExpandingACollapsedOrderListsEveryVisibleStackPhotoOnce() {
        let index = PhotoStackIndex([stack("s", ["a", "b", "c"], cover: "b")])
        // "c" and "a" are in view; "b" is not.
        let entries = index.collapse(["x", "c", "a", "y"])
        XCTAssertEqual(entries, [
            StackedEntry(id: "x", stackID: nil, count: 1),
            StackedEntry(id: "c", stackID: "s", count: 2),
            StackedEntry(id: "y", stackID: nil, count: 1),
        ])
        let expanded = index.expand(entries.map(\.id))
        XCTAssertEqual(expanded, ["x", "a", "b", "c", "y"])
        XCTAssertEqual(Set(expanded).count, expanded.count)
    }

    // MARK: - 5

    func testStackContainingFindsTheStackForAnyMemberAndNilForOtherIDs() {
        let index = PhotoStackIndex([
            stack("s1", ["a", "b"], cover: "a"),
            stack("s2", ["c", "d"], cover: "d"),
        ])
        XCTAssertEqual(index.stack(containing: "a")?.id, "s1")
        XCTAssertEqual(index.stack(containing: "b")?.id, "s1")
        XCTAssertEqual(index.stack(containing: "c")?.id, "s2")
        XCTAssertEqual(index.stack(containing: "d")?.id, "s2")
        XCTAssertNil(index.stack(containing: "e"))
        XCTAssertNil(index.stack(containing: ""))
        XCTAssertNil(PhotoStackIndex.empty.stack(containing: "a"))
    }

    // MARK: - 6

    func testPageOfIsTheSamePageForEveryShotOfAStack() {
        let stacks = PhotoStackIndex([stack("s", ["a", "b", "c"], cover: "c")])
        // Newest first, as a screen hands it over.
        let paging = StackPaging(order: ["c", "b", "a", "x"], stacks: stacks)
        XCTAssertEqual(paging.pages, [StackedEntry(id: "c", stackID: "s", count: 3),
                                      StackedEntry(id: "x", stackID: nil, count: 1)])
        XCTAssertEqual(paging.page(of: "a"), 0)
        XCTAssertEqual(paging.page(of: "b"), 0)
        XCTAssertEqual(paging.page(of: "c"), 0)
        XCTAssertEqual(paging.page(of: "x"), 1)
        XCTAssertNil(paging.page(of: "unknown"))
    }

    func testShotsOfListsTheVisibleShotsOldestFirstAndIsEmptyForASinglePhoto() {
        let stacks = PhotoStackIndex([stack("s", ["a", "b", "c", "d"], cover: "a")])
        // The order is newest first and a filter left out "c".
        let paging = StackPaging(order: ["d", "b", "a", "x"], stacks: stacks)
        XCTAssertEqual(paging.shots(of: "b"), ["a", "b", "d"])
        XCTAssertEqual(paging.shots(of: "a"), ["a", "b", "d"])
        XCTAssertEqual(paging.shots(of: "d"), ["a", "b", "d"])
        XCTAssertTrue(paging.shots(of: "x").isEmpty)
        XCTAssertTrue(paging.shots(of: "unknown").isEmpty)
        XCTAssertTrue(StackPaging.empty.shots(of: "a").isEmpty)
    }

    // MARK: - 7

    func testNeighbourWalksInsideAStackThenAcrossPages() {
        let stacks = PhotoStackIndex([
            stack("s1", ["a", "b", "c"], cover: "a"),
            stack("s2", ["p", "q"], cover: "q"),
        ])
        // Pages: "z", "a" (stack s1), "y", "q" (stack s2).
        let paging = StackPaging(order: ["z", "c", "b", "a", "y", "q", "p"], stacks: stacks)
        XCTAssertEqual(paging.pages.map(\.id), ["z", "a", "y", "q"])

        // Inside the stack first.
        XCTAssertEqual(paging.neighbour(of: "a", offset: 1), "b")
        XCTAssertEqual(paging.neighbour(of: "a", offset: 2), "c")
        XCTAssertEqual(paging.neighbour(of: "c", offset: -1), "b")
        XCTAssertEqual(paging.neighbour(of: "c", offset: -2), "a")
        // Then the next page.
        XCTAssertEqual(paging.neighbour(of: "c", offset: 1), "y")
        XCTAssertEqual(paging.neighbour(of: "b", offset: -1), "a")

        // Entering a stack from the left gives its first shot, from the right
        // its last shot (both oldest first in the stack's own order).
        XCTAssertEqual(paging.neighbour(of: "y", offset: 1), "p")
        XCTAssertEqual(paging.neighbour(of: "y", offset: -1), "c")
        // Offsets move whole pages, not shot by shot.
        XCTAssertEqual(paging.neighbour(of: "z", offset: 2), "y")
        XCTAssertEqual(paging.neighbour(of: "q", offset: -2), "c")

        // Past either end and for an unknown id.
        XCTAssertNil(paging.neighbour(of: "z", offset: -1))
        XCTAssertNil(paging.neighbour(of: "q", offset: 1))
        XCTAssertEqual(paging.neighbour(of: "a", offset: -1), "z")
        XCTAssertNil(paging.neighbour(of: "unknown", offset: 1))
        XCTAssertNil(paging.neighbour(of: "unknown", offset: -1))
        XCTAssertNil(StackPaging.empty.neighbour(of: "a", offset: 1))
    }
}
