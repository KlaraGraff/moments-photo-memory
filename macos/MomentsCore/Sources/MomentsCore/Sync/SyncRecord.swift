import Foundation

// The platform-neutral shape of one synced record.
//
// The CloudKit adapter in the app converts these to and from `CKRecord`; the
// SwiftData coders in the app convert them to and from the local models. Keeping
// the shape here means the merge rules, the pending-change queue and the
// sharing scope are tested on Linux, and a future iPhone app reuses them as is.

/// One field value. A field that is absent from ``SyncRecord/fields`` is nil.
public enum SyncValue: Equatable, Hashable, Sendable, Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case date(Date)
    case data(Data)
    /// The stable ID of another record; its type comes from the schema.
    case reference(String)
    /// A downscaled preview stored next to the record (a `CKAsset` in CloudKit).
    case asset(SyncAssetRef)

    public var stringValue: String? {
        switch self {
        case .string(let value), .reference(let value): return value
        default: return nil
        }
    }

    public var dateValue: Date? {
        if case .date(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        if case .int(let value) = self { return value }
        return nil
    }

    public var kind: SyncFieldKind {
        switch self {
        case .string: return .string
        case .int: return .int
        case .double: return .double
        case .bool: return .bool
        case .date: return .date
        case .data: return .data
        case .reference: return .reference
        case .asset: return .asset
        }
    }

    /// A stable text form used for deterministic tie-breaks and digests.
    var canonicalText: String {
        switch self {
        case .string(let value): return "s:" + value
        case .int(let value): return "i:" + String(value)
        case .double(let value): return "d:" + String(value.bitPattern)
        case .bool(let value): return value ? "b:1" : "b:0"
        case .date(let value): return "t:" + String(value.timeIntervalSince1970.bitPattern)
        case .data(let value): return "x:" + value.base64EncodedString()
        case .reference(let value): return "r:" + value
        case .asset(let value): return "a:" + value.sha256 + ":" + String(value.byteCount)
        }
    }
}

/// The checksum and size of a preview image. The bytes themselves live in a
/// file the app manages; CloudKit carries them as a `CKAsset`.
public struct SyncAssetRef: Equatable, Hashable, Sendable, Codable {
    public var sha256: String
    public var byteCount: Int
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(sha256: String, byteCount: Int, pixelWidth: Int, pixelHeight: Int) {
        self.sha256 = sha256
        self.byteCount = byteCount
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

public struct SyncRecordKey: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public var type: SyncRecordType
    public var id: String

    public init(_ type: SyncRecordType, _ id: String) {
        self.type = type
        self.id = id
    }

    public static func < (lhs: SyncRecordKey, rhs: SyncRecordKey) -> Bool {
        if lhs.type.uploadRank != rhs.type.uploadRank { return lhs.type.uploadRank < rhs.type.uploadRank }
        if lhs.type != rhs.type { return lhs.type.rawValue < rhs.type.rawValue }
        return lhs.id < rhs.id
    }

    public var description: String { "\(type.rawValue)/\(id)" }
}

/// One record in its local spelling: account fields say `local-me` for the
/// person on this device. ``SyncAccountMap`` translates to and from the wire.
public struct SyncRecord: Equatable, Sendable, Codable {
    public var type: SyncRecordType
    public var id: String
    public var fields: [String: SyncValue]

    public init(type: SyncRecordType, id: String, fields: [String: SyncValue] = [:]) {
        self.type = type
        self.id = id
        self.fields = fields
    }

    public var key: SyncRecordKey { SyncRecordKey(type, id) }

    public subscript(field: String) -> SyncValue? {
        get { fields[field] }
        set { fields[field] = newValue }
    }

    /// When the record last changed, from its type's stamp field.
    public var stamp: Date? { fields[type.spec.stampField]?.dateValue }

    /// Who made the last change, from its type's editor field if it has one.
    public var editor: String? { type.spec.editorField.flatMap { fields[$0]?.stringValue } }

    /// A stable digest of every field, independent of dictionary order.
    public var digest: String {
        let text = fields.keys.sorted().map { "\($0)=\(fields[$0]!.canonicalText)" }.joined(separator: "\u{1F}")
        return SyncDigest.hex(type.rawValue + "\u{1E}" + id + "\u{1E}" + text)
    }
}

/// FNV-1a, 64 bit. Not a security hash: used for deterministic IDs, record
/// names and shard selection, where Foundation on Linux has no CryptoKit.
public enum SyncDigest {
    public static func value(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    public static func hex(_ text: String) -> String {
        let raw = String(value(text), radix: 16)
        return String(repeating: "0", count: max(0, 16 - raw.count)) + raw
    }
}

// MARK: Typed access, used by the app's model coders

extension SyncRecord {
    public mutating func set(_ name: String, _ value: String?) { fields[name] = value.map { .string($0) } }
    public mutating func set(_ name: String, _ value: Int?) { fields[name] = value.map { .int($0) } }
    public mutating func set(_ name: String, _ value: Double?) { fields[name] = value.map { .double($0) } }
    public mutating func set(_ name: String, _ value: Bool?) { fields[name] = value.map { .bool($0) } }
    public mutating func set(_ name: String, _ value: Date?) { fields[name] = value.map { .date(SyncRecord.normalizedDate($0)) } }
    public mutating func set(_ name: String, _ value: Data?) { fields[name] = value.map { .data($0) } }
    public mutating func setReference(_ name: String, _ id: String?) { fields[name] = id.map { .reference($0) } }

    public func string(_ name: String) -> String? { fields[name]?.stringValue }
    public func int(_ name: String) -> Int? { fields[name]?.intValue }
    public func date(_ name: String) -> Date? { fields[name]?.dateValue }

    public func double(_ name: String) -> Double? {
        if case .double(let value)? = fields[name] { return value }
        return nil
    }

    public func bool(_ name: String) -> Bool? {
        if case .bool(let value)? = fields[name] { return value }
        return nil
    }

    public func data(_ name: String) -> Data? {
        if case .data(let value)? = fields[name] { return value }
        return nil
    }

    /// CloudKit keeps dates to the millisecond. Every date is rounded the
    /// same way before it is compared or sent, so a record that comes back
    /// from the server is not mistaken for a local change.
    public static func normalizedDate(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
    }

    /// The record with every date rounded to the millisecond.
    public var normalized: SyncRecord {
        var copy = self
        for (name, value) in fields {
            if case .date(let date) = value { copy.fields[name] = .date(SyncRecord.normalizedDate(date)) }
        }
        return copy
    }
}
