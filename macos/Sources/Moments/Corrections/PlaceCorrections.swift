import Foundation
import SwiftData

extension Place {
    /// This person's own name for the place, from Rename or Merge in Edit
    /// Places. It is a place-wide override (no photo), so imports, which only
    /// write the place's own `name`, never undo it, and new photos of the
    /// same place pick it up.
    var localNameOverride: PlaceOverride? {
        overrides.first { $0.accountID == MomentsAccount.localID && $0.mediaID == nil }
    }

    var correctedName: String? {
        let value = localNameOverride?.nameOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }
}

/// Places as the person sees them: by name. Two places with the same name
/// are one place in the filters and the Map, so merging places is giving them
/// one name, and nothing is ever deleted.
enum PlaceNames {
    /// Filter ids for a name start with this; older place-id filters still work.
    static let optionPrefix = "name:"

    /// One place name and everything listed under it.
    struct Group: Identifiable, Equatable {
        let key: String
        var name: String
        var itemIDs: [String]
        var id: String { optionPrefix + key }
    }

    /// Names compare without case, width or surrounding spaces, so "Kyoto",
    /// "kyoto " and "ｋｙｏｔｏ" are one place.
    static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    /// The name a photo is listed under: its own correction, else its place's.
    static func listedName(of item: MediaItem) -> String? {
        item.namedPlace
    }

    /// Every place name in `items`, most photos first within equal names'
    /// spellings, sorted by name.
    static func groups(for items: [MediaItem]) -> [Group] {
        var groups: [String: Group] = [:]
        var spellings: [String: [String: Int]] = [:]
        for item in items {
            guard let name = listedName(of: item) else { continue }
            let key = Self.key(name)
            guard !key.isEmpty else { continue }
            spellings[key, default: [:]][name, default: 0] += 1
            groups[key, default: Group(key: key, name: name, itemIDs: [])].itemIDs.append(item.id)
        }
        for (key, counts) in spellings {
            if let name = counts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key { groups[key]?.name = name }
        }
        return groups.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func options(for items: [MediaItem]) -> [LibraryPlaceOption] {
        groups(for: items).map { LibraryPlaceOption(id: $0.id, name: $0.name) }
    }

    /// True when the photo is listed under the name `key`: its own correction
    /// says so, or (without one) its place or a parent has that name.
    static func matches(_ item: MediaItem, key: String) -> Bool {
        if let override = item.placeOverrideName?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return Self.key(override) == key
        }
        var current = item.place
        var depth = 0
        while let place = current, depth < 4 {
            if let name = PlaceDisplayName.ownName(of: place), Self.key(name) == key { return true }
            current = place.parent
            depth += 1
        }
        return false
    }

    /// The name-based filter id for a filter saved before places were listed
    /// by name: a place id or "override:<name>".
    static func optionID(forLegacy id: String, items: [MediaItem]) -> String? {
        guard !id.isEmpty, !id.hasPrefix(optionPrefix) else { return nil }
        if id.hasPrefix("override:") {
            let key = Self.key(String(id.dropFirst("override:".count)))
            return key.isEmpty ? nil : optionPrefix + key
        }
        for item in items {
            var current = item.place
            var depth = 0
            while let place = current, depth < 4 {
                if place.id == id {
                    return PlaceDisplayName.resolvedName(of: place).map { optionPrefix + Self.key($0) }
                }
                current = place.parent
                depth += 1
            }
        }
        return nil
    }

    // MARK: Renaming and merging

    /// One place-name write, so Undo can put it back exactly.
    struct OverrideChange: Equatable {
        let overrideID: String
        let previousName: String?
        /// The override did not exist before; Undo removes it.
        let created: Bool
    }

    /// A smart group's place rule that followed a renamed name.
    struct RuleChange: Equatable {
        let groupID: String
        let ruleID: UUID
        let previousValue: String
    }

    /// One of this person's place descriptions that followed a renamed name.
    struct NoteChange: Equatable {
        let noteID: String
        let previousName: String
        let previousKey: String
    }

    /// Everything one rename or merge wrote.
    struct Changes: Equatable {
        var overrides: [OverrideChange] = []
        var rules: [RuleChange] = []
        var notes: [NoteChange] = []

        var isEmpty: Bool { overrides.isEmpty && rules.isEmpty && notes.isEmpty }

        mutating func append(_ other: Changes) {
            overrides += other.overrides
            rules += other.rules
            notes += other.notes
        }
    }

