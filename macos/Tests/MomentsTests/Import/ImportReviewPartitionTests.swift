import XCTest
@testable import Moments

final class ImportReviewPartitionTests: XCTestCase {
    private let flags = [
        ImportReviewFlag(id: "synthetic-a", fileName: "synthetic-a.jpg", reasons: [.missingLocation]),
        ImportReviewFlag(id: "synthetic-b", fileName: "synthetic-b.jpg", reasons: [.needsDate]),
        ImportReviewFlag(id: "synthetic-c", fileName: "synthetic-c.jpg", reasons: [.nearDuplicate])
    ]

    func testAcceptMovesFlagToHandledAndUpdatesCounts() {
        let partition = partitionImportReviewFlags(flags, decisionOverrides: ["synthetic-a": .accepted])

        XCTAssertEqual(partition.pending.map(\.id), ["synthetic-b", "synthetic-c"])
        XCTAssertEqual(partition.handled.map(\.id), ["synthetic-a"])
        XCTAssertEqual(partition.pending.count, 2)
        XCTAssertEqual(partition.handled.count, 1)
    }

    func testUndoReturnsFlagToPending() {
        let handled = partitionImportReviewFlags(flags, decisionOverrides: ["synthetic-a": .accepted])
        XCTAssertEqual(handled.handled.count, 1)

        let undone = partitionImportReviewFlags(flags, decisionOverrides: ["synthetic-a": .pending])

        XCTAssertEqual(undone.pending.map(\.id), ["synthetic-a", "synthetic-b", "synthetic-c"])
        XCTAssertEqual(undone.pending.count, 3)
        XCTAssertEqual(undone.handled.count, 0)
        XCTAssertTrue(undone.handled.isEmpty)
    }

    func testExistingHandledDecisionIsPartitionedWithoutOverrides() {
        let alreadyIgnored = ImportReviewFlag(
            id: "synthetic-a",
            fileName: "synthetic-a.jpg",
            reasons: [.missingLocation],
            decision: .ignored
        )

        let partition = partitionImportReviewFlags([alreadyIgnored, flags[1]])

        XCTAssertEqual(partition.pending.count, 1)
        XCTAssertEqual(partition.handled.count, 1)
    }

    func testChangedDecisionIsHandledAndKeepsItOutOfPendingCount() {
        let changed = ImportReviewFlag(
            id: "synthetic-a",
            fileName: "synthetic-a.jpg",
            reasons: [.missingLocation],
            decision: .changed
        )

        let partition = partitionImportReviewFlags([changed, flags[1]])

        XCTAssertEqual(partition.pending.map(\.id), ["synthetic-b"])
        XCTAssertEqual(partition.handled.map(\.id), ["synthetic-a"])
    }

    func testAcceptPreservesTypedPlaceAndSavesTheTypedValue() {
        XCTAssertEqual(
            ImportReviewDecisionLogic.placeAction(
                suggestedPlaceName: "Suggested place",
                typedPlaceName: " My place ",
                existingOverrideName: nil,
                existingReviewOverridePlaceID: nil
            ),
            .set("My place")
        )
    }

    func testAcceptDoesNotReplaceAnExistingPersonalPlaceOverride() {
        XCTAssertEqual(
            ImportReviewDecisionLogic.placeAction(
                suggestedPlaceName: "Suggested place",
                typedPlaceName: nil,
                existingOverrideName: "My place",
                existingReviewOverridePlaceID: nil
            ),
            .preserve
        )
    }

    func testAcceptCanRefreshItsOwnPreviousSuggestion() {
        XCTAssertEqual(
            ImportReviewDecisionLogic.placeAction(
                suggestedPlaceName: "New suggestion",
                typedPlaceName: nil,
                existingOverrideName: "Old suggestion",
                existingReviewOverridePlaceID: "Old suggestion"
            ),
            .set("New suggestion")
        )
    }

    /// The To review list and its sidebar badge drop a photo once it is handled.
    func testHandledItemNoLongerNeedsReview() {
        let item = MediaItem(id: "synthetic-review")
        item.importReviewReasonsRaw = ImportReviewReason.missingLocation.rawValue
        XCTAssertTrue(item.needsImportReview)

        item.importDecision = .accepted
        XCTAssertFalse(item.needsImportReview)

        item.importDecision = .pending
        XCTAssertTrue(item.needsImportReview)

        item.importReviewReasonsRaw = nil
        XCTAssertFalse(item.needsImportReview)
    }
}
