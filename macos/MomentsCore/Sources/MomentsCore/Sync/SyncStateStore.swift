import Foundation

/// Which CloudKit database an engine talks to. The owner syncs the private
/// database (where the shared zone lives); the partner syncs the shared one.
public enum SyncDatabaseScope: String, Sendable, Codable, CaseIterable {
    case privateDatabase = "private"
    case sharedDatabase = "shared"
}

/// Everything the sync layer must remember between launches, kept in one
/// folder per iCloud account under the app's Application Support folder:
///
/// - `engine-<scope>.state`: the engine's opaque state (`CKSyncEngine.State.Serialization`).
/// - `pending.json`: the ``SyncPendingQueue``.
/// - `settings.json`: the ``SharingScope`` and the partner's account.
/// - `bases/<shard>.json`: the last server version of each record, for
///   three-way merges. 256 shard files, so saving a batch rewrites only the
///   shards it touched even with 50,000 photos.
///
/// Every write goes to a temporary file first and is then renamed into
/// place, so a crash leaves the old file or the new one, never half of one.
public final class SyncStateStore {
    /// Which side of the share this account is on.
    public enum Role: String, Equatable, Sendable, Codable {
        /// Made the share; syncs the private database.
        case owner
        /// Accepted the other person's share; syncs the shared database.
        case participant
    }

    public struct Settings: Equatable, Sendable, Codable {
        public var scope: SharingScope
        public var partnerAccountID: String?
        public var zoneName: String
        public var role: Role?
        /// The zone owner's record name, which the participant needs to
        /// address the zone in the shared database.
        public var zoneOwnerName: String?

        public init(
            scope: SharingScope = .selectedTrips([]),
            partnerAccountID: String? = nil,
            zoneName: String = SyncStateStore.defaultZoneName,
            role: Role? = nil,
            zoneOwnerName: String? = nil
        ) {
            self.scope = scope
            self.partnerAccountID = partnerAccountID
            self.zoneName = zoneName
            self.role = role
            self.zoneOwnerName = zoneOwnerName
        }
    }

    /// The last server version of a record plus the server's own bookkeeping
    /// for it (CloudKit's archived system fields, which carry the change tag
    /// the next save must quote).
    public struct BaseEntry: Equatable, Sendable, Codable {
        public var record: SyncRecord
        public var recordName: String
        public var systemFields: Data?

        public init(record: SyncRecord, recordName: String, systemFields: Data?) {
            self.record = record
            self.recordName = recordName
            self.systemFields = systemFields
        }
    }

    public static let defaultZoneName = "moments-shared"
    public static let shardCount = 256

    public let folder: URL
    private let fileManager = FileManager.default
    private var shards: [Int: [String: BaseEntry]] = [:]
    private var names: [String: SyncRecordKey]?
    private var namesDirty = false
    private var dirtyShards = Set<Int>()

    /// `folder` should be account-specific, so signing in with another
    /// iCloud account never reuses this account's state.
    public init(folder: URL) throws {
        self.folder = folder
        try fileManager.createDirectory(at: folder.appendingPathComponent("bases", isDirectory: true), withIntermediateDirectories: true)
    }

    /// The folder for one account inside a root folder. The account ID is
    /// hashed so it never appears in a path.
    public static func accountFolder(root: URL, accountID: String) -> URL {
        root.appendingPathComponent("account-" + SyncDigest.hex(accountID), isDirectory: true)
    }

    // MARK: Engine state

    public func engineState(for scope: SyncDatabaseScope) -> Data? {
        try? Data(contentsOf: engineURL(scope))
    }

    public func saveEngineState(_ data: Data, for scope: SyncDatabaseScope) throws {
        try writeAtomically(data, to: engineURL(scope))
    }

    public func clearEngineState(for scope: SyncDatabaseScope) throws {
        try removeIfPresent(engineURL(scope))
    }

    private func engineURL(_ scope: SyncDatabaseScope) -> URL {
        folder.appendingPathComponent("engine-\(scope.rawValue).state")
    }

    // MARK: Pending changes and settings

    public func loadPending() -> SyncPendingQueue {
        load(SyncPendingQueue.self, from: "pending.json") ?? SyncPendingQueue()
    }

    public func savePending(_ queue: SyncPendingQueue) throws {
        try save(queue, to: "pending.json")
    }

    public func loadSettings() -> Settings {
        load(Settings.self, from: "settings.json") ?? Settings()
    }

    public func saveSettings(_ settings: Settings) throws {
        try save(settings, to: "settings.json")
    }

    // MARK: Server versions (merge bases)

    public func base(for key: SyncRecordKey) -> SyncRecord? {
        baseEntry(for: key)?.record
    }

