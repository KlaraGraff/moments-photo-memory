import Foundation
import Observation
import SwiftUI

// MARK: - Group

/// A named group of people, such as Family or Friends. A person can be in
/// several groups.
///
/// Groups live in `UserDefaults`, not in the store: a group is a label the
/// owner puts on people, so this feature needs no schema change and no
/// migration. The name is the owner's own text and stays on this Mac.
struct PeopleGroup: Codable, Equatable, Identifiable {
    let id: String
    var name: String
}

// MARK: - Storage

/// The owner's groups and their members, stored beside the other People
/// preferences. Only opaque person IDs are written, never names or faces.
enum PeopleGroupStore {
    /// The groups, in display order, as a JSON array of `PeopleGroup`.
    static let groupsKey = "moments.people.groups"
    /// Group ID → person IDs, as JSON. Opaque IDs only.
    static let membersKey = "moments.people.groupMembers"
    /// Set when the three starting groups exist. Deleting groups never
    /// re-seeds them.
    static let seededKey = "moments.people.groupsSeeded"

    /// The three groups that exist after the first launch, in this order.
    private static var defaultNames: [String] {
        [String(localized: "Family"), String(localized: "Friends"), String(localized: "Work")]
    }

    /// The groups, seeding Family, Friends and Work once. Reading never
    /// duplicates a group the owner renamed or deleted.
    static func groups(defaults: UserDefaults = .standard) -> [PeopleGroup] {
        var stored = storedGroups(defaults)
        guard !defaults.bool(forKey: seededKey) else { return stored }
        let known = Set(stored.map { (group: PeopleGroup) -> String in group.name.lowercased() })
        for name in defaultNames where !known.contains(name.lowercased()) {
            stored.append(PeopleGroup(id: UUID().uuidString, name: name))
        }
        writeGroups(stored, defaults)
        defaults.set(true, forKey: seededKey)
        return stored
    }

    /// Adds a group at the end and returns it. An empty name is ignored by the
    /// caller's disabled button; it becomes "New group" here as a last resort.
    @discardableResult
    static func create(name: String, defaults: UserDefaults = .standard) -> PeopleGroup {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = PeopleGroup(
            id: UUID().uuidString,
            name: trimmed.isEmpty ? String(localized: "New group") : trimmed
        )
        var stored = storedGroups(defaults)
        stored.append(group)
        writeGroups(stored, defaults)
        return group
    }

    /// Renames a group. People keep their membership; an empty name is ignored.
    static func rename(_ groupID: String, to name: String, defaults: UserDefaults = .standard) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var stored = storedGroups(defaults)
        guard let index = stored.firstIndex(where: { (group: PeopleGroup) -> Bool in group.id == groupID }) else { return }
        stored[index].name = trimmed
        writeGroups(stored, defaults)
    }

    /// Deletes a group and its member list. The people themselves never are
    /// touched; they simply no longer carry this label.
    static func delete(_ groupID: String, defaults: UserDefaults = .standard) {
        var stored = storedGroups(defaults)
        guard stored.contains(where: { (group: PeopleGroup) -> Bool in group.id == groupID }) else { return }
        stored.removeAll { (group: PeopleGroup) -> Bool in group.id == groupID }
        writeGroups(stored, defaults)
        var members = storedMembers(defaults)
        if members.removeValue(forKey: groupID) != nil { writeMembers(members, defaults) }
    }

    /// The people in one group.
    static func members(of groupID: String, defaults: UserDefaults = .standard) -> Set<String> {
        storedMembers(defaults)[groupID] ?? []
    }

    /// The groups one person is in.
    static func groups(of personID: String, defaults: UserDefaults = .standard) -> Set<String> {
        let members = storedMembers(defaults)
        return Set(members.compactMap { (groupID: String, personIDs: Set<String>) -> String? in
            personIDs.contains(personID) ? groupID : nil
        })
    }

    /// Adds the person to the group, or takes them out when already in it.
    static func toggle(personID: String, in groupID: String, defaults: UserDefaults = .standard) {
        var members = storedMembers(defaults)
        var personIDs = members[groupID] ?? []
        if personIDs.contains(personID) {
            personIDs.remove(personID)
        } else {
            personIDs.insert(personID)
        }
        if personIDs.isEmpty {
            members.removeValue(forKey: groupID)
        } else {
            members[groupID] = personIDs
        }
        writeMembers(members, defaults)
    }

    /// Every group's members at once, so a view reads the defaults once.
    static func allMembers(defaults: UserDefaults = .standard) -> [String: Set<String>] {
        storedMembers(defaults)
    }

    // MARK: Raw storage

    private static func storedGroups(_ defaults: UserDefaults) -> [PeopleGroup] {
        guard let data = defaults.data(forKey: groupsKey),
              let decoded = try? JSONDecoder().decode([PeopleGroup].self, from: data)
        else { return [] }
        return decoded
    }

    private static func writeGroups(_ groups: [PeopleGroup], _ defaults: UserDefaults) {
        guard !groups.isEmpty else {
            defaults.removeObject(forKey: groupsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(groups) else { return }
        defaults.set(data, forKey: groupsKey)
    }

    private static func storedMembers(_ defaults: UserDefaults) -> [String: Set<String>] {
        guard let data = defaults.data(forKey: membersKey),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return [:] }
        return decoded.mapValues { (personIDs: [String]) -> Set<String> in Set(personIDs) }
    }

    private static func writeMembers(_ members: [String: Set<String>], _ defaults: UserDefaults) {
        guard !members.isEmpty else {
            defaults.removeObject(forKey: membersKey)
            return
        }
        let sorted = members.mapValues { (personIDs: Set<String>) -> [String] in personIDs.sorted() }
        guard let data = try? JSONEncoder().encode(sorted) else { return }
        defaults.set(data, forKey: membersKey)
    }
}
