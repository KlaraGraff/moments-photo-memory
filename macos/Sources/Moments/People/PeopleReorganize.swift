import Foundation
import SwiftData

/// The reset behind the People "reorganize" button: everything the owner did
/// not confirm goes back to a pending state, so the next scan groups it again.
///
/// Kept: named people and their faces (hidden or not), and the "no" answers.
/// Reset: unnamed groups, loose faces, ignored unnamed groups and every skipped
/// or open question.
enum PeopleReorganize {
    /// Releases every face that is not on a named person and deletes the
    /// unnamed people left without faces. Returns how many faces were released.
    @MainActor
    static func reset(context: ModelContext, defaults: UserDefaults = .standard) throws -> Int {
        let people: [Person] = try context.fetch(FetchDescriptor<Person>())
        var namedPersonIDs = Set<String>()
        namedPersonIDs.reserveCapacity(people.count)
        for person in people where isNamed(person) {
            namedPersonIDs.insert(person.id)
        }

        let faces: [FaceObservation] = try context.fetch(FetchDescriptor<FaceObservation>())
        var released = 0
        for face in faces {
            // A face on a named person keeps its person, its state and its
            // group; a hidden person counts as named.
            if let personID = face.personID, namedPersonIDs.contains(personID) { continue }
            // A loose face, or one on a group the owner never named, becomes a
            // pending cluster of its own: the next scan groups it again. The
            // "no" answers on it stay as they are.
            face.personID = nil
            face.clusterID = "pending-\(face.id)"
            face.confirmed = false
            face.assignmentSource = "auto"
            face.updatedAt = .now
            released += 1
        }

        // Every face off a named person was released above, so an unnamed
        // person owns no face any more and its record would only show up as an
        // empty, ignored card.
        for person in people where !namedPersonIDs.contains(person.id) {
            context.delete(person)
        }

        if context.hasChanges { try context.save() }

        // Skipped and open questions are meaningless after the regrouping; the
        // "no" answers and the picked key faces stay the owner's words.
        defaults.removeObject(forKey: PeopleStoreActions.questionsKey)
        // Zero makes the next start regroup once, whatever rule ran before.
        defaults.set(0, forKey: PeopleScanStore.groupingVersionKey)
        return released
    }

    /// A person is named as soon as its trimmed name is not empty. Anything
    /// else is a machine group the owner has not named yet.
    static func isNamed(_ person: Person) -> Bool {
        guard let name = person.name else { return false }
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
