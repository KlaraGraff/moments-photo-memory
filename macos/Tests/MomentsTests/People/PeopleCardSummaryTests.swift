import Foundation
import SwiftData
import XCTest
@testable import Moments

/// Card summaries for the People page. Every name, face and ID here is synthetic.
@MainActor
final class PeopleCardSummaryTests: XCTestCase {
    private func face(_ id: String, personID: String? = nil, clusterID: String? = nil, rejected: String = "") -> FaceObservation {
        FaceObservation(
            id: id,
            mediaID: "synthetic-\(id)",
            rect: (0.1, 0.1, 0.2, 0.2),
            embedding: Data(repeating: 0, count: 8 * MemoryLayout<Float>.size),
            cropData: Data([1, 2, 3]),
            quality: 0.8,
            personID: personID,
            clusterID: clusterID,
            confirmed: personID != nil,
            rejectedPersonIDs: rejected,
            assignmentSource: personID != nil ? "user" : "auto"
        )
    }

    /// A synthetic face with an explicit media ID, quality and confirmation
    /// state, so covers and photo counts have something to tell apart.
    private func syntheticFace(
        _ id: String,
        personID: String,
        mediaID: String,
        quality: Double,
        confirmed: Bool
    ) -> FaceObservation {
        let created = face(id, personID: personID)
        created.mediaID = mediaID
        created.quality = quality
        created.confirmed = confirmed
        created.assignmentSource = confirmed ? "user" : "auto"
        return created
    }

    /// `count` faces for one person. Every third face shares its photo with
    /// another one, so the photo count is smaller than the face count.
    private func faces(personID: String, count: Int) -> [FaceObservation] {
        var result: [FaceObservation] = []
        for index in 0..<count {
            let mediaNumber: Int = index % 3
            let mediaID: String = "synthetic-media-\(personID)-\(mediaNumber)"
            let quality: Double = 0.30 + Double(index) * 0.07
            let confirmed: Bool = index % 2 == 1
            let id: String = "\(personID)-face-\(index)"
            let created: FaceObservation = syntheticFace(
                id,
                personID: personID,
                mediaID: mediaID,
                quality: quality,
                confirmed: confirmed
            )
            result.append(created)
        }
        return result
    }

    private func fixture(counts: [String: Int]) -> [String: [FaceObservation]] {
        var facesByPerson: [String: [FaceObservation]] = [:]
        for personID in counts.keys {
            let count: Int = counts[personID] ?? 0
            let personFaces: [FaceObservation] = faces(personID: personID, count: count)
            facesByPerson[personID] = personFaces
        }
        return facesByPerson
    }

    private func distinctPhotoCount(_ faces: [FaceObservation]) -> Int {
        let mediaIDs: Set<String> = Set(faces.map { (face: FaceObservation) -> String in face.mediaID })
        return mediaIDs.count
    }

    func testSummariesMatchThePickerAndCountDistinctPhotos() {
        let counts: [String: Int] = ["person-one": 1, "person-four": 4, "person-nine": 9]
        let facesByPerson: [String: [FaceObservation]] = fixture(counts: counts)
        let summaries: [String: PeopleCardSummary] = PeopleCardSummaries.make(
            facesByPerson: facesByPerson,
            keyFaceID: { (personID: String) -> String? in nil }
        )

        XCTAssertEqual(summaries.count, 3)
        for personID in counts.keys {
            let personFaces: [FaceObservation] = facesByPerson[personID] ?? []
            let expectedCover: FaceObservation? = PeopleFacePicker.cover(personFaces, keyFaceID: nil)
            let summary: PeopleCardSummary? = summaries[personID]
            XCTAssertEqual(summary?.cover?.id, expectedCover?.id, "Cover for \(personID)")
            XCTAssertEqual(summary?.photoCount, distinctPhotoCount(personFaces), "Photo count for \(personID)")
            XCTAssertLessThanOrEqual(summary?.photoCount ?? -1, personFaces.count)
        }
        // Sanity check the fixture really has faces sharing a photo.
        let nineFaces: [FaceObservation] = facesByPerson["person-nine"] ?? []
        XCTAssertEqual(nineFaces.count, 9)
        XCTAssertEqual(distinctPhotoCount(nineFaces), 3)
    }

