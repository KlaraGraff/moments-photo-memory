import Foundation
import SwiftData
import XCTest
@testable import Moments

/// The People page's face caches, built in one pass. Every name, face, photo
/// and ID here is synthetic.
@MainActor
final class PeopleFaceCachesTests: XCTestCase {
    // MARK: - Synthetic library

    private struct Library {
        let container: ModelContainer
        let observations: [FaceObservation]
        let deletedMediaIDs: Set<String>
        let keyFaceIDs: [String: String]
        let personCount: Int
        let clusterCount: Int
        let looseClusterCount: Int
        let faceCount: Int
    }

    private static let base = Date(timeIntervalSince1970: 1_700_000_000)
    private static let keyFaceID = "synthetic-face-32"
    private static let keyPersonID = "synthetic-person-2"

    /// 300 faces over 5 persons, 6 clusters and 2 loose clusters, with shared
    /// photos, deleted photos, user confirmations and ties in creation date
    /// and quality.
    private func makeLibrary() throws -> Library {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let faceCount: Int = 300
        let personCount: Int = 5
        let clusterCount: Int = 6
        let looseClusterCount: Int = 2
        let deletedMediaIDs: Set<String> = ["synthetic-media-3", "synthetic-media-7", "synthetic-media-11", "synthetic-media-40"]
        var observations: [FaceObservation] = []
        observations.reserveCapacity(faceCount)
        for index in 0..<faceCount {
            let id: String = "synthetic-face-\(index)"
            let mediaID: String = "synthetic-media-\(index % 90)"
            let createdAt: Date = Self.base.addingTimeInterval(Double(index % 17))
            let quality: Double = 0.20 + Double(index % 13) * 0.05
            let confirmed: Bool = index % 3 == 0
            let source: String = (confirmed && index % 2 == 0) ? "user" : (index % 5 == 0 ? "user" : "auto")
            var personID: String? = nil
            var clusterID: String? = nil
            if index % 4 == 0 {
                personID = "synthetic-person-\(index % personCount)"
            } else if index % 11 == 0 {
                // Neither person nor cluster: the page draws no card for these.
                clusterID = nil
            } else if index % 7 == 0 {
                let looseName: String = index % looseClusterCount == 0 ? "loose-a" : "loose-b"
                clusterID = looseName
            } else {
                clusterID = "synthetic-cluster-\(index % clusterCount)"
            }
            let face = FaceObservation(
                id: id,
                mediaID: mediaID,
                rect: (0.1, 0.1, 0.2, 0.2),
                embedding: Data(repeating: 0, count: 8 * MemoryLayout<Float>.size),
                cropData: Data([1, 2, 3]),
                quality: quality,
                personID: personID,
                clusterID: clusterID,
                confirmed: confirmed,
                assignmentSource: source,
                createdAt: createdAt
            )
            context.insert(face)
            observations.append(face)
        }
        try context.save()
        let keyFaceIDs: [String: String] = [Self.keyPersonID: Self.keyFaceID]
        return Library(
            container: container,
            observations: observations,
            deletedMediaIDs: deletedMediaIDs,
            keyFaceIDs: keyFaceIDs,
            personCount: personCount,
            clusterCount: clusterCount,
            looseClusterCount: looseClusterCount,
            faceCount: faceCount
        )
    }

    // MARK: - Reference: today's refreshFaceCaches, with an index tie-break

    private struct ReferenceCluster {
        let id: String
        let faceIDs: [String]
        let coverID: String?
    }

    private struct ReferenceCaches {
        let facesByPerson: [String: [String]]
        let coversByPerson: [String: String]
        let photoCountsByPerson: [String: Int]
        let unnamedClusters: [ReferenceCluster]
        let looseFaceIDs: [String]
    }

