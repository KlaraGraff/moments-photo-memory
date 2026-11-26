import Foundation

/// Photos someone put in a trip (or took out of one) by hand. Changing a
/// trip's dates re-sorts photos automatically, but never these. A library
/// decision (`LibraryDecisions`), kept in the local store.
enum TripAssignmentLocks {
    static let defaultsKey = "moments.trip.lockedItemIDs"

    /// Where locks and covers live: the library's own store. UI tests open an
    /// in-memory store, so running them never touches this Mac's choices.
    static var store: any DecisionStore { LibraryDecisions.shared }

    static func lock(_ itemID: String, defaults: any DecisionStore = TripAssignmentLocks.store) {
        var ids = lockedIDs(defaults: defaults)
        guard ids.insert(itemID).inserted else { return }
        defaults.set(Array(ids).sorted(), forKey: defaultsKey)
    }

    static func isLocked(_ itemID: String, defaults: any DecisionStore = TripAssignmentLocks.store) -> Bool {
        lockedIDs(defaults: defaults).contains(itemID)
    }

    static func lockedIDs(defaults: any DecisionStore = TripAssignmentLocks.store) -> Set<String> {
        Set(defaults.stringArray(forKey: defaultsKey) ?? [])
    }
}

/// The photo chosen as a trip's cover, by trip id, as JSON. A library
/// decision, like the locks above.
enum TripCoverChoice {
    static let defaultsKey = "moments.trip.coverItemIDs"

    static func decode(_ stored: String) -> [String: String] {
        guard let data = stored.data(using: .utf8),
              let value = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return value
    }

    static func encode(_ choices: [String: String]) -> String {
        guard let data = try? JSONEncoder().encode(choices) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
