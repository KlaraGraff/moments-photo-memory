import Foundation
import XCTest
@testable import MomentsCore

final class CollectionGrouperEdgeCaseTests: XCTestCase {
    private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    func testItemsExactlyNinetySecondsApartGroupAndNinetyPointFiveSecondsApartDoNot() {
        let items = [
            item("a", at: 0),
            item("b", at: 90),
            item("c", at: 180.5)
        ]

        let collections = CollectionGrouper().group(items)

        XCTAssertEqual(collections.map(\.itemIDs), [["a", "b"], ["c"]])
    }

    func testAnItemWithoutACaptureDateIsItsOwnGroupAfterAllDatedItems() {
        let items = [
            item("undated-b", at: nil),
            item("dated-2", at: 10),
            item("undated-a", at: nil),
            item("dated-1", at: 0)
        ]

        let collections = CollectionGrouper().group(items)

        XCTAssertEqual(collections.map(\.itemIDs), [["dated-1", "dated-2"], ["undated-a"], ["undated-b"]])
    }

    func testAFeaturePrintFarFromEveryPrintInTheGroupStartsANewGroup() {
        let items = [
            item("a", at: 0, featurePrint: [1, 0, 0]),
            item("b", at: 10, featurePrint: [1, 0, 0]),
            item("c", at: 20, featurePrint: [0, 1, 0])
        ]

        let collections = CollectionGrouper().group(items)

        XCTAssertEqual(collections.map(\.itemIDs), [["a", "b"], ["c"]])
    }

    func testAnItemWithoutAFeaturePrintIsCompatibleWithEveryPrint() {
        let items = [
            item("printed-a", at: 0, featurePrint: [1, 0, 0]),
            item("unprinted", at: 10),
            item("printed-b", at: 20, featurePrint: [0, 1, 0]),
            item("unprinted-2", at: 30)
        ]

        let collections = CollectionGrouper().group(items)

        XCTAssertEqual(collections.map(\.itemIDs), [["printed-a", "unprinted"], ["printed-b", "unprinted-2"]])
    }

    func testFeaturePrintsOfDifferentLengthsAreIncompatible() {
        let items = [
            item("three-values", at: 0, featurePrint: [1, 0, 0]),
            item("two-values", at: 10, featurePrint: [1, 0])
        ]

        let collections = CollectionGrouper().group(items)

        XCTAssertEqual(collections.map(\.itemIDs), [["three-values"], ["two-values"]])
    }

    func testAnAllZeroFeaturePrintIsIncompatible() {
        let zero: [Float] = [0, 0]
        let allZero = CollectionGrouper().group([
            item("zero-a", at: 0, featurePrint: zero),
            item("zero-b", at: 10, featurePrint: zero)
        ])
        XCTAssertEqual(allZero.map(\.itemIDs), [["zero-a"], ["zero-b"]])

        let zeroAgainstNonZero = CollectionGrouper().group([
            item("zero", at: 0, featurePrint: zero),
            item("non-zero", at: 10, featurePrint: [1, 0])
        ])
        XCTAssertEqual(zeroAgainstNonZero.map(\.itemIDs), [["zero"], ["non-zero"]])
    }

    func testCoverUsesMostPixelsThenEarliestDateThenSmallestID() {
        let mostPixels = CollectionGrouper().group([
            item("small", at: 0, width: 1_000, height: 1_000),
            item("large", at: 30, width: 2_000, height: 2_000)
        ])
        XCTAssertEqual(mostPixels.first?.cover.id, "large")

        let earliest = CollectionGrouper().group([
            item("later", at: 20, width: 1_600, height: 1_600),
            item("earlier", at: 10, width: 1_600, height: 1_600)
        ])
        XCTAssertEqual(earliest.first?.cover.id, "earlier")

        let smallestID = CollectionGrouper().group([
            item("b", at: 0, width: 1_600, height: 1_600),
            item("a", at: 0, width: 1_600, height: 1_600)
        ])
        XCTAssertEqual(smallestID.first?.cover.id, "a")
    }

    func testCollectionIDIsOrderIndependentAndHasSixteenLowercaseHexDigits() {
        let items = [
            item("b", at: 10),
            item("a", at: 0),
            item("c", at: 20)
        ]

        let original = CollectionGrouper().group(items)
        let reordered = CollectionGrouper().group(items.reversed())

        XCTAssertEqual(original.map(\.id), reordered.map(\.id))
        let id = original.first?.id ?? ""
        XCTAssertTrue(id.hasPrefix("collection-"))
        let suffix = String(id.dropFirst("collection-".count))
        XCTAssertEqual(suffix.count, 16)
        XCTAssertEqual(suffix, suffix.lowercased())
        XCTAssertTrue(suffix.allSatisfy { $0.isHexDigit })
    }

    func testCollectionPropertiesReflectTheItemsAndCover() {
        let collections = CollectionGrouper().group([
            item("first", at: 0, width: 1_000, height: 1_000),
            item("second", at: 10, width: 2_000, height: 2_000),
            item("alone", at: 500, width: 1_000, height: 1_000)
        ])

        XCTAssertEqual(collections.count, 2)
        XCTAssertEqual(collections[0].itemIDs, ["first", "second"])
        XCTAssertEqual(collections[0].coverID, "second")
        XCTAssertEqual(collections[0].count, 2)
        XCTAssertFalse(collections[0].isSingleton)
        XCTAssertEqual(collections[1].itemIDs, ["alone"])
        XCTAssertEqual(collections[1].coverID, "alone")
        XCTAssertEqual(collections[1].count, 1)
        XCTAssertTrue(collections[1].isSingleton)
    }

    func testGroupVisibleLeavesOutEveryItemTheScreenshotDetectorFlags() {
        let items = [
            item("photo-a", at: 0, width: 2_000, height: 1_500),
            item("explicit", at: 1, width: 2_000, height: 1_500, isScreenshotFlag: true),
            item("named", at: 2, width: 2_000, height: 1_500, fileNameHint: "Screenshot 1.png"),
            item("sized", at: 3, width: 1_170, height: 2_532),
            item("photo-b", at: 4, width: 2_000, height: 1_500)
        ]

        let collections = CollectionGrouper().groupVisible(items)

        XCTAssertEqual(collections.map(\.itemIDs), [["photo-a", "photo-b"]])
    }

    func testANegativeBurstIntervalIsClampedToZeroSoOnlyEqualDatesGroup() {
        let grouper = CollectionGrouper(burstInterval: -30)
        XCTAssertEqual(grouper.burstInterval, 0)

        let items = [
            item("same-a", at: 0),
            item("same-b", at: 0),
            item("later", at: 0.5)
        ]

        let collections = grouper.group(items)

        XCTAssertEqual(collections.map(\.itemIDs), [["same-a", "same-b"], ["later"]])
    }

    // MARK: - Helpers

    private func item(
        _ id: String,
        at offset: TimeInterval? = 0,
        width: Int = 1_000,
        height: Int = 1_000,
        isScreenshotFlag: Bool? = nil,
        fileNameHint: String? = nil,
        featurePrint: [Float]? = nil
    ) -> MediaDescriptor {
        MediaDescriptor(
            id: id,
            captureDate: offset.map { baseDate.addingTimeInterval($0) },
            pixelWidth: width,
            pixelHeight: height,
            isScreenshotFlag: isScreenshotFlag,
            fileNameHint: fileNameHint,
            featurePrint: featurePrint
        )
    }
}
