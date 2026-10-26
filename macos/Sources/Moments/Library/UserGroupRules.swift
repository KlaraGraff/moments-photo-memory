import Foundation
import SwiftData

/// The fields available to a smart group's rule editor. Person membership is
/// resolved through local FaceObservation records at evaluation time.
public enum UserGroupRuleField: String, Codable, CaseIterable, Hashable, Sendable {
    case place
    case trip
    case type
    case dateRange
    case hasMemory
    case tag
    case person
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
    static func matches(_ item: MediaItem, ruleSet: UserGroupRuleSet, calendar: Calendar = .current) -> Bool {
        guard !ruleSet.rules.isEmpty else { return false }
        let results = ruleSet.rules.map { matches(item, rule: $0, calendar: calendar) }
        switch ruleSet.mode {
        case .all: return results.allSatisfy { $0 }
        case .any: return results.contains { $0 }
        }
    }

    static func matches(
        _ item: MediaItem,
        ruleSet: UserGroupRuleSet,
        observations: [FaceObservation],
        personIDsByMediaID: [String: Set<String>]? = nil,
        calendar: Calendar = .current
    ) -> Bool {
        guard !ruleSet.rules.isEmpty else { return false }
        let ids = personIDsByMediaID?[item.id] ?? observations.reduce(into: Set<String>()) { ids, observation in
            if observation.mediaID == item.id, let personID = observation.personID { ids.insert(personID) }
        }
        let results = ruleSet.rules.map { rule in
            if rule.field == .person {
                let result = ids.contains(rule.value)
                return rule.op == .equals ? result : !result
            }
            return matches(item, rule: rule, calendar: calendar)
        }
        switch ruleSet.mode {
        case .all: return results.allSatisfy { $0 }
        case .any: return results.contains { $0 }
        }
    }

    static func matchingItems(_ items: [MediaItem], ruleSet: UserGroupRuleSet, calendar: Calendar = .current) -> [MediaItem] {
        items.filter { matches($0, ruleSet: ruleSet, calendar: calendar) }
    }

    static func matchingItems(_ items: [MediaItem], ruleSet: UserGroupRuleSet, observations: [FaceObservation], personIDsByMediaID: [String: Set<String>]? = nil, calendar: Calendar = .current) -> [MediaItem] {
        let index = personIDsByMediaID ?? makePersonIndex(observations)
        return items.filter { matches($0, ruleSet: ruleSet, observations: observations, personIDsByMediaID: index, calendar: calendar) }
    }

    /// Computes the current smart-group contents while retaining explicit
    /// exclusions stored in UserGroupItem. A manual group simply uses the
    /// persisted, non-excluded media IDs supplied by its caller.
    static func smartItems(
        from items: [MediaItem],
        ruleSet: UserGroupRuleSet,
        pinnedIDs: Set<String> = [],
        exclusions: Set<String> = [],
        calendar: Calendar = .current
    ) -> [MediaItem] {
        let matchingIDs = Set(matchingItems(items, ruleSet: ruleSet, calendar: calendar).map(\.id))
        let includedIDs = (matchingIDs.union(pinnedIDs)).subtracting(exclusions)
        var seen = Set<String>()
        return items.filter { includedIDs.contains($0.id) && seen.insert($0.id).inserted }
    }

    static func smartItems(
        from items: [MediaItem],
        ruleSet: UserGroupRuleSet,
        observations: [FaceObservation],
        personIDsByMediaID: [String: Set<String>]? = nil,
        pinnedIDs: Set<String> = [],
        exclusions: Set<String> = [],
        calendar: Calendar = .current
    ) -> [MediaItem] {
        let matchingIDs = Set(matchingItems(items, ruleSet: ruleSet, observations: observations, personIDsByMediaID: personIDsByMediaID, calendar: calendar).map(\.id))
        let includedIDs = (matchingIDs.union(pinnedIDs)).subtracting(exclusions)
        var seen = Set<String>()
        return items.filter { includedIDs.contains($0.id) && seen.insert($0.id).inserted }
    }

