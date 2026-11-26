import Foundation

/// The app's local database as the sync layer sees it. Records are in their
/// local spelling (`local-me` for this device's person).
///
/// The Mac app implements it over SwiftData; tests use ``InMemorySyncLocalStore``.
public protocol SyncLocalStore: AnyObject {
    func record(for key: SyncRecordKey) -> SyncRecord?
    /// Insert or update from the server. Must not report the write back as a
    /// local change (the coordinator would send it again).
    func apply(_ record: SyncRecord)
    /// The server deleted the record. Delete it locally without reporting it.
    func applyDeletion(_ key: SyncRecordKey)
}

/// One change ready for the server, in the wire spelling.
public enum SyncOutgoing: Equatable, Sendable {
    case save(SyncRecord, recordName: String, systemFields: Data?, change: SyncPendingChange)
    case delete(SyncRecordType, recordName: String, change: SyncPendingChange)

    public var change: SyncPendingChange {
        switch self {
        case .save(_, _, _, let change), .delete(_, _, let change): return change
        }
    }
}

/// Glue between the local store, the pending queue, the merge rules and
/// whatever talks to the server (`CKSyncEngine` in the app, an in-memory
/// server in tests). It holds no CloudKit types, so it is the same on Mac and
/// on a future iPhone app.
///
/// Both devices filter what they send through ``updateSharedKeys(_:)``: the
/// owner's set comes from the trips they chose, the partner's from the trips
/// that arrived in the shared zone, so neither sends the rest of their own
/// library. Until the first call, nothing is filtered (tests rely on that).
public final class SyncCoordinator {
    public let accounts: SyncAccountMap
    public let state: SyncStateStore
    public let database: SyncDatabaseScope
    public private(set) var pending: SyncPendingQueue
    private let local: SyncLocalStore
    /// What belongs in the shared zone. Nil sends everything.
    public private(set) var sharedKeys: Set<SyncRecordKey>?
    /// Changes to records outside the shared set, checked again on the next
    /// ``updateSharedKeys(_:)`` (a new memory on a shared photo is outside
    /// the set until the set is recomputed).
    private var deferred = Set<SyncRecordKey>()
    /// What the resolver produced last time.
    private var scopeKeys: Set<SyncRecordKey>?

    public init(accounts: SyncAccountMap, state: SyncStateStore, database: SyncDatabaseScope, local: SyncLocalStore) {
        self.accounts = accounts
        self.state = state
        self.database = database
        self.local = local
        self.pending = state.loadPending()
    }

    // MARK: Local changes

    /// This device changed a record. Changes the person may not make (a
    /// partner's memory) are never queued.
    public func localRecordChanged(_ key: SyncRecordKey) {
        guard let record = local.record(for: key) else { return }
        consider(record)
    }

    private func consider(_ record: SyncRecord) {
        guard accounts.canEdit(record) else { return }
        guard joinSharedSet(record) else {
            deferred.insert(record.key)
            return
        }
        pending.enqueueSave(record.key)
    }

    /// Whether a changed record belongs in the shared zone, adding it to the
    /// shared set when it hangs off something already shared (a new memory,
    /// favorite or tag on a shared photo; a new photo in a shared trip). The
    /// place, tag or chapter it points at is pulled in with it. Anything
    /// else waits for the next full ``updateSharedKeys(_:)``.
    private func joinSharedSet(_ record: SyncRecord) -> Bool {
        guard var keys = sharedKeys else { return true }
        if keys.contains(record.key) { return true }
        let anchors: [SyncRecordKey]
        switch record.type {
        case .mediaItem:
            anchors = ref(record, "tripID").map { [SyncRecordKey(.trip, $0)] } ?? []
        case .previewAsset, .memory, .mediaTag, .favorite, .userGroupItem, .photoNote, .placeOverride:
            anchors = ref(record, "mediaID").map { [SyncRecordKey(.mediaItem, $0)] } ?? []
        case .memoryRevision:
            let id = ref(record, "memoryID")
            let types: [SyncRecordType] = [.memory, .photoNote, .placeNote, .collectionMemory]
            anchors = id.map { value in types.map { SyncRecordKey($0, value) } } ?? []
        case .place, .tag, .trip, .userGroup, .placeNote, .collectionMemory:
            anchors = []
        }
        guard anchors.contains(where: { keys.contains($0) }) else { return false }
        keys.insert(record.key)
        let pulledIn: [SyncRecordType] = [.place, .tag, .userGroup]
        for field in record.type.spec.references {
            guard let target = field.target, pulledIn.contains(target),
                  let id = ref(record, field.name) else { continue }
            var next: SyncRecordKey? = SyncRecordKey(target, id)
            while let key = next, !keys.contains(key), let parent = local.record(for: key) {
                keys.insert(key)
                if state.baseEntry(for: key) == nil { pending.enqueueSave(key) }
                next = target == .place ? ref(parent, "parentID").map { SyncRecordKey(.place, $0) } : nil
            }
        }
        sharedKeys = keys
        return true
    }

