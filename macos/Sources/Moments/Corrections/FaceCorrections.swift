import Foundation
import SwiftData

/// "This isn't Anna, it's Ben": moves a face straight to the right person.
/// The face is confirmed for Ben and Anna is remembered as wrong for it, so a
/// later scan neither moves it back nor suggests Anna again.
@MainActor
enum FaceCorrection {
    /// A face and its old person before a reassignment, for Undo.
    struct Snapshot: Equatable {
        let faceID: String
        let personID: String?
        let clusterID: String?
        let confirmed: Bool
        let assignmentSource: String
        let rejectedPersonIDs: String
        /// Set when the face was the old person's last one and they were hidden.
        var hiddenPersonID: String?
        /// Set when the reassignment created the new person.
        var createdPersonID: String?

        init(_ face: FaceObservation) {
            faceID = face.id
            personID = face.personID
            clusterID = face.clusterID
            confirmed = face.confirmed
            assignmentSource = face.assignmentSource
            rejectedPersonIDs = face.rejectedPersonIDs
        }
    }

    /// Moves `face` to `target`. Returns nil when it already is theirs.
    @discardableResult
    static func reassign(_ face: FaceObservation, to target: Person, observations: [FaceObservation], now: Date = .now) -> Snapshot? {
        guard face.personID != target.id || !face.confirmed || face.assignmentSource != "user" else { return nil }
        var snapshot = Snapshot(face)
        var rejected = face.rejectedPersonIDSet
        if let old = face.personID, old != target.id { rejected.insert(old) }
        rejected.remove(target.id)
        face.rejectedPersonIDs = rejected.sorted().joined(separator: ",")
        face.personID = target.id
        face.clusterID = nil
        face.confirmed = true
        face.assignmentSource = "user"
        face.updatedAt = now
        if target.hidden {
            target.hidden = false
            target.updatedAt = now
        }
        // The old person's last face: hide them, as removing it does.
        if let old = snapshot.personID, old != target.id,
           !observations.contains(where: { $0 !== face && $0.personID == old }),
           let oldPerson = try? face.modelContext?.fetch(FetchDescriptor<Person>(predicate: #Predicate { $0.id == old })).first {
            oldPerson.hidden = true
            oldPerson.updatedAt = now
            snapshot.hiddenPersonID = old
        }
        return snapshot
    }

    /// Moves `face` to the person called `name`, joining someone who already
    /// has that name or creating them.
    @discardableResult
    static func reassign(_ face: FaceObservation, toName name: String, people: [Person], observations: [FaceObservation], context: ModelContext, now: Date = .now) -> Snapshot? {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if let existing = PeopleStoreActions.mergeCandidate(forName: value, people: people) {
            return reassign(face, to: existing, observations: observations, now: now)
        }
        let person = Person(name: value, createdAt: now, updatedAt: now)
        context.insert(person)
        var snapshot = reassign(face, to: person, observations: observations, now: now)
        snapshot?.createdPersonID = person.id
        return snapshot
    }

    static func restore(_ snapshot: Snapshot, context: ModelContext, now: Date = .now) {
        let faceID = snapshot.faceID
        guard let face = try? context.fetch(FetchDescriptor<FaceObservation>(predicate: #Predicate { $0.id == faceID })).first else { return }
        let people = (try? context.fetch(FetchDescriptor<Person>())) ?? []
        // A merge since then may have removed the old person; leave the face
        // where it is rather than pointing it at nobody.
        if let old = snapshot.personID, !people.contains(where: { $0.id == old }) { return }
        face.personID = snapshot.personID
        face.clusterID = snapshot.clusterID
        face.confirmed = snapshot.confirmed
        face.assignmentSource = snapshot.assignmentSource
        face.rejectedPersonIDs = snapshot.rejectedPersonIDs
        face.updatedAt = now
        if let hidden = snapshot.hiddenPersonID, let person = people.first(where: { $0.id == hidden }) {
            person.hidden = false
            person.updatedAt = now
        }
        if let created = snapshot.createdPersonID, let person = people.first(where: { $0.id == created }) {
            let others = ((try? context.fetch(FetchDescriptor<FaceObservation>())) ?? []).filter { $0.personID == created }
            if others.allSatisfy({ $0 === face }) { context.delete(person) }
        }
    }

    static func message(movedTo name: String) -> String {
        String(localized: "Moved the face to \(name)")
    }
}
