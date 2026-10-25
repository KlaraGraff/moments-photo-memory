import Foundation
import XCTest
@testable import MomentsCore

final class CollectionGrouperTests: XCTestCase {
    private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    func testEightItemBurstProducesOneCollectionAndPicksLargestCover() {
        let items = (0..<8).map { index in
            MediaDescriptor(
                id: "burst-\(index)",
                captureDate: baseDate.addingTimeInterval(Double(index) * 5),
                pixelWidth: index == 4 ? 4_000 : 1_600,
                pixelHeight: index == 4 ? 3_000 : 1_000
            )
        }

        let collections = CollectionGrouper().group(items)

        XCTAssertEqual(collections.count, 1)
        XCTAssertEqual(collections[0].items.count, 8)
        XCTAssertEqual(collections[0].cover.id, "burst-4")
    }

    func testCoverTieUsesEarliestCaptureDate() {
        let items = [
            MediaDescriptor(id: "later", captureDate: baseDate.addingTimeInterval(4), pixelWidth: 2_000, pixelHeight: 2_000),
            MediaDescriptor(id: "earlier", captureDate: baseDate, pixelWidth: 2_000, pixelHeight: 2_000)
        ]

        XCTAssertEqual(CollectionGrouper().group(items).first?.cover.id, "earlier")
    }

    func testDissimilarFeaturePrintsSplitScenesEvenWhenTenSecondsApart() {
        let first = MediaDescriptor(
            id: "scene-a",
            captureDate: baseDate,
            pixelWidth: 2_000,
            pixelHeight: 1_500,
            featurePrint: [1, 0, 0]
        )
        let second = MediaDescriptor(
            id: "scene-b",
            captureDate: baseDate.addingTimeInterval(10),
            pixelWidth: 2_000,
            pixelHeight: 1_500,
            featurePrint: [0, 1, 0]
        )

        let collections = CollectionGrouper().group([second, first])

        XCTAssertEqual(collections.count, 2)
        XCTAssertEqual(collections.map(\.items.first?.id), ["scene-a", "scene-b"])
    }

    func testScreenshotDetectorUsesExplicitFlagBeforeHeuristicsAndExplainsDecision() {
        let forcedPhoto = MediaDescriptor(
            id: "flagged-photo",
            captureDate: baseDate,
            pixelWidth: 1_170,
            pixelHeight: 2_532,
            isScreenshotFlag: false,
            fileNameHint: "Screenshot 2024-01-01.png"
        )
        let namedScreenshot = MediaDescriptor(
            id: "named-screenshot",
            pixelWidth: 4_032,
            pixelHeight: 3_024,
            fileNameHint: "Screenshot 2024-01-01.png"
        )
        let sizedScreenshot = MediaDescriptor(
            id: "sized-screenshot",
            pixelWidth: 1_170,
            pixelHeight: 2_532
        )
        let ordinaryPhoto = MediaDescriptor(
            id: "ordinary-photo",
            pixelWidth: 4_032,
            pixelHeight: 3_024,
            fileNameHint: "IMG_1234.JPG"
        )

        let detector = ScreenshotDetector()
        let forcedResult = detector.detect(forcedPhoto)
        let namedResult = detector.detect(namedScreenshot)
        let sizedResult = detector.detect(sizedScreenshot)
        let ordinaryResult = detector.detect(ordinaryPhoto)

        XCTAssertFalse(forcedResult.isScreenshot)
        XCTAssertEqual(forcedResult.reason, .explicitFlag)
        XCTAssertTrue(namedResult.isScreenshot)
        XCTAssertEqual(namedResult.reason, .filenameHint)
        XCTAssertTrue(sizedResult.isScreenshot)
        XCTAssertEqual(sizedResult.reason, .deviceScreenPixelSize)
        XCTAssertFalse(ordinaryResult.isScreenshot)
        XCTAssertEqual(ordinaryResult.reason, .notDetected)
        XCTAssertFalse(namedResult.reasonText.isEmpty)
    }

    func testCollectionIDsAndOrderingAreStableAfterReorderingInput() {
        let items = [
            MediaDescriptor(id: "b", captureDate: baseDate.addingTimeInterval(2), pixelWidth: 1_000, pixelHeight: 1_000),
            MediaDescriptor(id: "a", captureDate: baseDate, pixelWidth: 1_000, pixelHeight: 1_000),
            MediaDescriptor(id: "c", captureDate: baseDate.addingTimeInterval(4), pixelWidth: 1_000, pixelHeight: 1_000),
            MediaDescriptor(id: "d", captureDate: baseDate.addingTimeInterval(300), pixelWidth: 1_000, pixelHeight: 1_000)
        ]

        let grouper = CollectionGrouper()
        let original = grouper.group(items)
        let reordered = grouper.group(items.reversed())

        XCTAssertEqual(original.map(\.id), reordered.map(\.id))
        XCTAssertEqual(original.map(\.itemIDs), reordered.map(\.itemIDs))
        XCTAssertEqual(original.map(\.cover.id), reordered.map(\.cover.id))
    }

    func testEmptyInputProducesNoCollectionsAndUndatedItemsStaySingle() {
        let grouper = CollectionGrouper()
        XCTAssertTrue(grouper.group([]).isEmpty)

        let undated = [
            MediaDescriptor(id: "a", pixelWidth: 100, pixelHeight: 100),
            MediaDescriptor(id: "b", pixelWidth: 100, pixelHeight: 100)
        ]
        XCTAssertEqual(grouper.group(undated).map(\.items.count), [1, 1])
    }

    func testVisibleGroupingFiltersScreenshotsBeforeGrouping() {
        let detector = ScreenshotDetector()
        let items = [
            MediaDescriptor(id: "photo", captureDate: baseDate, pixelWidth: 2_000, pixelHeight: 1_500),
            MediaDescriptor(id: "screen", captureDate: baseDate.addingTimeInterval(1), pixelWidth: 1_170, pixelHeight: 2_532)
        ]

        let collections = CollectionGrouper().groupVisible(items, using: detector)

        XCTAssertEqual(collections.flatMap(\.itemIDs), ["photo"])
    }
}
