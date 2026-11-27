import Foundation

/// A stand-in for one CloudKit zone, for tests and for the app's synthetic
/// UI-test mode. It keeps CloudKit's rules that matter to the merge logic:
/// a save must quote the change tag it last saw (`serverRecordChanged`
/// otherwise), saving a record the zone deleted fails (`unknownItem`), and
/// fetches return what changed since a token.
public final class InMemorySyncServer {
    public enum SaveResult: Equatable {
        case saved(SyncRecord, systemFields: Data)
        case conflict(SyncRecord, systemFields: Data)
        case gone
    }

    public enum Change: Equatable {
        case saved(SyncRecord, recordName: String, systemFields: Data)
        case deleted(SyncRecordType, recordName: String)
    }

    private struct Stored {
        var record: SyncRecord
        var tag: Int
    }

    private var stored: [String: Stored] = [:]
    private var deleted = Set<String>()
    private var log: [(sequence: Int, change: Change)] = []
    private var sequence = 0
    private var nextTag = 1
    /// While false, every call behaves like a device without a network.
    public var isReachable = true

    public init() {}

    public var recordCount: Int { stored.count }

    public func record(type: SyncRecordType, recordName: String) -> SyncRecord? {
        stored[Self.slot(type, recordName)]?.record
    }

    public func save(_ record: SyncRecord, recordName: String, systemFields: Data?) -> SaveResult? {
        guard isReachable else { return nil }
        let slot = Self.slot(record.type, recordName)
        if let current = stored[slot] {
            guard let systemFields, Self.tag(from: systemFields) == current.tag else {
                return .conflict(current.record, systemFields: Self.systemFields(current.tag))
            }
        } else if deleted.contains(slot), systemFields != nil {
            return .gone
        }
        let tag = nextTag
        nextTag += 1
        stored[slot] = Stored(record: record, tag: tag)
        deleted.remove(slot)
        let fields = Self.systemFields(tag)
        append(.saved(record, recordName: recordName, systemFields: fields))
        return .saved(record, systemFields: fields)
    }

    @discardableResult
    public func delete(_ type: SyncRecordType, recordName: String) -> Bool {
        guard isReachable else { return false }
        let slot = Self.slot(type, recordName)
        stored[slot] = nil
        deleted.insert(slot)
        append(.deleted(type, recordName: recordName))
        return true
    }

    /// Changes after `token`, each record's latest state once, and the new token.
    public func changes(since token: Int) -> (changes: [Change], token: Int)? {
        guard isReachable else { return nil }
        var latest: [String: (Int, Change)] = [:]
        for entry in log where entry.sequence > token {
            let slot: String
            switch entry.change {
            case .saved(let record, let name, _): slot = Self.slot(record.type, name)
            case .deleted(let type, let name): slot = Self.slot(type, name)
            }
            latest[slot] = (entry.sequence, entry.change)
        }
        let ordered = latest.values.sorted { $0.0 < $1.0 }.map { $0.1 }
        return (ordered, sequence)
    }

    private func append(_ change: Change) {
        sequence += 1
        log.append((sequence, change))
    }

    /// Like CloudKit, a record name is unique in the zone whatever its type.
    private static func slot(_ type: SyncRecordType, _ name: String) -> String {
        name
    }

    private static func systemFields(_ tag: Int) -> Data {
        Data(String(tag).utf8)
    }

    private static func tag(from data: Data) -> Int? {
        Int(String(decoding: data, as: UTF8.self))
    }
}

/// Runs one device's send and fetch against an ``InMemorySyncServer`` the
/// way the app's `CKSyncEngine` delegate does against CloudKit.
public final class InMemorySyncDriver {
    public let coordinator: SyncCoordinator
    public let server: InMemorySyncServer
    private var token = 0
    /// New words from the other person seen by the last ``fetch()``, as
    /// the app would announce them.
    public private(set) var lastArrivals: [SyncArrival] = []

    public init(coordinator: SyncCoordinator, server: InMemorySyncServer) {
        self.coordinator = coordinator
        self.server = server
    }

    /// Sends until the queue is empty or the server is unreachable. Returns
    /// the merges that happened.
    @discardableResult
    public func send() -> [SyncMergeResult] {
        var merges: [SyncMergeResult] = []
        var rounds = 0
        while !coordinator.pending.isEmpty && rounds < 50 {
            rounds += 1
            let batch = coordinator.outgoingBatch()
            if batch.isEmpty { break }
            for outgoing in batch {
                switch outgoing {
                case .save(let record, let name, let fields, let change):
                    switch server.save(record, recordName: name, systemFields: fields) {
                    case .saved(let stored, let systemFields)?:
                        coordinator.didSave(change, serverRecord: stored, recordName: name, systemFields: systemFields)
                    case .conflict(let current, let systemFields)?:
                        if let merge = coordinator.saveConflicted(change, serverRecord: current, recordName: name, systemFields: systemFields) {
                            merges.append(merge)
                        }
                    case .gone?:
                        coordinator.saveFailedBecauseRecordIsGone(change)
                    case nil:
                        return merges
                    }
                case .delete(let type, let name, let change):
                    guard server.delete(type, recordName: name) else { return merges }
                    coordinator.didDelete(change)
                }
            }
        }
        return merges
    }

    @discardableResult
    public func fetch() -> [SyncMergeResult] {
        lastArrivals = []
        guard let result = server.changes(since: token) else { return [] }
        var merges: [SyncMergeResult] = []
        for change in result.changes {
            switch change {
            case .saved(let record, let name, let fields):
                if let arrival = coordinator.arrival(of: record) { lastArrivals.append(arrival) }
                if let merge = coordinator.fetched(record, recordName: name, systemFields: fields) {
                    merges.append(merge)
                }
            case .deleted(let type, let name):
                coordinator.fetchedDeletion(type: type, recordName: name)
            }
        }
        token = result.token
        return merges
    }

    /// Fetch, then send, as the engine does after a push or on launch.
    @discardableResult
    public func sync() -> [SyncMergeResult] {
        fetch() + send()
    }
}