    private func ref(_ record: SyncRecord, _ field: String) -> String? {
        record.fields[field]?.stringValue
    }

    /// This device deleted a record it had synced.
    public func localRecordDeleted(_ key: SyncRecordKey) {
        deferred.remove(key)
        if state.baseEntry(for: key) != nil {
            pending.enqueueDelete(key)
        } else {
            // Never reached the server: forget the unsent save.
            pending.discard(key)
        }
    }

    /// Compares a full snapshot of this device's records with what the
    /// server last held and queues the differences: records changed or added
    /// since, and records deleted here. The app calls it a moment after its
    /// saves settle (and at launch), so it needs no per-edit hooks and also
    /// catches edits made while sync was off. Records are in local spelling.
    public func reconcile(localRecords: [SyncRecord]) {
        var present = Set<SyncRecordKey>()
        present.reserveCapacity(localRecords.count)
        for record in localRecords {
            present.insert(record.key)
            guard pending.pending(record.key) == nil else { continue }
            if let base = state.base(for: record.key),
               Self.comparable(record).digest == Self.comparable(base).digest {
                continue
            }
            consider(record)
        }
        for key in state.allBaseKeys() where !present.contains(key) && pending.pending(key) == nil {
            guard let base = state.base(for: key), accounts.canEdit(base) else { continue }
            pending.enqueueDelete(key)
        }
    }

    /// The scope or the library changed shape: `keys` is
    /// ``SharingScopeResolver/includedKeys(scope:records:)`` over this
    /// device's records. Records that joined are queued for upload. On the
    /// owner's device, records that left are removed from the shared zone
    /// (never from this device); the partner's device never removes anything
    /// from the zone this way. Zone records the resolver never placed (for
    /// example a note about a place name the owner's Mac does not know) are
    /// left alone.
    public func updateSharedKeys(_ keys: Set<SyncRecordKey>) {
        let oldScope = scopeKeys ?? []
        let unplaced = (sharedKeys ?? []).subtracting(oldScope).filter { state.baseEntry(for: $0) != nil }
        scopeKeys = keys
        sharedKeys = keys.union(unplaced)
        let diff = SharingScopeResolver.difference(old: oldScope, new: keys)
        for key in diff.upload where state.baseEntry(for: key) == nil {
            if let record = local.record(for: key), accounts.canEdit(record) {
                pending.enqueueSave(key)
            }
        }
        if database == .privateDatabase {
            for key in diff.removeFromZone where state.baseEntry(for: key) != nil {
                pending.enqueueDelete(key)
            }
        }
        for key in deferred where keys.contains(key) {
            if let record = local.record(for: key), accounts.canEdit(record) {
                pending.enqueueSave(key)
            }
        }
        deferred.removeAll()
    }

    // MARK: Sending

    public func outgoingBatch(limit: Int = 200) -> [SyncOutgoing] {
        var batch: [SyncOutgoing] = []
        for change in pending.nextBatch(limit: limit) {
            switch change.operation {
            case .save:
                guard let record = local.record(for: change.key) else {
                    pending.discard(change.key)
                    continue
                }
                let wire = accounts.toWire(record)
                var named = wire
                named.fields[SyncSchema.idField] = .string(wire.id)
                let entry = state.baseEntry(for: change.key)
                batch.append(.save(
                    named,
                    recordName: SyncRecordName.make(type: wire.type, id: wire.id),
                    systemFields: entry?.systemFields,
                    change: change
                ))
            case .delete:
                let entry = state.baseEntry(for: change.key)
                let wireID = accounts.wireID(change.key.id, type: change.key.type)
                batch.append(.delete(
                    change.key.type,
                    recordName: entry?.recordName ?? SyncRecordName.make(type: change.key.type, id: wireID),
                    change: change
                ))
            }
        }
        return batch
    }

    /// The server stored the record. `serverRecord` is what it now holds.
    public func didSave(_ change: SyncPendingChange, serverRecord: SyncRecord, recordName: String, systemFields: Data?) {
        pending.markSent(change)
        state.setBase(accounts.fromWire(decodeID(serverRecord)), recordName: recordName, systemFields: systemFields)
    }

    public func didDelete(_ change: SyncPendingChange) {
        pending.markSent(change)
        state.removeBase(change.key)
    }

    /// Records this device has a server version of, i.e. what is in the zone
    /// as far as this device knows. Callers check membership with it.
    public func isInZone(_ key: SyncRecordKey) -> Bool {
        state.baseEntry(for: key) != nil
    }

