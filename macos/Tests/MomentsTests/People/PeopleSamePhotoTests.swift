import CoreGraphics
import Foundation
import XCTest
@testable import Moments

/// One person appears at most once per photo, and "who is this" zooms to one
/// face. Every face, photo and vector here is synthetic.
final class PeopleSamePhotoTests: XCTestCase {
    private func embedding(_ values: [Float]) -> Data {
        var data = Data()
        values.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    private func face(
        _ id: String,
        photo: String,
        _ vector: [Float],
        personID: String? = nil,
        clusterID: String? = nil,
        confirmed: Bool = false
    ) -> PeopleFaceSnapshot {
        PeopleFaceSnapshot(
            id: id,
            personID: personID,
            clusterID: clusterID ?? (personID == nil ? "pending-\(id)" : nil),
            confirmed: confirmed,
            assignmentSource: confirmed ? "user" : "auto",
            rejectedPersonIDs: "",
            embedding: embedding(vector),
            mediaID: photo
        )
    }

    func testTwoFacesFromOnePhotoNeverShareAnUnnamedGroup() {
        // a and b are near-identical vectors (think twins, or a face and its
        // reflection) but sit in the same photo; c is the same look elsewhere.
        let faces = [
            face("a", photo: "photo-1", [1, 0]),
            face("b", photo: "photo-1", [0.99, 0.01]),
            face("c", photo: "photo-2", [0.995, 0.005])
        ]
        let result = PeopleScanController.makeAssignmentsResult(faces: faces, people: [], shouldStop: { false })
        XCTAssertFalse(result.clusteringStopped)
        let cluster = Dictionary(uniqueKeysWithValues: result.assignments.map { ($0.id, $0.clusterID) })
        XCTAssertNotNil(cluster["a"] ?? nil)
        XCTAssertNotEqual(cluster["a"], cluster["b"], "Two faces in one photo are two people")
        XCTAssertTrue(cluster["c"] == cluster["a"] || cluster["c"] == cluster["b"], "The other photo still groups with one of them")
        XCTAssertFalse(result.assignments.contains { $0.clusterID?.hasPrefix("pending-") == true })
    }

    func testOnlyTheCloserFaceInAPhotoIsSuggestedForAPerson() {
        let faces = [
            face("known", photo: "photo-1", [1, 0, 0], personID: "person-a", confirmed: true),
            face("close", photo: "photo-2", [0.99, 0.02, 0]),
            face("farther", photo: "photo-2", [0.9, 0.2, 0])
        ]
        let result = PeopleScanController.makeAssignmentsResult(faces: faces, people: [PeoplePersonSnapshot(id: "person-a")], shouldStop: { false })
        let byID = Dictionary(uniqueKeysWithValues: result.assignments.map { ($0.id, $0) })
        XCTAssertEqual(byID["known"]?.personID, "person-a")
        XCTAssertEqual(byID["close"]?.personID, "person-a")
        XCTAssertNil(byID["farther"]?.personID)
        XCTAssertEqual(byID["farther"]?.clusterID, "cluster-solo-farther")
    }

    func testAConfirmedFaceWinsItsPhotoOverASuggestion() {
        var assignments = [
            PeopleFaceAssignment(id: "known", personID: "person-a", clusterID: nil, confirmed: true, assignmentSource: "user"),
            PeopleFaceAssignment(id: "suggested", personID: "person-a", clusterID: nil, confirmed: false, assignmentSource: "auto")
        ]
        let faces = [
            face("known", photo: "photo-1", [0, 1], personID: "person-a", confirmed: true),
            // Closer to the person's other photos, but the user already picked
            // the face in this photo.
            face("suggested", photo: "photo-1", [1, 0], personID: "person-a")
        ]
        PeopleScanController.separateSamePhotoFaces(&assignments, faces: faces)
        XCTAssertEqual(assignments[0].personID, "person-a")
        XCTAssertTrue(assignments[0].confirmed)
        XCTAssertNil(assignments[1].personID)
        XCTAssertEqual(assignments[1].clusterID, "cluster-solo-suggested")
    }

    func testFacesWithoutAPhotoAreLeftAlone() {
        var assignments = [
            PeopleFaceAssignment(id: "x", personID: nil, clusterID: "cluster-x", confirmed: false, assignmentSource: "auto"),
            PeopleFaceAssignment(id: "y", personID: nil, clusterID: "cluster-x", confirmed: false, assignmentSource: "auto")
        ]
        let faces = [face("x", photo: "", [1, 0], clusterID: "cluster-x"), face("y", photo: "", [1, 0], clusterID: "cluster-x")]
        PeopleScanController.separateSamePhotoFaces(&assignments, faces: faces)
        XCTAssertEqual(assignments.map(\.clusterID), ["cluster-x", "cluster-x"])
    }

    func testZoomCropIsASquareAroundTheFace() {
        // Vision rect (normalized, y-up) at the centre of a 1000×500 photo.
        let rect = PeopleFaceZoom.cropRect(faceRect: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), imageSize: CGSize(width: 1000, height: 500))
        XCTAssertEqual(rect, CGRect(x: 320, y: 70, width: 360, height: 360))
    }

    func testZoomCropStaysInsideThePhoto() {
        // A face in the top-left corner: y-up 0.9 is the top in y-down pixels.
        let corner = PeopleFaceZoom.cropRect(faceRect: CGRect(x: 0, y: 0.9, width: 0.1, height: 0.1), imageSize: CGSize(width: 1000, height: 1000))
        XCTAssertEqual(corner, CGRect(x: 0, y: 0, width: 180, height: 180))
        // A face too big to give context shrinks to the photo's short side.
        let big = PeopleFaceZoom.cropRect(faceRect: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8), imageSize: CGSize(width: 400, height: 300))
        XCTAssertEqual(big.width, 300)
        XCTAssertEqual(big.height, 300)
        XCTAssertTrue(CGRect(x: 0, y: 0, width: 400, height: 300).contains(big))
    }
}