    public func baseEntry(for key: SyncRecordKey) -> BaseEntry? {
        shard(Self.shardIndex(key))[Self.storageKey(key)]
    }

    public func setBase(_ record: SyncRecord, recordName: String, systemFields: Data?) {
        let index = Self.shardIndex(record.key)
        var contents = shard(index)
        contents[Self.storageKey(record.key)] = BaseEntry(record: record, recordName: recordName, systemFields: systemFields)
        shards[index] = contents
        dirtyShards.insert(index)
        if !SyncRecordName.isSafe(record.id) {
            var map = loadNames()
            if map[Self.nameKey(record.type, recordName)] != record.key {
                map[Self.nameKey(record.type, recordName)] = record.key
                names = map
                namesDirty = true
            }
        }
    }

    public func removeBase(_ key: SyncRecordKey) {
        let index = Self.shardIndex(key)
        var contents = shard(index)
        guard let removed = contents.removeValue(forKey: Self.storageKey(key)) else { return }
        shards[index] = contents
        dirtyShards.insert(index)
        if !SyncRecordName.isSafe(key.id) {
            var map = loadNames()
            map[Self.nameKey(key.type, removed.recordName)] = nil
            names = map
            namesDirty = true
        }
    }

    /// Every record this account has a server version of. Loads all shards
    /// once; later calls use the cached shards.
    public func allBaseKeys() -> [SyncRecordKey] {
        var keys: [SyncRecordKey] = []
        for index in 0..<Self.shardCount {
            keys.append(contentsOf: shard(index).values.map(\.record.key))
        }
        return keys
    }

    /// The local key behind a record name made from an unsafe ID. A deletion
    /// from the server only names the record, so the mapping is remembered.
    public func key(type: SyncRecordType, hashedRecordName: String) -> SyncRecordKey? {
        loadNames()[Self.nameKey(type, hashedRecordName)]
    }

    private func loadNames() -> [String: SyncRecordKey] {
        if let names { return names }
        let loaded = load([String: SyncRecordKey].self, from: "names.json") ?? [:]
        names = loaded
        return loaded
    }

    private static func nameKey(_ type: SyncRecordType, _ recordName: String) -> String {
        type.rawValue + "/" + recordName
    }

    /// Writes the shards changed since the last flush. Call it before saving
    /// the engine state that acknowledges the same fetch.
    public func flushBases() throws {
        for index in dirtyShards.sorted() {
            let data = try Self.encoder.encode(shards[index] ?? [:])
            try writeAtomically(data, to: shardURL(index))
        }
        dirtyShards.removeAll()
        if namesDirty, let names {
            try save(names, to: "names.json")
            namesDirty = false
        }
    }

    /// Forget everything this account synced. Local photos and memories are
    /// not touched; they live in the app's own store.
    public func reset() throws {
        shards.removeAll()
        dirtyShards.removeAll()
        names = nil
        namesDirty = false
        if fileManager.fileExists(atPath: folder.path) {
            try fileManager.removeItem(at: folder)
        }
        try fileManager.createDirectory(at: folder.appendingPathComponent("bases", isDirectory: true), withIntermediateDirectories: true)
    }

    static func shardIndex(_ key: SyncRecordKey) -> Int {
        Int(SyncDigest.value(storageKey(key)) % UInt64(shardCount))
    }

    static func storageKey(_ key: SyncRecordKey) -> String {
        key.type.rawValue + "/" + key.id
    }

    private func shard(_ index: Int) -> [String: BaseEntry] {
        if let loaded = shards[index] { return loaded }
        let contents = (try? Data(contentsOf: shardURL(index)))
            .flatMap { try? Self.decoder.decode([String: BaseEntry].self, from: $0) } ?? [:]
        shards[index] = contents
        return contents
    }

    private func shardURL(_ index: Int) -> URL {
        folder.appendingPathComponent("bases", isDirectory: true)
            .appendingPathComponent((index < 16 ? "0" : "") + String(index, radix: 16) + ".json")
    }

    // MARK: Files

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.dataEncodingStrategy = .base64
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        decoder.dataDecodingStrategy = .base64
        return decoder
    }()

    private func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return nil }
        return try? Self.decoder.decode(type, from: data)
    }

    private func save<T: Encodable>(_ value: T, to name: String) throws {
        try writeAtomically(try Self.encoder.encode(value), to: folder.appendingPathComponent(name))
    }

    private func writeAtomically(_ data: Data, to url: URL) throws {
        // `.atomic` writes a temporary file and renames it into place.
        try data.write(to: url, options: .atomic)
    }

    private func removeIfPresent(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }
}