    /// The old body of `refreshFaceCaches`, reading the SwiftData models
    /// directly. Equal creation dates fall back to the face's position, so the
    /// result does not depend on the sort's stability.
    private func reference(_ library: Library) -> ReferenceCaches {
        let deletedIDs: Set<String> = library.deletedMediaIDs
        let shown: [FaceObservation] = library.observations.filter { (face: FaceObservation) -> Bool in
            !deletedIDs.contains(face.mediaID)
        }
        var indexByFaceID: [String: Int] = [:]
        for (offset, face) in shown.enumerated() {
            indexByFaceID[face.id] = offset
        }
        let byPerson: [String: [FaceObservation]] = Dictionary(grouping: shown.compactMap { (face: FaceObservation) -> FaceObservation? in
            face.personID == nil ? nil : face
        }, by: { (face: FaceObservation) -> String in face.personID! })
        var facesByPerson: [String: [String]] = [:]
        var coversByPerson: [String: String] = [:]
        var photoCountsByPerson: [String: Int] = [:]
        for (personID, faces) in byPerson {
            facesByPerson[personID] = faces.map { (face: FaceObservation) -> String in face.id }
            let keyFaceID: String? = library.keyFaceIDs[personID]
            let cover: FaceObservation? = PeopleFacePicker.cover(faces, keyFaceID: keyFaceID)
            if let cover { coversByPerson[personID] = cover.id }
            let mediaIDs: Set<String> = Set(faces.map { (face: FaceObservation) -> String in face.mediaID })
            photoCountsByPerson[personID] = mediaIDs.count
        }
        let unfiled: [FaceObservation] = shown.filter { (face: FaceObservation) -> Bool in
            face.personID == nil && face.clusterID != nil
        }
        let byCluster: [String: [FaceObservation]] = Dictionary(grouping: unfiled, by: { (face: FaceObservation) -> String in face.clusterID! })
        func sortedByCreation(_ faces: [FaceObservation]) -> [FaceObservation] {
            return faces.sorted { (lhs: FaceObservation, rhs: FaceObservation) -> Bool in
                let left = lhs.createdAt
                let right = rhs.createdAt
                if left != right { return left < right }
                let leftIndex = indexByFaceID[lhs.id] ?? 0
                let rightIndex = indexByFaceID[rhs.id] ?? 0
                return leftIndex < rightIndex
            }
        }
        var clusters: [ReferenceCluster] = []
        var loose: [FaceObservation] = []
        for (clusterID, group) in byCluster {
            let sortedFaces: [FaceObservation] = sortedByCreation(group)
            if clusterID.hasPrefix("loose-") {
                loose.append(contentsOf: sortedFaces)
            } else {
                let cover: FaceObservation? = PeopleFacePicker.cover(sortedFaces)
                let ids: [String] = sortedFaces.map { (face: FaceObservation) -> String in face.id }
                clusters.append(ReferenceCluster(id: clusterID, faceIDs: ids, coverID: cover?.id))
            }
        }
        let unnamedClusters: [ReferenceCluster] = clusters.sorted { (lhs: ReferenceCluster, rhs: ReferenceCluster) -> Bool in
            lhs.id < rhs.id
        }
        let looseFaceIDs: [String] = sortedByCreation(loose).map { (face: FaceObservation) -> String in face.id }
        return ReferenceCaches(
            facesByPerson: facesByPerson,
            coversByPerson: coversByPerson,
            photoCountsByPerson: photoCountsByPerson,
            unnamedClusters: unnamedClusters,
            looseFaceIDs: looseFaceIDs
        )
    }

    // MARK: - Helpers that turn the result into comparable values

