import Foundation

/// How a device shows the person behind an account ID.
public enum SyncAuthorRole: String, Sendable, Equatable {
    case me
    case partner
    /// An account that is neither person on the share (for example one that
    /// was removed). The record is kept; the UI shows no name.
    case unresolved
}

/// Translates account IDs between this device's spelling and the wire.
///
/// On every device the local models call that device's person `local-me`
/// (`MomentsAccount.localID` in the app), so nothing written before sharing
/// has to be rewritten and every "is this mine?" check keeps working. On the
/// wire the same person is their iCloud user record name. A partner's
/// records arrive with the partner's record name and keep it locally.
public struct SyncAccountMap: Equatable, Sendable {
    public static let localAlias = "local-me"

    /// This device's iCloud user record name (`CKContainer.fetchUserRecordID`).
    public let currentAccountID: String
    /// The other person on the share, once known.
    public var partnerAccountID: String?

    public init(currentAccountID: String, partnerAccountID: String? = nil) {
        precondition(currentAccountID != Self.localAlias, "the wire account must be a real account ID")
        self.currentAccountID = currentAccountID
        self.partnerAccountID = partnerAccountID
    }

    public func toWire(_ local: String) -> String {
        local == Self.localAlias ? currentAccountID : local
    }

    public func fromWire(_ wire: String) -> String {
        wire == currentAccountID ? Self.localAlias : wire
    }

    public func role(of localAccountID: String?) -> SyncAuthorRole {
        guard let localAccountID else { return .me }
        if localAccountID == Self.localAlias || localAccountID == currentAccountID { return .me }
        if partnerAccountID == nil || localAccountID == partnerAccountID { return .partner }
        return .unresolved
    }

    public func canEdit(_ record: SyncRecord) -> Bool {
        switch record.type.spec.ownership {
        case .shared:
            return true
        case .appendOnly:
            // Written once by its editor; nil is a revision kept before sharing.
            return record.editor.map { role(of: $0) == .me } ?? true
        case .perAccount(let field), .authored(let field):
            let owner = record.fields[field]?.stringValue
            let nilMeansLocal = record.type.spec.field(field)?.nilMeansLocal ?? false
            if owner == nil { return nilMeansLocal }
            return role(of: owner) == .me
        }
    }

    /// The record in its wire spelling: account fields and per-person record
    /// IDs carry the real account.
    public func toWire(_ record: SyncRecord) -> SyncRecord {
        var wire = record
        wire.id = wireID(record.id, type: record.type)
        for field in record.type.spec.accountFields {
            if let value = record.fields[field.name]?.stringValue {
                wire.fields[field.name] = .string(toWire(value))
            } else if field.nilMeansLocal {
                wire.fields[field.name] = .string(currentAccountID)
            }
        }
        for field in record.type.spec.references {
            if let target = field.target, let value = record.fields[field.name]?.stringValue {
                wire.fields[field.name] = .reference(wireID(value, type: target))
            }
        }
        return wire
    }

    public func fromWire(_ record: SyncRecord) -> SyncRecord {
        var local = SyncSchema.sanitized(record)
        local.id = localID(record.id, type: record.type)
        for field in record.type.spec.accountFields {
            if let value = local.fields[field.name]?.stringValue {
                local.fields[field.name] = .string(fromWire(value))
            }
        }
        for field in record.type.spec.references {
            if let target = field.target, let value = local.fields[field.name]?.stringValue {
                local.fields[field.name] = .reference(localID(value, type: target))
            }
        }
        return local
    }

    /// Favorites and personal place names are keyed `<owner>:<account>`.
    public func wireID(_ id: String, type: SyncRecordType) -> String {
        guard Self.isPerAccount(type) else { return id }
        let suffix = ":" + Self.localAlias
        guard id.hasSuffix(suffix) else { return id }
        return String(id.dropLast(suffix.count)) + ":" + currentAccountID
    }

    public func localID(_ id: String, type: SyncRecordType) -> String {
        guard Self.isPerAccount(type) else { return id }
        let suffix = ":" + currentAccountID
        guard id.hasSuffix(suffix) else { return id }
        return String(id.dropLast(suffix.count)) + ":" + Self.localAlias
    }

    static func isPerAccount(_ type: SyncRecordType) -> Bool {
        if case .perAccount = type.spec.ownership { return true }
        return false
    }
}

/// CloudKit record names: ASCII, at most 255 bytes. Moments IDs are UUIDs or
/// short generated strings, but a trip ID can come from a place name, so an
/// unsafe ID is replaced by a digest and the real ID rides in
/// ``SyncSchema/idField``.
public enum SyncRecordName {
    public static let maxLength = 200

    /// CloudKit record names are unique within a zone across all record
    /// types, and two types can share an ID (a favorite and a personal place
    /// name are both "photo:person"), so every name starts with its type.
    public static func make(type: SyncRecordType, id: String) -> String {
        let plain = type.rawValue + "-" + id
        if isSafe(id), plain.utf8.count <= maxLength { return plain }
        return "h-" + type.rawValue + "-" + SyncDigest.hex(id) + "-" + SyncDigest.hex(String(id.reversed()))
    }

    /// The ID inside a name `make` built without hashing, or nil for a
    /// hashed name (looked up in the saved name map instead).
    public static func id(fromPlain name: String, type: SyncRecordType) -> String? {
        let prefix = type.rawValue + "-"
        guard name.hasPrefix(prefix) else { return nil }
        let id = String(name.dropFirst(prefix.count))
        return isSafe(id) ? id : nil
    }

    public static func isSafe(_ id: String) -> Bool {
        guard !id.isEmpty, id.utf8.count <= maxLength, !id.hasPrefix("_"), !id.hasPrefix("h-") else { return false }
        return id.unicodeScalars.allSatisfy { (scalar: Unicode.Scalar) -> Bool in
            switch scalar.value {
            case 0x61...0x7A, 0x41...0x5A, 0x30...0x39: return true
            case 0x2D, 0x5F, 0x2E, 0x3A: return true // - _ . :
            default: return false
            }
        }
    }
}
