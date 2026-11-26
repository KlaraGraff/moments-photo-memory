import Foundation

/// Why a backup was made. Only the automatic kinds are ever pruned.
public enum BackupKind: String, Codable, Sendable, CaseIterable {
    /// The once-a-day automatic backup.
    case daily
    /// Made before a new app version opens the library with a newer schema.
    case beforeUpgrade
    /// The library as it was just before a restore replaced it.
    case beforeRestore
}

/// `backup.json`, written last into every backup folder. A folder without one
/// is not a finished backup (or is an old "couldn't open" copy) and is never
/// listed, restored or pruned.
public struct BackupManifest: Codable, Equatable, Sendable {
    public static let fileName = "backup.json"
    public static let currentFormat = 1

    public var format: Int
    public var kind: BackupKind
    public var createdAt: Date
    public var appVersion: String
    /// The store's schema version, "8.0.0". A backup from a newer schema than
    /// the running app knows is never restored.
    public var schemaVersion: String
    public var photoCount: Int?
    public var memoryCount: Int?
    /// The newest modification date of the store files when they were copied,
    /// so an unchanged library is not backed up again.
    public var sourceModifiedAt: Date?

    public init(
        format: Int = BackupManifest.currentFormat,
        kind: BackupKind,
        createdAt: Date,
        appVersion: String,
        schemaVersion: String,
        photoCount: Int? = nil,
        memoryCount: Int? = nil,
        sourceModifiedAt: Date? = nil
    ) {
        self.format = format
        self.kind = kind
        self.createdAt = createdAt
        self.appVersion = appVersion
        self.schemaVersion = schemaVersion
        self.photoCount = photoCount
        self.memoryCount = memoryCount
        self.sourceModifiedAt = sourceModifiedAt
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public func encoded() throws -> Data {
        try Self.encoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> BackupManifest {
        try decoder().decode(BackupManifest.self, from: data)
    }
}

/// One finished backup on disk: its folder name and what its manifest says.
public struct BackupEntry: Equatable, Sendable {
    public var folderName: String
    public var manifest: BackupManifest

    public init(folderName: String, manifest: BackupManifest) {
        self.folderName = folderName
        self.manifest = manifest
    }
}

/// Whether a backup can replace the running app's library.
public enum RestoreCheck: Equatable, Sendable {
    case ok
    /// Made by a newer Moments: opening it would need a schema this app lacks.
    case tooNew
    /// Not a Moments backup this app understands (format or version unreadable).
    case unreadable
}

/// The rules behind automatic backups, kept free of SwiftData and the file
/// system so Linux can test them.
public enum BackupPolicy {
    /// Daily backups kept; older ones are removed after each new backup.
    public static let dailyKeep = 14
    /// Backups made before a schema upgrade that are kept.
    public static let beforeUpgradeKeep = 3
    /// "Before restore" copies kept. Restores are rare; this only stops a
    /// long run of experiments from filling the disk.
    public static let beforeRestoreKeep = 5

    /// A daily backup is due when no backup was made today (in the person's
    /// calendar) and the library changed since the newest backup. A library
    /// without any backup is always due.
    public static func isDailyDue(
        newest: BackupManifest?,
        currentSourceModifiedAt: Date?,
        now: Date,
        calendar: Calendar = .current
    ) -> Bool {
        guard let newest else { return true }
        if calendar.isDate(newest.createdAt, inSameDayAs: now) { return false }
        guard let current = currentSourceModifiedAt, let backedUp = newest.sourceModifiedAt else { return true }
        // backup.json keeps whole seconds while file times have fractions,
        // so a change must be more than a second newer to count.
        return current.timeIntervalSince(backedUp) > modificationTolerance
    }

    /// How much newer the store must be than the backed-up copy to count as
    /// changed: the manifest rounds dates to whole seconds.
    public static let modificationTolerance: TimeInterval = 1

    /// The newest backup of any kind, by creation date.
    public static func newest(_ entries: [BackupEntry]) -> BackupEntry? {
        entries.max { $0.manifest.createdAt < $1.manifest.createdAt }
    }

    /// Entries newest first, the order the restore list shows.
    public static func sortedNewestFirst(_ entries: [BackupEntry]) -> [BackupEntry] {
        entries.sorted { lhs, rhs in
            if lhs.manifest.createdAt != rhs.manifest.createdAt { return lhs.manifest.createdAt > rhs.manifest.createdAt }
            return lhs.folderName > rhs.folderName
        }
    }

    /// Folder names to remove so each automatic kind keeps only its newest
    /// copies. Folders without a manifest are not entries and never removed,
    /// nor are `protected` ones (a backup about to be restored), which also
    /// don't count against their kind's limit.
    public static func foldersToPrune(_ entries: [BackupEntry], protected: Set<String> = []) -> [String] {
        var doomed: [String] = []
        for kind in BackupKind.allCases {
            let keep = keepCount(for: kind)
            let ofKind = sortedNewestFirst(entries.filter { $0.manifest.kind == kind && !protected.contains($0.folderName) })
            if ofKind.count > keep {
                doomed.append(contentsOf: ofKind[keep...].map(\.folderName))
            }
        }
        return doomed.sorted()
    }

    public static func keepCount(for kind: BackupKind) -> Int {
        switch kind {
        case .daily: return dailyKeep
        case .beforeUpgrade: return beforeUpgradeKeep
        case .beforeRestore: return beforeRestoreKeep
        }
    }

    /// An upgrade backup is due when a store exists and was last opened by a
    /// different schema (or the app never recorded one: the first launch of a
    /// build with backups).
    public static func needsUpgradeBackup(lastOpenedSchema: String?, currentSchema: String, storeExists: Bool) -> Bool {
        storeExists && lastOpenedSchema != currentSchema
    }

    /// True when `version` is an older schema than `other`, compared as
    /// numbers ("10.0.0" is newer than "9.0.0"). Unreadable text is never older.
    public static func isSchema(_ version: String, olderThan other: String) -> Bool {
        guard let lhs = SchemaVersionNumber(version), let rhs = SchemaVersionNumber(other) else { return false }
        return lhs < rhs
    }

    public static func restoreCheck(_ manifest: BackupManifest, currentSchema: String) -> RestoreCheck {
        guard manifest.format <= BackupManifest.currentFormat,
              let backup = SchemaVersionNumber(manifest.schemaVersion),
              let current = SchemaVersionNumber(currentSchema) else { return .unreadable }
        return backup <= current ? .ok : .tooNew
    }

    /// A folder name that sorts by time and says what it is, for example
    /// `2026-11-26T09-12-00+0800 daily`. Finder shows ":" as "/", so the time
    /// uses dashes.
    public static func folderName(for kind: BackupKind, at date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate, .withTimeZone]
        let stamp = formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
        return "\(stamp) \(kind.rawValue)"
    }
}

/// "8.0.0" compared part by part.
struct SchemaVersionNumber: Comparable {
    let parts: [Int]

    init?(_ text: String) {
        let pieces = text.split(separator: ".").map { Int($0) }
        guard !pieces.isEmpty, pieces.allSatisfy({ $0 != nil }) else { return nil }
        parts = pieces.compactMap { $0 }
    }

    static func < (lhs: SchemaVersionNumber, rhs: SchemaVersionNumber) -> Bool {
        let count = max(lhs.parts.count, rhs.parts.count)
        for index in 0..<count {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    static func == (lhs: SchemaVersionNumber, rhs: SchemaVersionNumber) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}
