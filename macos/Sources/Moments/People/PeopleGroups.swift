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

// MARK: - View model

/// The chips' selection and the owner's groups, so the screen holds one piece
/// of state. Every change goes through the store and reloads once.
@Observable
final class PeopleGroupsModel {
    private(set) var groups: [PeopleGroup] = []
    private(set) var members: [String: Set<String>] = [:]
    /// nil shows every named person.
    var selectedGroupID: String?
    var isCreatingGroup = false
    var newGroupName = ""
    /// The person a "New group…" from their menu should also join.
    var newGroupForPersonID: String?
    var renamingGroupID: String?
    var renameName = ""
    var deletingGroupID: String?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        reload()
    }

    func reload() {
        groups = PeopleGroupStore.groups(defaults: defaults)
        members = PeopleGroupStore.allMembers(defaults: defaults)
        if let selected = selectedGroupID,
           !groups.contains(where: { (group: PeopleGroup) -> Bool in group.id == selected }) {
            selectedGroupID = nil
        }
    }

    var trimmedNewGroupName: String {
        newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedRenameName: String {
        renameName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func count(of groupID: String, among personIDs: Set<String>) -> Int {
        (members[groupID] ?? []).intersection(personIDs).count
    }

    func isMember(personID: String, of groupID: String) -> Bool {
        members[groupID]?.contains(personID) ?? false
    }

    /// Tapping a chip shows only that group; "All" passes nil.
    func select(_ groupID: String?) {
        selectedGroupID = groupID
    }

    func setMember(_ member: Bool, personID: String, in groupID: String) {
        guard member != isMember(personID: personID, of: groupID) else { return }
        PeopleGroupStore.toggle(personID: personID, in: groupID, defaults: defaults)
        reload()
    }

    // MARK: New group

    func beginCreatingGroup(for personID: String?) {
        newGroupName = ""
        newGroupForPersonID = personID
        isCreatingGroup = true
    }

    func cancelCreatingGroup() {
        isCreatingGroup = false
        newGroupName = ""
        newGroupForPersonID = nil
    }

    /// Creates the typed group and, when the request came from a person's
    /// menu, puts that person in it.
    func commitNewGroup() {
        let name = trimmedNewGroupName
        guard !name.isEmpty else { return }
        let group = PeopleGroupStore.create(name: name, defaults: defaults)
        if let personID = newGroupForPersonID {
            PeopleGroupStore.toggle(personID: personID, in: group.id, defaults: defaults)
        }
        cancelCreatingGroup()
        reload()
    }

    // MARK: Rename

    func beginRename(_ group: PeopleGroup) {
        renameName = group.name
        renamingGroupID = group.id
    }

    func cancelRename() {
        renamingGroupID = nil
        renameName = ""
    }

    func commitRename() {
        guard let groupID = renamingGroupID else { return }
        PeopleGroupStore.rename(groupID, to: renameName, defaults: defaults)
        cancelRename()
        reload()
    }

    // MARK: Delete

    func requestDelete(_ group: PeopleGroup) {
        deletingGroupID = group.id
    }

    func cancelDelete() {
        deletingGroupID = nil
    }

    /// Deletes the group and its member list; people stay where they are.
    func commitDelete() {
        guard let groupID = deletingGroupID else { return }
        PeopleGroupStore.delete(groupID, defaults: defaults)
        deletingGroupID = nil
        if selectedGroupID == groupID { selectedGroupID = nil }
        reload()
    }
}

// MARK: - Chips

/// The row above the Named grid: everyone, one chip per group, and a way to
/// add a group. The selection lives in the model so "Put in group" on a card
/// and this row always agree.
struct PeopleGroupChips: View {
    /// The selection is `selectedGroupID`: nil shows everyone.
    @Bindable var model: PeopleGroupsModel
    /// The named people on the page; only they are counted.
    let namedPersonIDs: Set<String>

    var body: some View {
        let allCount: Int = namedPersonIDs.count
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(
                    Text(String(localized: "All \(allCount)")),
                    selected: model.selectedGroupID == nil,
                    identifier: "people.groups.all"
                ) {
                    model.select(nil)
                }
                ForEach(model.groups) { group in
                    chip(
                        Text(verbatim: "\(group.name) \(model.count(of: group.id, among: namedPersonIDs))"),
                        selected: model.selectedGroupID == group.id,
                        identifier: "people.groups.\(group.id)"
                    ) {
                        model.select(group.id)
                    }
                    .contextMenu {
                        Button(String(localized: "Rename…")) { model.beginRename(group) }
                        Button(String(localized: "Delete group"), role: .destructive) { model.requestDelete(group) }
                    }
                }
                Button { model.beginCreatingGroup(for: nil) } label: {
                    chipLabel(Text(String(localized: "+ New group")), selected: false)
                }
                .buttonStyle(.plain)
                .help(String(localized: "New group"))
                .accessibilityIdentifier("people.groups.new")
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 1)
        }
        .accessibilityIdentifier("people.groups")
        .alert(String(localized: "New group"), isPresented: creatingBinding) {
            TextField(String(localized: "Group name"), text: $model.newGroupName)
            Button(String(localized: "Save")) { model.commitNewGroup() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.trimmedNewGroupName.isEmpty)
            Button(String(localized: "Cancel"), role: .cancel) { model.cancelCreatingGroup() }
        }
        .alert(String(localized: "Rename"), isPresented: renamingBinding) {
            TextField(String(localized: "Group name"), text: $model.renameName)
            Button(String(localized: "Save")) { model.commitRename() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.trimmedRenameName.isEmpty)
            Button(String(localized: "Cancel"), role: .cancel) { model.cancelRename() }
        }
        .alert(String(localized: "Delete group"), isPresented: deletingBinding) {
            Button(String(localized: "Delete"), role: .destructive) { model.commitDelete() }
            Button(String(localized: "Cancel"), role: .cancel) { model.cancelDelete() }
        }
    }

    private func chip(_ title: Text, selected: Bool, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            chipLabel(title, selected: selected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? AccessibilityTraits.isSelected : AccessibilityTraits())
        .accessibilityIdentifier(identifier)
    }

    private func chipLabel(_ title: Text, selected: Bool) -> some View {
        title
            .font(.callout)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(selected ? Paper.accent : Paper.well, in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? Color.clear : Paper.muted.opacity(0.28), lineWidth: 1))
            .foregroundStyle(selected ? Color.white : Paper.ink)
            .contentShape(Capsule())
    }

    // MARK: Bindings

    private var creatingBinding: Binding<Bool> {
        Binding(
            get: { model.isCreatingGroup },
            set: { (isOn: Bool) in if !isOn { model.cancelCreatingGroup() } }
        )
    }

    private var renamingBinding: Binding<Bool> {
        Binding(
            get: { model.renamingGroupID != nil },
            set: { (isOn: Bool) in if !isOn { model.cancelRename() } }
        )
    }

    private var deletingBinding: Binding<Bool> {
        Binding(
            get: { model.deletingGroupID != nil },
            set: { (isOn: Bool) in if !isOn { model.cancelDelete() } }
        )
    }
}