    /// Renames every place and photo listed under `key` to `newName`. Places
    /// get this person's place-wide name; photos with their own correction
    /// get the new name in it. Smart groups on the old name and this
    /// person's description of the place follow. Renaming to a name another
    /// place has merges them.
    @discardableResult
    static func rename(key: String, to newName: String, items: [MediaItem], context: ModelContext, now: Date = .now) -> Changes {
        let value = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return Changes() }
        var result = Changes()
        result.rules = moveGroupRules(from: key, to: Self.key(value), context: context, now: now)
        result.notes = movePlaceNotes(from: key, to: value, context: context, now: now)
        var changes: [OverrideChange] = []
        var renamedPlaceIDs = Set<String>()
        for item in items where matches(item, key: key) {
            if let override = item.localPlaceOverride,
               let name = override.nameOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                guard name != value else { continue }
                changes.append(OverrideChange(overrideID: override.id, previousName: override.nameOverride, created: false))
                override.nameOverride = value
                override.updatedAt = now
                override.updatedBy = MomentsAccount.localID
                item.updatedAt = now
                continue
            }
            // The place in the photo's chain that carries the name.
            var current = item.place
            var depth = 0
            while let place = current, depth < 4 {
                if let name = PlaceDisplayName.ownName(of: place), Self.key(name) == key {
                    if renamedPlaceIDs.insert(place.id).inserted, let change = setName(value, of: place, context: context, now: now) {
                        changes.append(change)
                    }
                    break
                }
                current = place.parent
                depth += 1
            }
        }
        result.overrides = changes
        return result
    }

    private static func moveGroupRules(from oldKey: String, to newKey: String, context: ModelContext, now: Date) -> [RuleChange] {
        guard oldKey != newKey else { return [] }
        var changes: [RuleChange] = []
        for group in (try? context.fetch(FetchDescriptor<UserGroup>())) ?? [] {
            var rules = group.rules
            var changed = false
            for index in rules.rules.indices where rules.rules[index].field == .place && rules.rules[index].value == optionPrefix + oldKey {
                changes.append(RuleChange(groupID: group.id, ruleID: rules.rules[index].id, previousValue: rules.rules[index].value))
                rules.rules[index].value = optionPrefix + newKey
                changed = true
            }
            if changed {
                group.rules = rules
                group.updatedAt = now
            }
        }
        return changes
    }

    /// This person's descriptions are found by place name, so they follow a
    /// rename, unless the new name already has one of theirs.
    private static func movePlaceNotes(from oldKey: String, to newName: String, context: ModelContext, now: Date) -> [NoteChange] {
        let notes = ((try? context.fetch(FetchDescriptor<PlaceNote>())) ?? []).filter { $0.authorAccountID == MomentsAccount.localID }
        let newNoteKey = PlaceNote.key(for: newName)
        guard !notes.contains(where: { $0.placeKey == newNoteKey }) else { return [] }
        var changes: [NoteChange] = []
        for note in notes where Self.key(note.placeName) == oldKey && note.placeKey != newNoteKey {
            changes.append(NoteChange(noteID: note.id, previousName: note.placeName, previousKey: note.placeKey))
            note.placeName = newName
            note.placeKey = newNoteKey
            note.updatedAt = now
            // One description per place: the first moved, the rest stay.
            break
        }
        return changes
    }

    /// Merges the places listed under `sourceKeys` into the one under
    /// `targetKey`: they all take its name.
    @discardableResult
    static func merge(_ sourceKeys: [String], into targetKey: String, items: [MediaItem], context: ModelContext, now: Date = .now) -> Changes {
        guard let target = groups(for: items).first(where: { $0.key == targetKey }) else { return Changes() }
        var changes = Changes()
        for source in sourceKeys where source != targetKey {
            changes.append(rename(key: source, to: target.name, items: items, context: context, now: now))
        }
        return changes
    }

    /// Gives a place this person's name for it. Its own name back removes the rename.
    private static func setName(_ value: String, of place: Place, context: ModelContext, now: Date) -> OverrideChange? {
        let canonical = place.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let newOverride: String? = value == canonical ? nil : value
        if let existing = place.localNameOverride {
            guard existing.nameOverride != newOverride else { return nil }
            let change = OverrideChange(overrideID: existing.id, previousName: existing.nameOverride, created: false)
            existing.nameOverride = newOverride
            existing.updatedAt = now
            existing.updatedBy = MomentsAccount.localID
            place.updatedAt = now
            return change
        }
        guard let newOverride else { return nil }
        let override = PlaceOverride(placeID: place.id, nameOverride: newOverride, updatedAt: now, updatedBy: MomentsAccount.localID, place: place)
        context.insert(override)
        place.updatedAt = now
        return OverrideChange(overrideID: override.id, previousName: nil, created: true)
    }

    static func restore(_ all: Changes, context: ModelContext, now: Date = .now) {
        let groups = (try? context.fetch(FetchDescriptor<UserGroup>())) ?? []
        for change in all.rules.reversed() {
            guard let group = groups.first(where: { $0.id == change.groupID }) else { continue }
            var rules = group.rules
            guard let index = rules.rules.firstIndex(where: { $0.id == change.ruleID }) else { continue }
            rules.rules[index].value = change.previousValue
            group.rules = rules
            group.updatedAt = now
        }
        let notes = (try? context.fetch(FetchDescriptor<PlaceNote>())) ?? []
        for change in all.notes.reversed() {
            guard let note = notes.first(where: { $0.id == change.noteID }) else { continue }
            note.placeName = change.previousName
            note.placeKey = change.previousKey
            note.updatedAt = now
        }
        let changes = all.overrides
        let ids = Array(Set(changes.map(\.overrideID)))
        let overrides = (try? context.fetch(FetchDescriptor<PlaceOverride>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
        let byID = Dictionary(overrides.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Newest first, so a name written twice goes back to the first one.
        for change in changes.reversed() {
            guard let override = byID[change.overrideID] else { continue }
            if change.created {
                override.place?.updatedAt = now
                override.mediaItem?.updatedAt = now
                context.delete(override)
            } else {
                override.nameOverride = change.previousName
                override.updatedAt = now
                override.place?.updatedAt = now
                override.mediaItem?.updatedAt = now
            }
        }
    }
}