    /// The server holds a newer version than the one this device edited.
    /// Merge, keep the losing words, and queue the result again.
    @discardableResult
    public func saveConflicted(_ change: SyncPendingChange, serverRecord: SyncRecord, recordName: String, systemFields: Data?) -> SyncMergeResult? {
        let server = accounts.fromWire(decodeID(serverRecord))
        let base = state.base(for: change.key)
        state.setBase(server, recordName: recordName, systemFields: systemFields)
        guard let mine = local.record(for: change.key) else {
            local.apply(server)
            pending.discard(change.key)
            return nil
        }
        let result = SyncMerger.merge(base: base, local: mine, server: server)
        local.apply(result.merged)
        keep(result.keptRevisions)
        if result.needsUpload {
            pending.enqueueSave(change.key)
        } else {
            pending.markSent(change)
        }
        return result
    }

    /// The record is gone on the server. Never re-create it: an offline
    /// device must not bring back what the other person deleted.
    public func saveFailedBecauseRecordIsGone(_ change: SyncPendingChange) {
        pending.discard(change.key)
        state.removeBase(change.key)
        local.applyDeletion(change.key)
    }

    // MARK: Receiving

    /// A record changed on the server (sent by the other person or by this
    /// person's other device).
    @discardableResult
    public func fetched(_ serverRecord: SyncRecord, recordName: String, systemFields: Data?) -> SyncMergeResult? {
        let server = accounts.fromWire(decodeID(serverRecord))
        let key = server.key
        let base = state.base(for: key)
        state.setBase(server, recordName: recordName, systemFields: systemFields)
        sharedKeys?.insert(key)
        if pending.hasPendingSave(key), let mine = local.record(for: key) {
            let result = SyncMerger.merge(base: base, local: mine, server: server)
            local.apply(result.merged)
            keep(result.keptRevisions)
            if !result.needsUpload { pending.discard(key) }
            return result
        }
        if pending.pending(key)?.operation == .delete {
            // This device deleted it meanwhile; the delete still goes out.
            return nil
        }
        local.apply(server)
        return nil
    }

    /// A record was deleted from the zone. When this device has no server
    /// version of it, the deletion is this device's own (a delete it sent, or
    /// a trip the owner stopped sharing) and the local record stays.
    public func fetchedDeletion(type: SyncRecordType, recordName: String) {
        guard let key = localKey(type: type, recordName: recordName),
              state.baseEntry(for: key) != nil else { return }
        pending.discard(key)
        state.removeBase(key)
        sharedKeys?.remove(key)
        local.applyDeletion(key)
    }

    /// The local key for a record name from the server.
    public func localKey(type: SyncRecordType, recordName: String) -> SyncRecordKey? {
        if SyncRecordName.isSafe(recordName) {
            return SyncRecordKey(type, accounts.localID(recordName, type: type))
        }
        return state.key(type: type, hashedRecordName: recordName)
    }

    /// Persist the queue and merge bases. Call before saving engine state.
    public func flush() throws {
        try state.flushBases()
        try state.savePending(pending)
    }

    private func keep(_ revisions: [SyncRecord]) {
        for revision in revisions where local.record(for: revision.key) == nil {
            local.apply(revision)
            pending.enqueueSave(revision.key)
        }
    }

    /// A record as reconcile compares it: dates to the millisecond, and an
    /// empty "this device's person" field the same as `local-me`.
    static func comparable(_ record: SyncRecord) -> SyncRecord {
        var copy = record.normalized
        for field in record.type.spec.accountFields where field.nilMeansLocal && copy.fields[field.name] == nil {
            copy.fields[field.name] = .string(SyncAccountMap.localAlias)
        }
        return copy
    }

    /// Restores the Moments ID from ``SyncSchema/idField`` and drops it.
    private func decodeID(_ record: SyncRecord) -> SyncRecord {
        var copy = record
        if let id = record.fields[SyncSchema.idField]?.stringValue { copy.id = id }
        copy.fields[SyncSchema.idField] = nil
        return copy
    }
}

/// A dictionary-backed ``SyncLocalStore`` for tests and previews.
public final class InMemorySyncLocalStore: SyncLocalStore {
    public private(set) var records: [SyncRecordKey: SyncRecord] = [:]

    public init(_ records: [SyncRecord] = []) {
        for record in records { self.records[record.key] = record }
    }

    public func record(for key: SyncRecordKey) -> SyncRecord? { records[key] }
    public func apply(_ record: SyncRecord) { records[record.key] = record }
    public func applyDeletion(_ key: SyncRecordKey) { records[key] = nil }

    /// A local edit, as the app would make it.
    public func write(_ record: SyncRecord) { records[record.key] = record }
    public func remove(_ key: SyncRecordKey) { records[key] = nil }
}
