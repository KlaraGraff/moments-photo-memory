import Foundation
import SwiftData

/// Everything the People page works out from its faces, built in one pass.
struct PeopleFaceCachesResult {
    let facesByPerson: [String: [FaceObservation]]
    let cardSummaries: [String: PeopleCardSummary]
    let unnamedClusters: [PeopleClusterSnapshot]
    let looseFaces: [FaceObservation]
}

/// Builds the People page caches from one read of each face. `FaceObservation`
/// is a SwiftData model, so every property read is a slow getter; grouping,
/// sorting and the cover choice all run on plain values instead.
enum PeopleFaceCaches {
    /// One face's fields, read once.
    private struct FaceRecord {
        let index: Int
        let face: FaceObservation
        let mediaID: String
        let personID: String?
        let clusterID: String?
        let createdAt: Date
        let userConfirmed: Bool
        let quality: Double
    }

    /// Faces in deleted photos are skipped. `keyFaceID` is asked once per
    /// person, the way `PeopleCardSummaries.make` asks it.
    @MainActor
    static func make(
        observations: [FaceObservation],
        deletedIDs: Set<String>,
        keyFaceID: (String) -> String?
    ) -> PeopleFaceCachesResult {
        var records: [FaceRecord] = []
        records.reserveCapacity(observations.count)
        for index in observations.indices {
            let face = observations[index]
            let mediaID = face.mediaID
            if deletedIDs.contains(mediaID) { continue }
            let confirmed = face.confirmed
            let source = face.assignmentSource
            let record = FaceRecord(
                index: index,
                face: face,
                mediaID: mediaID,
                personID: face.personID,
                clusterID: face.clusterID,
                createdAt: face.createdAt,
                userConfirmed: confirmed && source == "user",
                quality: face.quality
            )
            records.append(record)
        }

        // A face with a person belongs to that person only, never to a cluster,
        // which is the split the page has always used.
        var personRecords: [String: [FaceRecord]] = [:]
        var clusterRecords: [String: [FaceRecord]] = [:]
        for record in records {
            if let personID = record.personID {
                personRecords[personID, default: []].append(record)
            } else if let clusterID = record.clusterID {
                clusterRecords[clusterID, default: []].append(record)
            }
        }

        var facesByPerson: [String: [FaceObservation]] = [:]
        var cardSummaries: [String: PeopleCardSummary] = [:]
        facesByPerson.reserveCapacity(personRecords.count)
        cardSummaries.reserveCapacity(personRecords.count)
        for (personID, group) in personRecords {
            facesByPerson[personID] = group.map { (record: FaceRecord) -> FaceObservation in record.face }
            let key = keyFaceID(personID)
            let personCover: FaceObservation? = cover(group, keyFaceID: key)
            let mediaIDs: Set<String> = Set(group.map { (record: FaceRecord) -> String in record.mediaID })
            cardSummaries[personID] = PeopleCardSummary(cover: personCover, photoCount: mediaIDs.count)
        }

        var cards: [PeopleClusterSnapshot] = []
        var looseRecords: [FaceRecord] = []
        for (clusterID, group) in clusterRecords {
            let sorted: [FaceRecord] = byCreation(group)
            if clusterID.hasPrefix("loose-") {
                looseRecords.append(contentsOf: sorted)
            } else {
                let clusterCover: FaceObservation? = cover(sorted, keyFaceID: nil)
                let faces: [FaceObservation] = sorted.map { (record: FaceRecord) -> FaceObservation in record.face }
                cards.append(PeopleClusterSnapshot(id: clusterID, faces: faces, cover: clusterCover))
            }
        }

        let unnamedClusters: [PeopleClusterSnapshot] = cards.sorted { (lhs: PeopleClusterSnapshot, rhs: PeopleClusterSnapshot) -> Bool in
            lhs.id < rhs.id
        }
        let looseFaces: [FaceObservation] = byCreation(looseRecords).map { (record: FaceRecord) -> FaceObservation in record.face }
        return PeopleFaceCachesResult(
            facesByPerson: facesByPerson,
            cardSummaries: cardSummaries,
            unnamedClusters: unnamedClusters,
            looseFaces: looseFaces
        )
    }

    /// Oldest first. Equal creation dates keep the order the faces arrived in,
    /// so the result does not depend on the sort's stability.
    private static func byCreation(_ records: [FaceRecord]) -> [FaceRecord] {
        records.sorted { (lhs: FaceRecord, rhs: FaceRecord) -> Bool in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.index < rhs.index
        }
    }

    /// The same rule as `PeopleFacePicker.cover`: the key photo first, else a
    /// user-confirmed face, then the sharpest. On a tie the first face wins,
    /// as `max(by:)` keeps the first of equal elements.
    private static func cover(_ records: [FaceRecord], keyFaceID: String?) -> FaceObservation? {
        if let keyFaceID {
            for record in records where record.face.id == keyFaceID { return record.face }
        }
        var best: FaceRecord?
        for record in records {
            guard let current = best else {
                best = record
                continue
            }
            let better: Bool
            if record.userConfirmed != current.userConfirmed {
                better = record.userConfirmed
            } else {
                better = record.quality > current.quality
            }
            if better { best = record }
        }
        return best?.face
    }
}
