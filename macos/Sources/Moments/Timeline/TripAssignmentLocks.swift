import Foundation

/// Photos someone put in a trip (or took out of one) by hand. Changing a
/// trip's dates re-sorts photos automatically, but never these. Kept on this
/// Mac for now; it moves into the shared store with the next schema change.
enum TripAssignmentLocks {
    static let defaultsKey = "moments.trip.lockedItemIDs"

    static func lock(_ itemID: String, defaults: UserDefaults = .standard) {
        var ids = lockedIDs(defaults: defaults)
        guard ids.insert(itemID).inserted else { return }
        defaults.set(Array(ids).sorted(), forKey: defaultsKey)
    }

    static func isLocked(_ itemID: String, defaults: UserDefaults = .standard) -> Bool {
        lockedIDs(defaults: defaults).contains(itemID)
    }

    static func lockedIDs(defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: defaultsKey) ?? [])
    }
}

/// The photo chosen as a trip's cover, by trip id. Kept on this Mac for now,
/// like the locks above.
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
