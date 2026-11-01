import Foundation
import XCTest
@testable import MomentsCore

final class PhotoStackDetectorEdgeCaseTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func photo(
        _ id: String,
        _ seconds: Double,
        hash: UInt64? = 0,
        print: [Float]? = nil,
        quality: StackQuality? = nil
    ) -> StackPhoto {
        StackPhoto(
            id: id,
            captureDate: base.addingTimeInterval(seconds),
            perceptualHash: hash,
            featurePrint: print,
            quality: quality
        )
    }

    /// The member lists of every stack, ordered by their first member.
    private func memberLists(_ index: PhotoStackIndex) -> [[String]] {
        index.stacks.values.map(\.memberIDs).sorted { ($0.first ?? "") < ($1.first ?? "") }
    }

    // MARK: - 1

    func testHashFromHexRejectsWrongLengthAndNonHexCharacters() {
        XCTAssertNil(StackPhoto.hash(fromHex: nil))
        XCTAssertNil(StackPhoto.hash(fromHex: "0000000000000ff"))
        XCTAssertNil(StackPhoto.hash(fromHex: "000000000000000ff"))
        XCTAssertNil(StackPhoto.hash(fromHex: "zzzzzzzzzzzzzzzz"))
        XCTAssertNil(StackPhoto.hash(fromHex: "0000000000000gff"))
        XCTAssertNil(StackPhoto.hash(fromHex: ""))
    }

    func testHashFromHexParsesSixteenHexDigits() {
        XCTAssertEqual(StackPhoto.hash(fromHex: "00000000000000ff"), 255)
        XCTAssertEqual(StackPhoto.hash(fromHex: "ffffffffffffffff"), UInt64.max)
        XCTAssertEqual(StackPhoto.hash(fromHex: "0000000000000000"), 0)
    }

    // MARK: - 2

    func testShotsExactlyFiveSecondsApartStack() {
        let index = PhotoStackDetector().detect([photo("a", 0), photo("b", 5)])
        XCTAssertEqual(memberLists(index), [["a", "b"]])
    }

    func testShotsFivePointZeroOneSecondsApartDoNotStack() {
        let index = PhotoStackDetector().detect([photo("a", 0), photo("b", 5.01)])
        XCTAssertTrue(index.isEmpty)
    }

    func testEveryShotAtTheMaximumGapChainsOneStack() {
        let photos = [photo("a", 0), photo("b", 5), photo("c", 10)]
        let index = PhotoStackDetector().detect(photos)
        XCTAssertEqual(memberLists(index), [["a", "b", "c"]])
    }

    // MARK: - 3

    func testChainOfSimilarShotsStopsGrowingPastTheMaximumSpan() {
        // Each shot is 4 s after the last, so 16 shots span 60 s exactly
        // (0 s ... 60 s). The 17th shot at 64 s is 68 s from the first, which
        // is past the 60 s span, so a second stack starts.
        let photos = (0..<20).map { photo("p\($0)", Double($0) * 4) }
        let index = PhotoStackDetector().detect(photos)
        XCTAssertEqual(index.stacks.count, 2)
        XCTAssertEqual(index.stack(containing: "p0")?.memberIDs, (0..<16).map { "p\($0)" })
        XCTAssertEqual(index.stack(containing: "p16")?.memberIDs, (16..<20).map { "p\($0)" })
        XCTAssertEqual(index.stacks.values.map(\.count).sorted(), [4, 16])
    }

    // MARK: - 4

    func testFeaturePrintsWinOverIdenticalHashes() {
        let photos = [
            photo("a", 0, hash: 0, print: [1, 0, 0]),
            photo("b", 1, hash: 0, print: [0, 1, 0]),
        ]
        XCTAssertTrue(PhotoStackDetector().detect(photos).isEmpty)
    }

    func testIdenticalHashesStackWhenThereAreNoFeaturePrints() {
        let photos = [
            photo("a", 0, hash: 0, print: nil),
            photo("b", 1, hash: 0, print: nil),
        ]
        XCTAssertEqual(memberLists(PhotoStackDetector().detect(photos)), [["a", "b"]])
    }

    // MARK: - 5

    func testTwelveDifferingHashBitsStack() {
        let photos = [photo("a", 0, hash: 0), photo("b", 1, hash: (1 << 12) - 1)]
        XCTAssertEqual(memberLists(PhotoStackDetector().detect(photos)), [["a", "b"]])
    }

    func testThirteenDifferingHashBitsDoNotStack() {
        let photos = [photo("a", 0, hash: 0), photo("b", 1, hash: (1 << 13) - 1)]
        XCTAssertTrue(PhotoStackDetector().detect(photos).isEmpty)
    }

    // MARK: - 6

    func testShotsWithoutHashAndWithoutFeaturePrintNeverStack() {
        let photos = [photo("a", 0, hash: nil), photo("b", 1, hash: nil)]
        XCTAssertTrue(PhotoStackDetector().detect(photos).isEmpty)
    }

    func testAFeaturePrintOnOnlyOneShotFallsBackToTheHashes() {
        let photos = [
            photo("a", 0, hash: 0, print: [1, 0, 0]),
            photo("b", 1, hash: 0, print: nil),
        ]
        // The pair falls back to the hashes, which are identical.
        XCTAssertEqual(memberLists(PhotoStackDetector().detect(photos)), [["a", "b"]])
    }

    // MARK: - 7

    func testPhotosWithoutACaptureDateAreNeverInAnAutomaticStack() {
        let photos = [
            StackPhoto(id: "a", captureDate: nil, perceptualHash: 0),
            photo("b", 1, hash: 0),
            StackPhoto(id: "c", captureDate: nil, perceptualHash: 0),
            photo("d", 2, hash: 0),
        ]
        let index = PhotoStackDetector().detect(photos)
        XCTAssertEqual(memberLists(index), [["b", "d"]])
        XCTAssertNil(index.stack(containing: "a"))
        XCTAssertNil(index.stack(containing: "c"))
    }

    // MARK: - 8

    func testAutomaticStackIDIsBuiltFromTheFirstShotAndMembersAreOldestFirst() {
        let photos = [photo("late", 2), photo("early", 0), photo("middle", 1)]
        let index = PhotoStackDetector().detect(photos)
        let stack = index.stack(containing: "middle")
        XCTAssertEqual(stack?.id, "stack-early")
        XCTAssertEqual(stack?.memberIDs, ["early", "middle", "late"])
        XCTAssertEqual(index.stackIDByMember, ["early": "stack-early", "middle": "stack-early", "late": "stack-early"])
    }

    // MARK: - 9

    func testADecisionKeepsItsMembersTogetherEvenFarApartInTime() {
        let photos = [photo("a", 0), photo("b", 1000), photo("c", 2000)]
        let decision = StackDecision(id: "chosen", memberIDs: ["c", "a", "b"])
        let stack = PhotoStackDetector().detect(photos, decisions: [decision]).stack(containing: "a")
        XCTAssertEqual(stack?.id, "chosen")
        XCTAssertEqual(stack?.memberIDs, ["a", "b", "c"])
        XCTAssertEqual(stack?.count, 3)
    }

    func testADecisionDropsMemberIDsThatAreNotAmongThePhotos() {
        let photos = [photo("a", 0), photo("b", 1)]
        let decision = StackDecision(id: "chosen", memberIDs: ["a", "ghost", "b"])
        let index = PhotoStackDetector().detect(photos, decisions: [decision])
        XCTAssertEqual(index.stack(containing: "a")?.memberIDs, ["a", "b"])
        XCTAssertNil(index.stack(containing: "ghost"))
        XCTAssertNil(index.stackIDByMember["ghost"])
    }

    func testADecisionWithFewerThanTwoRealMembersMakesNoStackAndItsPhotosAreNotStackedAutomatically() {
        // Without the decision "a" and "b" would be one automatic stack.
        let photos = [photo("a", 0), photo("b", 1)]
        // The unknown id leaves the decision with a single member.
        let decision = StackDecision(id: "chosen", memberIDs: ["a", "ghost"])
        let index = PhotoStackDetector().detect(photos, decisions: [decision])
        XCTAssertTrue(index.isEmpty)
        // "a" is claimed by the decision, so it is no stack and is not picked
        // up by the automatic pass either.
        XCTAssertNil(index.stack(containing: "a"))
        XCTAssertNil(index.stack(containing: "b"))
        XCTAssertNil(index.stack(containing: "ghost"))
        XCTAssertTrue(index.stackIDByMember.isEmpty)
    }

    // MARK: - 10

    func testUnstackedDecisionPhotosAreNeverStackedEvenAutomatically() {
        // Without the decision "a", "b" and "c" would be one automatic stack.
        let photos = [photo("a", 0), photo("b", 1), photo("c", 2), photo("alone", 5000)]
        let decision = StackDecision(id: "chosen", memberIDs: ["a", "b", "c"], isUnstacked: true)
        let index = PhotoStackDetector().detect(photos, decisions: [decision])
        XCTAssertTrue(index.isEmpty)
        for id in ["a", "b", "c", "alone"] {
            XCTAssertNil(index.stack(containing: id))
        }
    }

    // MARK: - 11

    func testRemovedIDsShowOnTheirOwnAndAreNotStackedAutomatically() {
        let photos = [photo("a", 0), photo("b", 1), photo("c", 2)]
        let decision = StackDecision(id: "chosen", memberIDs: ["a", "c"], removedIDs: ["b"])
        let index = PhotoStackDetector().detect(photos, decisions: [decision])
        XCTAssertEqual(index.stack(containing: "a")?.memberIDs, ["a", "c"])
        XCTAssertNil(index.stack(containing: "b"))
        XCTAssertNil(index.stackIDByMember["b"])
    }

    func testRemovedIDOutsideTheDecisionIsNotStackedAutomaticallyEither() {
        let photos = [photo("a", 0), photo("b", 1), photo("c", 2)]
        let decision = StackDecision(id: "chosen", memberIDs: ["a", "b"], removedIDs: ["c"])
        let index = PhotoStackDetector().detect(photos, decisions: [decision])
        XCTAssertEqual(index.stack(containing: "a")?.memberIDs, ["a", "b"])
        XCTAssertNil(index.stack(containing: "c"))
    }

    // MARK: - 12

    func testADecisionsCoverIDIsUsedWhenItIsAMember() {
        let photos = [photo("a", 0), photo("b", 1), photo("c", 2)]
        let decision = StackDecision(id: "chosen", memberIDs: ["a", "b", "c"], coverID: "b")
        let stack = PhotoStackDetector().detect(photos, decisions: [decision]).stack(containing: "c")
        XCTAssertEqual(stack?.coverID, "b")
        XCTAssertEqual(stack?.isCoverChosen, true)
    }

    func testADecisionsCoverIDThatIsNotAMemberIsIgnoredAndTheBestShotIsPicked() {
        let photos = [photo("a", 0), photo("b", 1000), photo("c", 2000)]
        let decision = StackDecision(id: "chosen", memberIDs: ["a", "b", "c"], coverID: "nobody")
        let stack = PhotoStackDetector().detect(photos, decisions: [decision]).stack(containing: "a")
        XCTAssertEqual(stack?.coverID, "a")
        XCTAssertEqual(stack?.isCoverChosen, false)
    }

    func testADecisionsRemovedCoverIsIgnoredAndTheBestShotIsPicked() {
        let photos = [photo("a", 0), photo("b", 1), photo("c", 2)]
        let decision = StackDecision(id: "chosen", memberIDs: ["a", "c"], coverID: "b", removedIDs: ["b"])
        let stack = PhotoStackDetector().detect(photos, decisions: [decision]).stack(containing: "c")
        XCTAssertEqual(stack?.coverID, "a")
        XCTAssertEqual(stack?.isCoverChosen, false)
    }

    // MARK: - 13

    func testAPhotoInTwoDecisionsGoesToTheDecisionWhoseIDSortsFirst() {
        let photos = [photo("a", 0), photo("b", 1), photo("c", 2)]
        let later = StackDecision(id: "b-decision", memberIDs: ["a", "b"])
        let earlier = StackDecision(id: "a-decision", memberIDs: ["a", "c"])
        let index = PhotoStackDetector().detect(photos, decisions: [later, earlier])
        XCTAssertEqual(index.stack(containing: "a")?.id, "a-decision")
        XCTAssertEqual(index.stack(containing: "a")?.memberIDs, ["a", "c"])
        XCTAssertNil(index.stack(containing: "b"))
        XCTAssertEqual(index.stack(containing: "c")?.id, "a-decision")
    }

    // MARK: - 14

    func testBestCoverWithoutQualityIsTheFirstShot() {
        let photos = [photo("b", 1), photo("a", 0)]
        XCTAssertEqual(PhotoStackDetector.bestCover(photos), "a")
    }

    func testBestCoverWithoutFacesIsTheSharpest() {
        let photos = [
            photo("a", 0, quality: StackQuality(sharpness: 100)),
            photo("b", 1, quality: StackQuality(sharpness: 400)),
            photo("c", 2, quality: StackQuality(sharpness: 200)),
        ]
        XCTAssertEqual(PhotoStackDetector.bestCover(photos), "b")
    }

    func testBestCoverWithFacesPrefersAClearOpenEyedFaceOverASlightlySharperShotWithoutFaces() {
        let photos = [
            photo("faces", 0, quality: StackQuality(sharpness: 500, faceCount: 1, faceQuality: 0.5, eyesOpen: 1)),
            photo("scenery", 1, quality: StackQuality(sharpness: 550)),
        ]
        // "scenery" only scores 0.2 * 1 = 0.2, "faces" scores 0.8 + 0.2 = 1.
        XCTAssertEqual(PhotoStackDetector.bestCover(photos), "faces")
    }

    func testBestCoverTiesGoToTheEarlierShot() {
        let photos = [
            photo("firstsharp", 0, quality: StackQuality(sharpness: 500)),
            photo("secondsharp", 1, quality: StackQuality(sharpness: 500)),
        ]
        XCTAssertEqual(PhotoStackDetector.bestCover(photos), "firstsharp")
    }

    func testBestCoverNeverPicksAShotWithoutMeasurements() {
        let photos = [
            photo("measured", 1, quality: StackQuality(sharpness: 900)),
            photo("unmeasured", 0),
        ]
        // A single measured shot has low == high, so it is normalized to 0.5;
        // the unmeasured shot cannot beat it.
        XCTAssertEqual(PhotoStackDetector.bestCover(photos), "measured")
    }

    // MARK: - 15

    func testCosineDistanceIsNilForDifferentLengthsEmptyArraysAndZeroVectors() {
        XCTAssertNil(PhotoStackDetector.cosineDistance([1, 0], [1, 0, 0]))
        XCTAssertNil(PhotoStackDetector.cosineDistance([], []))
        XCTAssertNil(PhotoStackDetector.cosineDistance([0, 0], [1, 0]))
        XCTAssertNil(PhotoStackDetector.cosineDistance([1, 0], [0, 0]))
        XCTAssertNil(PhotoStackDetector.cosineDistance([0, 0, 0], [0, 0, 0]))
    }

    func testCosineDistanceOfIdenticalOrthogonalAndOppositeVectors() throws {
        let identical = try XCTUnwrap(PhotoStackDetector.cosineDistance([1, 0, 0], [1, 0, 0]))
        XCTAssertEqual(identical, 0, accuracy: 1e-12)
        let orthogonal = try XCTUnwrap(PhotoStackDetector.cosineDistance([1, 0, 0], [0, 1, 0]))
        XCTAssertEqual(orthogonal, 1, accuracy: 1e-12)
        let opposite = try XCTUnwrap(PhotoStackDetector.cosineDistance([1, 0, 0], [-1, 0, 0]))
        XCTAssertEqual(opposite, 2, accuracy: 1e-12)
    }
}