    static func visibleItems(
        for group: UserGroup,
        from items: [MediaItem],
        memberships: [UserGroupItem],
        observations: [FaceObservation] = [],
        personIDsByMediaID: [String: Set<String>]? = nil,
        calendar: Calendar = .current
    ) -> [MediaItem] {
        let groupMemberships = memberships.filter { $0.groupID == group.id }
        switch group.kind {
        case .manual:
            let ids = Set(groupMemberships.filter { !$0.excluded }.map(\.mediaID))
            var seen = Set<String>()
            return items.filter { ids.contains($0.id) && seen.insert($0.id).inserted }
        case .smart:
            let pinned = Set(groupMemberships.filter { !$0.excluded }.map(\.mediaID))
            let exclusions = Set(groupMemberships.filter(\.excluded).map(\.mediaID))
            return smartItems(from: items, ruleSet: group.rules, observations: observations, personIDsByMediaID: personIDsByMediaID, pinnedIDs: pinned, exclusions: exclusions, calendar: calendar)
        case .stack:
            return []
        }
    }

    static func makePersonIndex(_ observations: [FaceObservation]) -> [String: Set<String>] {
        observations.reduce(into: [:]) { result, observation in
            if let personID = observation.personID { result[observation.mediaID, default: []].insert(personID) }
        }
    }

    static func add(_ item: MediaItem, to group: UserGroup, memberships: [UserGroupItem], context: ModelContext) {
        let fresh = fetchMemberships(for: group.id, mediaID: item.id, context: context)
        if fresh.isEmpty == false {
            for membership in fresh { membership.excluded = false }
        } else {
            context.insert(UserGroupItem(groupID: group.id, mediaID: item.id))
        }
    }

    static func remove(_ item: MediaItem, from group: UserGroup, memberships: [UserGroupItem], context: ModelContext) {
        let fresh = fetchMemberships(for: group.id, mediaID: item.id, context: context)
        if group.kind == .smart {
            if fresh.isEmpty == false {
                for membership in fresh { membership.excluded = true }
            } else {
                context.insert(UserGroupItem(groupID: group.id, mediaID: item.id, excluded: true))
            }
        } else {
            for membership in fresh { context.delete(membership) }
        }
    }

    private static func fetchMemberships(for groupID: String, mediaID: String, context: ModelContext) -> [UserGroupItem] {
        let predicate = #Predicate<UserGroupItem> { membership in
            membership.groupID == groupID && membership.mediaID == mediaID
        }
        return (try? context.fetch(FetchDescriptor<UserGroupItem>(predicate: predicate))) ?? []
    }

    static func convertToManual(
        _ group: UserGroup,
        items: [MediaItem],
        memberships: [UserGroupItem],
        observations: [FaceObservation] = [],
        context: ModelContext
    ) {
        let matches = visibleItems(for: group, from: items, memberships: memberships, observations: observations)
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

    private static func matches(_ item: MediaItem, rule: UserGroupRule, calendar: Calendar) -> Bool {
        guard let criteria = UserGroupRuleSet().libraryCriteria(for: rule, calendar: calendar) else {
            return rule.op == .isNot
        }
        let result = LibraryFilterEngine.matches(item, criteria: criteria, calendar: calendar, hidesScreenshots: false)
        return rule.op == .equals ? result : !result
    }
}

extension UserGroupRuleSet {
    /// The subset represented by the Library's existing filter engine. This
    /// keeps date, place, type, and memory semantics aligned with LibraryView.
    func libraryCriteria(for rule: UserGroupRule, calendar: Calendar = .current) -> LibraryFilterCriteria? {
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
            guard let from = Self.localDayDate(rule.value, calendar: calendar) else { return nil }
            criteria.fromDate = from
            if let secondaryValue = rule.secondaryValue {
                guard let to = Self.localDayDate(secondaryValue, calendar: calendar) else { return nil }
                criteria.toDate = to
            }
        case .tag: criteria.tagID = rule.value
        case .person: criteria.personID = rule.value
        }
        return criteria
    }

    static func localDayKey(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private static func localDayDate(_ value: String, calendar: Calendar) -> Date? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
