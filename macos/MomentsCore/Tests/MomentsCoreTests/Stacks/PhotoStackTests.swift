import Foundation
import XCTest
@testable import MomentsCore

final class PhotoStackTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func photo(_ id: String, _ seconds: Double, hash: UInt64? = 0, print: [Float]? = nil, quality: StackQuality? = nil) -> StackPhoto {
        StackPhoto(id: id, captureDate: base.addingTimeInterval(seconds), perceptualHash: hash, featurePrint: print, quality: quality)
    }

    func testRepeatedShutterTapsBecomeOneStack() {
        let photos = [photo("a", 0), photo("b", 1.2), photo("c", 2.5), photo("d", 4), photo("e", 30)]
        let index = PhotoStackDetector().detect(photos)
        XCTAssertEqual(index.stacks.count, 1)
        XCTAssertEqual(index.stack(containing: "c")?.memberIDs, ["a", "b", "c", "d"])
        XCTAssertNil(index.stack(containing: "e"))
    }

    func testDifferentScenesShotQuicklyStayApart() {
        let photos = [
            photo("street", 0, hash: 0x0000_0000_0000_0000),
            photo("street-2", 1, hash: 0x0000_0000_0000_000F),
            photo("menu", 2, hash: 0xFFFF_FFFF_FFFF_FFF0),
        ]
        let index = PhotoStackDetector().detect(photos)
        XCTAssertEqual(index.stack(containing: "street")?.memberIDs, ["street", "street-2"])
        XCTAssertNil(index.stack(containing: "menu"))
    }

    func testFeaturePrintsWinOverHashes() {
        let photos = [
            photo("a", 0, hash: 0, print: [1, 0, 0]),
            // Same hash, but Vision sees a different picture.
            photo("b", 1, hash: 0, print: [0, 1, 0]),
        ]
        XCTAssertTrue(PhotoStackDetector().detect(photos).isEmpty)
    }

    func testPhotosWithoutAnySimilarityMeasureNeverStack() {
        let photos = [photo("a", 0, hash: nil), photo("b", 1, hash: nil)]
        XCTAssertTrue(PhotoStackDetector().detect(photos).isEmpty)
    }

    func testLongGapOrLongSpanEndsAStack() {
        let gap = [photo("a", 0), photo("b", 6)]
        XCTAssertTrue(PhotoStackDetector().detect(gap).isEmpty)
        let span = (0..<20).map { photo("p\($0)", Double($0) * 4) }
        let index = PhotoStackDetector().detect(span)
        XCTAssertEqual(index.stacks.values.map(\.count).sorted(), [4, 16])
    }

    func testUndatedPhotosNeverStack() {
        let photos = [StackPhoto(id: "a", captureDate: nil, perceptualHash: 0), StackPhoto(id: "b", captureDate: nil, perceptualHash: 0)]
        XCTAssertTrue(PhotoStackDetector().detect(photos).isEmpty)
    }

    func testBestCoverPrefersOpenEyesAndClearFaces() {
        let photos = [
            photo("blink", 0, quality: StackQuality(sharpness: 900, faceCount: 1, faceQuality: 0.7, eyesOpen: 0)),
            photo("good", 1, quality: StackQuality(sharpness: 600, faceCount: 1, faceQuality: 0.8, eyesOpen: 1)),
            photo("blurry", 2, quality: StackQuality(sharpness: 50, faceCount: 1, faceQuality: 0.3, eyesOpen: 1)),
        ]
        XCTAssertEqual(PhotoStackDetector().detect(photos).stack(containing: "good")?.coverID, "good")
    }

    func testBestCoverWithoutFacesIsTheSharpest() {
        let photos = [
            photo("a", 0, quality: StackQuality(sharpness: 100)),
            photo("b", 1, quality: StackQuality(sharpness: 400)),
            photo("c", 2, quality: StackQuality(sharpness: 200)),
        ]
        XCTAssertEqual(PhotoStackDetector().detect(photos).stack(containing: "a")?.coverID, "b")
    }

    func testBestCoverWithoutMeasurementsIsTheFirstShot() {
        let photos = [photo("b", 1), photo("a", 0)]
        let stack = PhotoStackDetector().detect(photos).stack(containing: "a")
        XCTAssertEqual(stack?.coverID, "a")
        XCTAssertEqual(stack?.isCoverChosen, false)
    }

    func testChosenCoverIsKept() {
        let photos = [photo("a", 0), photo("b", 1), photo("c", 2)]
        let decision = StackDecision(id: "stack-a", memberIDs: ["a", "b", "c"], coverID: "c")
        let stack = PhotoStackDetector().detect(photos, decisions: [decision]).stack(containing: "a")
        XCTAssertEqual(stack?.id, "stack-a")
        XCTAssertEqual(stack?.coverID, "c")
        XCTAssertEqual(stack?.isCoverChosen, true)
    }

    func testUnstackedPhotosShowOneByOneAndAreNotStackedAgain() {
        let photos = [photo("a", 0), photo("b", 1), photo("c", 2)]
        let decision = StackDecision(id: "stack-a", memberIDs: ["a", "b", "c"], isUnstacked: true)
        XCTAssertTrue(PhotoStackDetector().detect(photos, decisions: [decision]).isEmpty)
    }

    func testRemovedPhotoStaysOnItsOwn() {
        let photos = [photo("a", 0), photo("b", 1), photo("c", 2)]
        let decision = StackDecision(id: "stack-a", memberIDs: ["a", "c"], coverID: "a", removedIDs: ["b"])
        let index = PhotoStackDetector().detect(photos, decisions: [decision])
        XCTAssertEqual(index.stack(containing: "a")?.memberIDs, ["a", "c"])
        XCTAssertNil(index.stack(containing: "b"))
    }

    func testCoverRemovedFromStackFallsBackToBestPick() {
        let photos = [photo("a", 0), photo("b", 1), photo("c", 2)]
        let decision = StackDecision(id: "stack-a", memberIDs: ["a", "c"], coverID: "b", removedIDs: ["b"])
        let stack = PhotoStackDetector().detect(photos, decisions: [decision]).stack(containing: "c")
        XCTAssertEqual(stack?.coverID, "a")
        XCTAssertEqual(stack?.isCoverChosen, false)
    }

    func testNewPhotosNextToAChosenStackDoNotJoinIt() {
        let photos = [photo("a", 0), photo("b", 1), photo("new", 2)]
        let decision = StackDecision(id: "stack-a", memberIDs: ["a", "b"], coverID: "b")
        let index = PhotoStackDetector().detect(photos, decisions: [decision])
        XCTAssertEqual(index.stack(containing: "a")?.memberIDs, ["a", "b"])
        XCTAssertNil(index.stack(containing: "new"))
    }

    func testCollapseShowsTheCoverWhereTheStackFirstAppears() {
        let index = PhotoStackIndex([PhotoStack(id: "s", memberIDs: ["a", "b", "c"], coverID: "b", isCoverChosen: false)])
        // Newest first, as the Library shows it.
        let entries = index.collapse(["x", "c", "b", "a", "y"])
        XCTAssertEqual(entries.map(\.id), ["x", "b", "y"])
        XCTAssertEqual(entries[1], StackedEntry(id: "b", stackID: "s", count: 3))
        XCTAssertTrue(entries[1].isStack)
        XCTAssertFalse(entries[0].isStack)
    }

    func testCollapseUsesTheFirstVisiblePhotoWhenTheCoverIsFilteredOut() {
        let index = PhotoStackIndex([PhotoStack(id: "s", memberIDs: ["a", "b", "c"], coverID: "b", isCoverChosen: false)])
        XCTAssertEqual(index.collapse(["c", "a"]), [StackedEntry(id: "c", stackID: "s", count: 2)])
        // One photo left in view is just that photo.
        XCTAssertEqual(index.collapse(["a"]), [StackedEntry(id: "a", stackID: nil, count: 1)])
    }

    func testExpandListsEveryPhotoOnce() {
        let index = PhotoStackIndex([PhotoStack(id: "s", memberIDs: ["a", "b"], coverID: "a", isCoverChosen: false)])
        XCTAssertEqual(index.expand(["x", "a", "b"]), ["x", "a", "b"])
    }

    func testHashFromHex() {
        XCTAssertEqual(StackPhoto.hash(fromHex: "00000000000000ff"), 255)
        XCTAssertNil(StackPhoto.hash(fromHex: "zz"))
        XCTAssertNil(StackPhoto.hash(fromHex: nil))
    }
}
