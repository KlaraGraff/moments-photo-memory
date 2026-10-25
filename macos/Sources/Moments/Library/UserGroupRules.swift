import Foundation
import SwiftData

/// The fields available to a smart group's rule editor. Person is intentionally
/// omitted until MediaItem has a person field.
// TODO(#31): add a person rule when the sharing/person model lands.
public enum UserGroupRuleField: String, Codable, CaseIterable, Hashable, Sendable {
    case place
    case trip
    case type
    case dateRange
    case hasMemory
    case tag
}

public enum UserGroupRuleOperator: String, Codable, CaseIterable, Hashable, Sendable {
    case equals = "is"
    case isNot
}

public struct UserGroupRule: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var field: UserGroupRuleField
    public var op: UserGroupRuleOperator
    public var value: String
    /// Used by dateRange as an inclusive end date in `yyyy-MM-dd` format.
    public var secondaryValue: String?

    public init(
        id: UUID = UUID(),
        field: UserGroupRuleField,
        op: UserGroupRuleOperator = .equals,
        value: String,
        secondaryValue: String? = nil
    ) {
        self.id = id
        self.field = field
        self.op = op
        self.value = value
        self.secondaryValue = secondaryValue
    }
}

public struct UserGroupRuleSet: Codable, Equatable, Sendable {
    public enum MatchMode: String, Codable, Hashable, Sendable { case all, any }

    public var mode: MatchMode
    public var rules: [UserGroupRule]

    public init(mode: MatchMode = .all, rules: [UserGroupRule] = []) {
        self.mode = mode
        self.rules = rules
    }
}

enum UserGroupRuleEngine {
    static func canDelete(_ group: UserGroup, accountID: String = MomentsAccount.localID) -> Bool {
        group.ownerAccountID == accountID
    }
    static func matches(_ item: MediaItem, ruleSet: UserGroupRuleSet) -> Bool {
        guard !ruleSet.rules.isEmpty else { return true }
        let results = ruleSet.rules.map { matches(item, rule: $0) }
        switch ruleSet.mode {
        case .all: return results.allSatisfy { $0 }
        case .any: return results.contains { $0 }
        }
    }

    static func matchingItems(_ items: [MediaItem], ruleSet: UserGroupRuleSet) -> [MediaItem] {
        items.filter { matches($0, ruleSet: ruleSet) }
    }

    /// Computes the current smart-group contents while retaining explicit
    /// exclusions stored in UserGroupItem. A manual group simply uses the
    /// persisted, non-excluded media IDs supplied by its caller.
    static func smartItems(
        from items: [MediaItem],
        ruleSet: UserGroupRuleSet,
        exclusions: Set<String> = []
    ) -> [MediaItem] {
        matchingItems(items, ruleSet: ruleSet).filter { !exclusions.contains($0.id) }
    }

    static func visibleItems(
        for group: UserGroup,
        from items: [MediaItem],
        memberships: [UserGroupItem]
    ) -> [MediaItem] {
        let groupMemberships = memberships.filter { $0.groupID == group.id }
        switch group.kind {
        case .manual:
            let ids = Set(groupMemberships.filter { !$0.excluded }.map(\.mediaID))
            return items.filter { ids.contains($0.id) }
        case .smart:
            let exclusions = Set(groupMemberships.filter(\.excluded).map(\.mediaID))
            return smartItems(from: items, ruleSet: group.rules, exclusions: exclusions)
        }
    }

    static func add(_ item: MediaItem, to group: UserGroup, memberships: [UserGroupItem], context: ModelContext) {
        if let membership = memberships.first(where: { $0.groupID == group.id && $0.mediaID == item.id }) {
            membership.excluded = false
            return
        }
        context.insert(UserGroupItem(groupID: group.id, mediaID: item.id))
    }

    static func remove(_ item: MediaItem, from group: UserGroup, memberships: [UserGroupItem], context: ModelContext) {
        if group.kind == .smart {
            if let membership = memberships.first(where: { $0.groupID == group.id && $0.mediaID == item.id }) {
                membership.excluded = true
            } else {
                context.insert(UserGroupItem(groupID: group.id, mediaID: item.id, excluded: true))
            }
        } else if let membership = memberships.first(where: { $0.groupID == group.id && $0.mediaID == item.id }) {
            context.delete(membership)
        }
    }

    static func convertToManual(_ group: UserGroup, items: [MediaItem], memberships: [UserGroupItem], context: ModelContext) {
        let matches = visibleItems(for: group, from: items, memberships: memberships)
        for membership in memberships where membership.groupID == group.id {
            context.delete(membership)
        }
        for item in matches {
            context.insert(UserGroupItem(groupID: group.id, mediaID: item.id))
        }
        group.kind = .manual
        group.rules = UserGroupRuleSet()
        group.updatedAt = .now
    }

    private static func matches(_ item: MediaItem, rule: UserGroupRule) -> Bool {
        guard let criteria = UserGroupRuleSet().libraryCriteria(for: rule) else {
            return rule.op == .isNot
        }
        let result = LibraryFilterEngine.filteredItems([item], by: criteria).contains { $0.id == item.id }
        return rule.op == .equals ? result : !result
    }
}

extension UserGroupRuleSet {
    /// The subset represented by the Library's existing filter engine. This
    /// keeps date, place, type, and memory semantics aligned with LibraryView.
    func libraryCriteria(for rule: UserGroupRule) -> LibraryFilterCriteria? {
        var criteria = LibraryFilterCriteria.default
        switch rule.field {
        case .place: criteria.placeID = rule.value
        case .trip: criteria.tripKey = rule.value
        case .type:
            guard let type = LibraryMediaTypeFilter(rawValue: rule.value) else { return nil }
            criteria.mediaType = type
        case .hasMemory:
            criteria.memoryFilter = rule.value.lowercased() == "true" ? .hasMemory : .noMemory
        case .dateRange:
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withFullDate]
            guard let from = formatter.date(from: rule.value) else { return nil }
            criteria.fromDate = from
            if let secondaryValue = rule.secondaryValue {
                guard let to = formatter.date(from: secondaryValue) else { return nil }
                criteria.toDate = to
            }
        case .tag: criteria.tagID = rule.value
        }
        return criteria
    }
}