    private func faceIDs(_ caches: PeopleFaceCachesResult) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for (personID, faces) in caches.facesByPerson {
            result[personID] = faces.map { (face: FaceObservation) -> String in face.id }
        }
        return result
    }

    private func coverIDs(_ caches: PeopleFaceCachesResult) -> [String: String] {
        var result: [String: String] = [:]
        for (personID, summary) in caches.cardSummaries {
            if let cover = summary.cover { result[personID] = cover.id }
        }
        return result
    }

    private func photoCounts(_ caches: PeopleFaceCachesResult) -> [String: Int] {
        var result: [String: Int] = [:]
        for (personID, summary) in caches.cardSummaries {
            result[personID] = summary.photoCount
        }
        return result
    }

    private func clusterIDs(_ caches: PeopleFaceCachesResult) -> [String] {
        return caches.unnamedClusters.map { (cluster: PeopleClusterSnapshot) -> String in cluster.id }
    }

    private func clusterCoverIDs(_ caches: PeopleFaceCachesResult) -> [String: String] {
        var result: [String: String] = [:]
        for cluster in caches.unnamedClusters {
            if let cover = cluster.cover { result[cluster.id] = cover.id }
        }
        return result
    }

    private func clusterFaceIDs(_ caches: PeopleFaceCachesResult) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for cluster in caches.unnamedClusters {
            result[cluster.id] = cluster.faces.map { (face: FaceObservation) -> String in face.id }
        }
        return result
    }

    private func referenceClusterCoverIDs(_ clusters: [ReferenceCluster]) -> [String: String] {
        var result: [String: String] = [:]
        for cluster in clusters {
            if let coverID = cluster.coverID { result[cluster.id] = coverID }
        }
        return result
    }

    private func referenceClusterFaceIDs(_ clusters: [ReferenceCluster]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for cluster in clusters {
            result[cluster.id] = cluster.faceIDs
        }
        return result
    }

    // MARK: - Tests

    func testMakeMatchesReferenceForEveryCache() throws {
        let library: Library = try makeLibrary()
        let caches = PeopleFaceCaches.make(
            observations: library.observations,
            deletedIDs: library.deletedMediaIDs,
            keyFaceID: { (personID: String) -> String? in library.keyFaceIDs[personID] }
        )
        let expected: ReferenceCaches = reference(library)
        withExtendedLifetime(library.container) {}

        // The values the test itself built, so the comparison has something to bite on.
        XCTAssertEqual(library.observations.count, library.faceCount)
        XCTAssertEqual(expected.facesByPerson.count, library.personCount)
        XCTAssertEqual(expected.unnamedClusters.count, library.clusterCount)

        XCTAssertEqual(faceIDs(caches), expected.facesByPerson)
        XCTAssertEqual(coverIDs(caches), expected.coversByPerson)
        XCTAssertEqual(photoCounts(caches), expected.photoCountsByPerson)
        XCTAssertEqual(clusterIDs(caches), expected.unnamedClusters.map { (cluster: ReferenceCluster) -> String in cluster.id })
        XCTAssertEqual(clusterCoverIDs(caches), referenceClusterCoverIDs(expected.unnamedClusters))
        XCTAssertEqual(clusterFaceIDs(caches), referenceClusterFaceIDs(expected.unnamedClusters))
        let looseIDs: [String] = caches.looseFaces.map { (face: FaceObservation) -> String in face.id }
        XCTAssertEqual(looseIDs, expected.looseFaceIDs)
    }

    func testFacesInDeletedPhotosAreLeftOut() throws {
        let library: Library = try makeLibrary()
        let caches = PeopleFaceCaches.make(
            observations: library.observations,
            deletedIDs: library.deletedMediaIDs,
            keyFaceID: { (personID: String) -> String? in library.keyFaceIDs[personID] }
        )
        withExtendedLifetime(library.container) {}
        let remaining: [FaceObservation] = library.observations.filter { (face: FaceObservation) -> Bool in
            !library.deletedMediaIDs.contains(face.mediaID)
        }
        let expectedIDs: Set<String> = Set(remaining.map { (face: FaceObservation) -> String in face.id })
        var seenIDs: Set<String> = []
        for faces in caches.facesByPerson.values {
            for face in faces { seenIDs.insert(face.id) }
        }
        for cluster in caches.unnamedClusters {
            for face in cluster.faces { seenIDs.insert(face.id) }
        }
        for face in caches.looseFaces { seenIDs.insert(face.id) }
        XCTAssertTrue(seenIDs.isSubset(of: expectedIDs))
        XCTAssertFalse(seenIDs.contains("synthetic-face-3"))
        for personID in caches.facesByPerson.keys {
            let summary = try XCTUnwrap(caches.cardSummaries[personID])
            XCTAssertNotNil(summary.cover)
            XCTAssertGreaterThanOrEqual(summary.photoCount, 1)
        }
    }

    func testKeyFaceWinsTheCoverOfItsPerson() throws {
        let library: Library = try makeLibrary()
        let keyFace: FaceObservation = try XCTUnwrap(library.observations.first { (face: FaceObservation) -> Bool in
            face.id == Self.keyFaceID
        })
        // The key face is neither confirmed nor the sharpest, so only the key
        // rule can make it the cover.
        keyFace.confirmed = false
        keyFace.assignmentSource = "auto"
        keyFace.quality = 0
        let caches = PeopleFaceCaches.make(
            observations: library.observations,
            deletedIDs: library.deletedMediaIDs,
            keyFaceID: { (personID: String) -> String? in library.keyFaceIDs[personID] }
        )
        withExtendedLifetime(library.container) {}
        XCTAssertEqual(keyFace.personID, Self.keyPersonID)
        let summary = try XCTUnwrap(caches.cardSummaries[Self.keyPersonID])
        XCTAssertEqual(summary.cover?.id, Self.keyFaceID)
        // Without the key, the sharpest user-confirmed face wins instead.
        let plain = PeopleFaceCaches.make(
            observations: library.observations,
            deletedIDs: library.deletedMediaIDs,
            keyFaceID: { (personID: String) -> String? in nil }
        )
        let plainCover: FaceObservation? = plain.cardSummaries[Self.keyPersonID]?.cover
        XCTAssertNotNil(plainCover)
        XCTAssertNotEqual(plainCover?.id, Self.keyFaceID)
    }
}