    func testKeyFaceWinsForThatPersonAndOthersAreUnchanged() {
        let counts: [String: Int] = ["person-one": 1, "person-four": 4, "person-nine": 9]
        let facesByPerson: [String: [FaceObservation]] = fixture(counts: counts)
        let baseline: [String: PeopleCardSummary] = PeopleCardSummaries.make(
            facesByPerson: facesByPerson,
            keyFaceID: { (personID: String) -> String? in nil }
        )
        let chosenFaces: [FaceObservation] = facesByPerson["person-four"] ?? []
        // The lowest-quality face of this person: the picker would never pick it.
        let lowQualityFace: FaceObservation? = chosenFaces.min {
            (lhs: FaceObservation, rhs: FaceObservation) -> Bool in lhs.quality < rhs.quality
        }
        let keyFaceID: String = lowQualityFace?.id ?? ""
        XCTAssertFalse(keyFaceID.isEmpty)
        XCTAssertNotEqual(baseline["person-four"]?.cover?.id, keyFaceID)

        let summaries: [String: PeopleCardSummary] = PeopleCardSummaries.make(
            facesByPerson: facesByPerson
        ) { (personID: String) -> String? in
            personID == "person-four" ? keyFaceID : nil
        }

        XCTAssertEqual(summaries["person-four"]?.cover?.id, keyFaceID)
        XCTAssertEqual(summaries["person-four"]?.photoCount, baseline["person-four"]?.photoCount)
        XCTAssertEqual(summaries["person-one"]?.cover?.id, baseline["person-one"]?.cover?.id)
        XCTAssertEqual(summaries["person-nine"]?.cover?.id, baseline["person-nine"]?.cover?.id)
        XCTAssertEqual(summaries["person-one"]?.photoCount, baseline["person-one"]?.photoCount)
        XCTAssertEqual(summaries["person-nine"]?.photoCount, baseline["person-nine"]?.photoCount)
    }

    func testKeyFaceThatIsGoneFallsBackToThePicker() {
        let counts: [String: Int] = ["person-one": 1, "person-four": 4, "person-nine": 9]
        let facesByPerson: [String: [FaceObservation]] = fixture(counts: counts)
        let summaries: [String: PeopleCardSummary] = PeopleCardSummaries.make(
            facesByPerson: facesByPerson,
            keyFaceID: { (personID: String) -> String? in
                personID == "person-nine" ? "synthetic-face-that-is-gone" : nil
            }
        )

        let nineFaces: [FaceObservation] = facesByPerson["person-nine"] ?? []
        let expectedCover: FaceObservation? = PeopleFacePicker.cover(nineFaces, keyFaceID: nil)
        XCTAssertEqual(summaries["person-nine"]?.cover?.id, expectedCover?.id)
        XCTAssertNotEqual(summaries["person-nine"]?.cover?.id, "synthetic-face-that-is-gone")
    }

    func testKeyFaceIDIsAskedOncePerPerson() {
        let counts: [String: Int] = ["person-one": 1, "person-four": 4, "person-nine": 9]
        let facesByPerson: [String: [FaceObservation]] = fixture(counts: counts)
        var askedPersonIDs: [String] = []
        let summaries: [String: PeopleCardSummary] = PeopleCardSummaries.make(
            facesByPerson: facesByPerson
        ) { (personID: String) -> String? in
            askedPersonIDs.append(personID)
            return nil
        }

        XCTAssertEqual(summaries.count, 3)
        XCTAssertEqual(askedPersonIDs.count, 3)
        for personID in counts.keys {
            let timesAsked: Int = askedPersonIDs.filter { (asked: String) -> Bool in asked == personID }.count
            XCTAssertEqual(timesAsked, 1, "keyFaceID asked \(timesAsked) times for \(personID)")
        }
    }

    func testEmptyInputAndPersonWithoutFaces() {
        let empty: [String: PeopleCardSummary] = PeopleCardSummaries.make(
            facesByPerson: [:],
            keyFaceID: { (personID: String) -> String? in nil }
        )
        XCTAssertTrue(empty.isEmpty)

        var facesByPerson: [String: [FaceObservation]] = fixture(counts: ["person-four": 4])
        facesByPerson["person-without-faces"] = []
        let summaries: [String: PeopleCardSummary] = PeopleCardSummaries.make(
            facesByPerson: facesByPerson,
            keyFaceID: { (personID: String) -> String? in nil }
        )
        XCTAssertEqual(summaries.count, 2)
        XCTAssertNil(summaries["person-without-faces"]?.cover)
        XCTAssertEqual(summaries["person-without-faces"]?.photoCount, 0)
        XCTAssertNotNil(summaries["person-four"]?.cover)
        XCTAssertEqual(summaries["person-four"]?.photoCount, 3)
    }
}
