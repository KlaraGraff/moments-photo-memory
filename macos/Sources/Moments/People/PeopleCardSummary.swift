import Foundation

/// What a named person's card shows that depends on all of their faces,
/// worked out once per cache rebuild instead of on every redraw.
struct PeopleCardSummary {
    let cover: FaceObservation?
    let photoCount: Int
}

enum PeopleCardSummaries {
    /// One summary per person in `facesByPerson`. `keyFaceID` is asked once
    /// per person.
    static func make(
        facesByPerson: [String: [FaceObservation]],
        keyFaceID: (String) -> String?
    ) -> [String: PeopleCardSummary] {
        var summaries: [String: PeopleCardSummary] = [:]
        summaries.reserveCapacity(facesByPerson.count)
        for (personID, faces) in facesByPerson {
            let keyFaceIDForPerson: String? = keyFaceID(personID)
            let cover: FaceObservation? = PeopleFacePicker.cover(faces, keyFaceID: keyFaceIDForPerson)
            let mediaIDs: Set<String> = Set(faces.map { (face: FaceObservation) -> String in face.mediaID })
            let summary = PeopleCardSummary(cover: cover, photoCount: mediaIDs.count)
            summaries[personID] = summary
        }
        return summaries
    }
}
