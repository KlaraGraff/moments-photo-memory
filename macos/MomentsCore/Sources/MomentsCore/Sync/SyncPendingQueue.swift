import Foundation

/// A local change waiting to be sent.
public struct SyncPendingChange: Hashable, Sendable, Codable {
    public enum Operation: String, Hashable, Sendable, Codable {
        case save
        case delete
    }

    public var key: SyncRecordKey
    public var operation: Operation
    /// Increases every time the record changes again, so a send that
    /// finishes after a newer edit does not clear the newer edit.
    public var sequence: Int

    public init(key: SyncRecordKey, operation: Operation, sequence: Int) {
        self.key = key
        self.operation = operation
        self.sequence = sequence
    }
}

/// The durable list of records this device still has to send.
///
/// One entry per record: a later change replaces an earlier one (save then
/// delete is a delete; delete then save is a save of the record as it is
/// now). Batches send parents before children and delete children before
/// parents. The queue is `Codable`; ``SyncStateStore`` writes it atomically.
public struct SyncPendingQueue: Equatable, Sendable, Codable {
    private var entries: [SyncRecordKey: SyncPendingChange] = [:]
    private var nextSequence = 1

    public init() {}

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }

    public func pending(_ key: SyncRecordKey) -> SyncPendingChange? { entries[key] }

    public mutating func enqueueSave(_ key: SyncRecordKey) {
        enqueue(key, .save)
    }

    public mutating func enqueueDelete(_ key: SyncRecordKey) {
        enqueue(key, .delete)
    }

    private mutating func enqueue(_ key: SyncRecordKey, _ operation: SyncPendingChange.Operation) {
        entries[key] = SyncPendingChange(key: key, operation: operation, sequence: nextSequence)
        nextSequence += 1
    }

    /// The next changes to send: all saves first, parents before children,
    /// then deletes, children before parents.
    public func nextBatch(limit: Int = 200) -> [SyncPendingChange] {
        let saves = entries.values.filter { $0.operation == .save }.sorted { $0.key < $1.key }
        let deletes = entries.values.filter { $0.operation == .delete }.sorted { lhs, rhs in
            if lhs.key.type.uploadRank != rhs.key.type.uploadRank {
                return lhs.key.type.uploadRank > rhs.key.type.uploadRank
            }
            return lhs.key < rhs.key
        }
        return Array((saves + deletes).prefix(max(0, limit)))
    }

    /// The server accepted this change. Returns false (and keeps the entry)
    /// when the record changed again while the send was in flight.
    @discardableResult
    public mutating func markSent(_ change: SyncPendingChange) -> Bool {
        guard let current = entries[change.key], current.sequence == change.sequence else { return false }
        entries[change.key] = nil
        return true
    }

    /// Drops a change that must not be retried (the record is gone on the
    /// server, or this person may not change it).
    public mutating func discard(_ key: SyncRecordKey) {
        entries[key] = nil
    }

    /// A record arrived from the server that this device also changed.
    /// The caller merges; the entry stays so the merged result is sent.
    public func hasPendingSave(_ key: SyncRecordKey) -> Bool {
        entries[key]?.operation == .save
    }

    /// Forget everything, for example after the person signs out of iCloud.
    public mutating func removeAll() {
        entries.removeAll()
    }
}
