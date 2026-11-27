import Foundation
import XCTest
@testable import MomentsCore

final class CrossSourceDuplicateMatcherTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_767_225_600)
    private let matcher = CrossSourceDuplicateMatcher()
    private let sampleHash = "0f0f0f0f0f0f0f0f"

    func testBothWithLocationMatchWithinFiftyMetresAndOneSecond() {
        let folder = candidate("folder", at: 0, location: GeoPoint(latitude: 0.01, longitude: 0.02))
        let nearby = candidate("photos", at: 0.8, location: GeoPoint(latitude: 0.0103, longitude: 0.02))
        let far = candidate("photos-far", at: 0.8, location: GeoPoint(latitude: 0.011, longitude: 0.02))

        XCTAssertTrue(matcher.isMatch(nearby, folder))
        XCTAssertFalse(matcher.isMatch(far, folder), "about 110 m apart")
    }

    func testBothWithLocationIgnoreTheHash() {
        let folder = candidate("folder", at: 0, location: GeoPoint(latitude: 0, longitude: 0), hash: sampleHash)
        let photos = candidate("photos", at: 0, location: GeoPoint(latitude: 0, longitude: 0), hash: "f0f0f0f0f0f0f0f0")

        XCTAssertTrue(matcher.isMatch(photos, folder))
    }

    func testWithoutLocationOnEitherSideTheHashDecides() {
        let folder = candidate("folder", at: 0, location: GeoPoint(latitude: 0, longitude: 0), hash: sampleHash)
        let sixBitsOff = candidate("photos", at: 0.5, hash: "0f0f0f0f0f0f0f30") // 0f -> 30 flips 6 bits
        let sevenBitsOff = candidate("photos-other", at: 0.5, hash: "0f0f0f0f0f0f0f70")
        let noHash = candidate("photos-unhashed", at: 0.5)

        XCTAssertEqual(CrossSourceDuplicateMatcher.hammingDistance(sampleHash, "0f0f0f0f0f0f0f30"), 6)
        XCTAssertEqual(CrossSourceDuplicateMatcher.hammingDistance(sampleHash, "0f0f0f0f0f0f0f70"), 7)
        XCTAssertTrue(matcher.isMatch(sixBitsOff, folder))
        XCTAssertTrue(matcher.isMatch(folder, sixBitsOff), "the check is symmetric")
        XCTAssertFalse(matcher.isMatch(sevenBitsOff, folder))
        XCTAssertFalse(matcher.isMatch(noHash, folder), "no location and no hash is never a match")
    }

    func testNeitherWithLocationMatchesOnHash() {
        XCTAssertTrue(matcher.isMatch(candidate("a", at: 0, hash: sampleHash), candidate("b", at: 1, hash: sampleHash)))
    }

    func testDimensionsMayBeRotatedButMustAgree() {
        let landscape = candidate("folder", at: 0, width: 4032, height: 3024, hash: sampleHash)
        let portrait = candidate("photos", at: 0, width: 3024, height: 4032, hash: sampleHash)
        let cropped = candidate("photos-crop", at: 0, width: 4000, height: 3000, hash: sampleHash)
        let unknown = candidate("photos-unknown", at: 0, width: 0, height: 0, hash: sampleHash)

        XCTAssertTrue(matcher.isMatch(portrait, landscape))
        XCTAssertFalse(matcher.isMatch(cropped, landscape))
        XCTAssertFalse(matcher.isMatch(unknown, candidate("other-unknown", at: 0, width: 0, height: 0, hash: sampleHash)))
    }

    func testBurstFrameWithTheSamePictureDoesNotMatchBecauseTheTimeDiffers() {
        let frame = candidate("folder", at: 0, hash: sampleHash)
        let nextFrame = candidate("photos", at: 1.2, hash: sampleHash)

        XCTAssertFalse(matcher.isMatch(nextFrame, frame))
    }

    func testMatchingIDsFindsNeighboursAcrossSecondBoundaries() {
        let existing = [
            candidate("folder-a", at: 0.9, hash: sampleHash),
            candidate("folder-b", at: 100, location: GeoPoint(latitude: 0, longitude: 0)),
        ]
        let incoming = [
            candidate("photos-a", at: 1.7, hash: sampleHash),
            candidate("photos-b", at: 99.1, location: GeoPoint(latitude: 0, longitude: 0.0001)),
            candidate("photos-c", at: 50, hash: sampleHash),
        ]

        XCTAssertEqual(matcher.matchingIDs(incoming, against: existing), ["photos-a", "photos-b"])
        XCTAssertEqual(matcher.matchingIDs(incoming, against: []), [])
    }

    func testMatchingIDsHandlesATwentyThousandPhotoLibrary() {
        var existing: [DuplicateCandidate] = []
        var incoming: [DuplicateCandidate] = []
        for index in 0..<20_000 {
            let seconds = Double(index) * 2.5
            existing.append(candidate("folder-\(index)", at: seconds, hash: index.isMultiple(of: 2) ? sampleHash : "ffffffffffffffff"))
            incoming.append(candidate("photos-\(index)", at: seconds + 0.6, hash: sampleHash))
        }

        let matches = matcher.matchingIDs(incoming, against: existing)

        XCTAssertEqual(matches.count, 10_000)
        XCTAssertTrue(matches.contains("photos-0"))
        XCTAssertFalse(matches.contains("photos-1"))
    }

    private func candidate(
        _ id: String,
        at seconds: TimeInterval,
        width: Int = 100,
        height: Int = 80,
        location: GeoPoint? = nil,
        hash: String? = nil
    ) -> DuplicateCandidate {
        DuplicateCandidate(
            id: id,
            captureDate: base.addingTimeInterval(seconds),
            pixelWidth: width,
            pixelHeight: height,
            location: location,
            perceptualHash: hash
        )
    }
}
