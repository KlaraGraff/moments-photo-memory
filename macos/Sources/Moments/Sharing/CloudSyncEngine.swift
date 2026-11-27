import CloudKit
import Foundation
import MomentsCore
import SwiftData

/// Runs `CKSyncEngine` for one database: the owner's private database (where
/// the shared zone lives) or the partner's shared database.
///
/// All work happens on this actor with its own `ModelContext`, so fetched
/// records are written off the main thread and the coordinator is never
/// touched from two places at once. Nothing here runs unless sharing is set
/// up (a container is configured and the person is signed in to iCloud).
actor CloudSyncEngine: CKSyncEngineDelegate {
    struct Status: Equatable, Sendable {
        var pendingCount = 0
        var lastSync: Date?
        var lastError: String?
        var isSyncing = false
    }

    let database: CKDatabase
    let scope: SyncDatabaseScope
    let zoneID: CKRecordZone.ID
    private let context: ModelContext
    private let state: SyncStateStore
    private let store: SwiftDataSyncStore
    private let coordinator: SyncCoordinator
    private let previews: SharedPreviewFiles
    private var engine: CKSyncEngine?
    /// What each record name was sent as, to match results to the queue.
    private var inFlight: [String: SyncPendingChange] = [:]
    private var onStatus: (@Sendable (Status) -> Void)?
    private var onShareEnded: (@Sendable () -> Void)?
    private var onArrivals: (@Sendable ([SyncArrival]) -> Void)?
    /// False while this database is downloaded for the first time, so
    /// joining a share does not announce everything already in it.
    private var announcesArrivals = false
    /// The engine's own context, so the app can tell its saves (fetched
    /// changes) from the person's edits.
    nonisolated let contextID: ObjectIdentifier
    private(set) var status = Status()

    init(
        container: ModelContainer,
        database: CKDatabase,
        scope: SyncDatabaseScope,
        zoneID: CKRecordZone.ID,
        accounts: SyncAccountMap,
        stateFolder: URL,
        previews: SharedPreviewFiles
    ) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let state = try SyncStateStore(folder: stateFolder)
        let store = SwiftDataSyncStore(
            context: context,
            accounts: accounts,
            orphans: SyncOrphanLinks(file: stateFolder.appending(path: "orphans.json")),
            previews: previews
        )
        self.database = database
        self.scope = scope
        self.zoneID = zoneID
        self.context = context
        self.contextID = ObjectIdentifier(context)
        self.state = state
        self.store = store
        self.coordinator = SyncCoordinator(accounts: accounts, state: state, database: scope, local: store)
        self.previews = previews
    }

    func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        onStatus = handler
    }

    /// Called when the shared zone is gone: the owner stopped sharing, or
    /// it was stopped on another of the owner's Macs.
    func setShareEndedHandler(_ handler: @escaping @Sendable () -> Void) {
        onShareEnded = handler
    }

    /// Called after each fetch with what the other person newly wrote for
    /// this person (issue #28): new memories, comments and replies.
    func setArrivalsHandler(_ handler: @escaping @Sendable ([SyncArrival]) -> Void) {
        onArrivals = handler
    }

    /// Creates the engine from its saved state. The owner also makes sure the
    /// shared zone exists.
    func start() {
        guard engine == nil else { return }
        let saved = state.engineState(for: scope)
            .flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        announcesArrivals = saved != nil
        let configuration = CKSyncEngine.Configuration(database: database, stateSerialization: saved, delegate: self)
        let engine = CKSyncEngine(configuration)
        self.engine = engine
        if scope == .privateDatabase {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        }
        mirrorPendingIntoEngine()
    }

    /// Re-reads the shared set and the local library, makes previews for
    /// shared photos that have none yet, queues the differences and asks the
    /// engine to send. Called a moment after local saves settle.
    func reconcile(sharingScope: SharingScope?) async {
        do {
            var records = try allRecords()
            var keys = sharedKeys(sharingScope: sharingScope, records: records)
            if await producePreviews(for: keys) > 0 {
                records = try allRecords()
                keys = sharedKeys(sharingScope: sharingScope, records: records)
            }
            coordinator.updateSharedKeys(keys)
            coordinator.reconcile(localRecords: records)
            try coordinator.flush()
        } catch {
            report(error: error)
        }
        mirrorPendingIntoEngine()
    }

    /// The library plus every preview in the zone whose file is here: a
    /// preview can arrive before its photo, and must not look deleted.
    private func allRecords() throws -> [SyncRecord] {
        var records = try store.allRecords()
        let listed = Set(records.lazy.filter { $0.type == .previewAsset }.map(\.key))
        for key in state.allBaseKeys() where key.type == .previewAsset && !listed.contains(key) {
            if let preview = store.previewRecord(id: key.id) { records.append(preview) }
        }
        return records
    }

    private func sharedKeys(sharingScope: SharingScope?, records: [SyncRecord]) -> Set<SyncRecordKey> {
        if let sharingScope {
            return SharingScopeResolver.includedKeys(scope: sharingScope, records: records)
        }
        // The partner shares back what arrived in the zone, plus what hangs
        // off it.
        let trips = Set(records.filter { $0.type == .trip && coordinator.isInZone($0.key) }.map(\.id))
        return SharingScopeResolver.includedKeys(scope: .selectedTrips(trips), records: records)
    }

    /// Previews for shared photos whose original is on this Mac (a photo
    /// that arrived from the other person already has its preview).
    private func producePreviews(for keys: Set<SyncRecordKey>) async -> Int {
        let mediaIDs = Set(keys.filter { $0.type == .mediaItem }.map(\.id))
        guard !mediaIDs.isEmpty else { return 0 }
        let shared = SyncModelCoding.sharedSourceRaw
        let items = (try? context.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.sourceRaw != shared }))) ?? []
        let sources: [SharedPreviewProducer.Source] = items
            .filter { mediaIDs.contains($0.id) }
            .filter { !FileManager.default.fileExists(atPath: previews.url(mediaID: $0.id).path) }
            .map { SharedPreviewProducer.Source(mediaID: $0.id, photosLocalIdentifier: $0.photosLocalIdentifier, bookmark: $0.originalBookmarkData) }
        guard !sources.isEmpty else { return 0 }
        return await SharedPreviewProducer.produce(sources, into: previews)
    }

    func syncNow() async {
        guard let engine else { return }
        status.isSyncing = true
        publish()
        do {
            try await engine.fetchChanges()
            try await engine.sendChanges()
            status.lastSync = .now
            status.lastError = nil
        } catch {
            report(error: error)
        }
        status.isSyncing = false
        publish()
    }

    /// Stops syncing and forgets this database's sync state. Local photos
    /// and memories stay.
    func stopAndForget() throws {
        engine = nil
        inFlight.removeAll()
        try state.reset()
    }

    // MARK: CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            do {
                try coordinator.flush()
                let data = try JSONEncoder().encode(update.stateSerialization)
                try state.saveEngineState(data, for: scope)
            } catch {
                report(error: error)
            }

        case .accountChange(let change):
            switch change.changeType {
            case .signIn:
                break
            case .signOut, .switchAccounts:
                // Never mix two iCloud accounts' data: stop and forget sync
                // state; the local library is left alone.
                try? stopAndForget()
            @unknown default:
                break
            }

        case .fetchedRecordZoneChanges(let changes):
            var arrivals: [SyncArrival] = []
            for modification in changes.modifications {
                let ckRecord = modification.record
                guard ckRecord.recordID.zoneID == zoneID,
                      let record = CloudKitRecordCoding.syncRecord(from: ckRecord, storeAsset: { url in
                          storePreview(at: url, of: ckRecord)
                      }) else { continue }
                if announcesArrivals, let arrival = coordinator.arrival(of: record) { arrivals.append(arrival) }
                coordinator.fetched(
                    record,
                    recordName: ckRecord.recordID.recordName,
                    systemFields: CloudKitRecordCoding.encodeSystemFields(ckRecord)
                )
            }
            for deletion in changes.deletions where deletion.recordID.zoneID == zoneID {
                guard let type = SyncRecordType(rawValue: deletion.recordType) else { continue }
                coordinator.fetchedDeletion(type: type, recordName: deletion.recordID.recordName)
            }
            saveLocal()
            mirrorPendingIntoEngine()
            if !arrivals.isEmpty { onArrivals?(arrivals) }

        case .sentRecordZoneChanges(let sent):
            for ckRecord in sent.savedRecords {
                let name = ckRecord.recordID.recordName
                guard let change = inFlight.removeValue(forKey: name),
                      let record = CloudKitRecordCoding.syncRecord(from: ckRecord, storeAsset: { _ in nil }) else { continue }
                var server = record
                if server.type == .previewAsset, let local = store.record(for: change.key) {
                    // The saved record's asset points at a temporary upload
                    // copy; describe the file this Mac keeps instead.
                    server.fields["preview"] = local.fields["preview"]
                }
                coordinator.didSave(change, serverRecord: server, recordName: name, systemFields: CloudKitRecordCoding.encodeSystemFields(ckRecord))
            }
            for failure in sent.failedRecordSaves {
                let name = failure.record.recordID.recordName
                guard let change = inFlight.removeValue(forKey: name) else { continue }
                switch failure.error.code {
                case .serverRecordChanged:
                    if let serverRecord = failure.error.serverRecord,
                       let record = CloudKitRecordCoding.syncRecord(from: serverRecord, storeAsset: { url in
                           storePreview(at: url, of: serverRecord)
                       }) {
                        coordinator.saveConflicted(change, serverRecord: record, recordName: name, systemFields: CloudKitRecordCoding.encodeSystemFields(serverRecord))
                    } else {
                        coordinator.sendRefused(change)
                    }
                case .unknownItem:
                    coordinator.saveFailedBecauseRecordIsGone(change)
                case .zoneNotFound:
                    if scope == .privateDatabase {
                        syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
                    } else {
                        shareEnded()
                    }
                default:
                    handleFailure(failure.error, change: change)
                }
            }
            for recordID in sent.deletedRecordIDs {
                if let change = inFlight.removeValue(forKey: recordID.recordName) {
                    coordinator.didDelete(change)
                }
            }
            for (recordID, error) in sent.failedRecordDeletes {
                guard let change = inFlight.removeValue(forKey: recordID.recordName) else { continue }
                if error.code == .unknownItem {
                    // Already gone: that is what was wanted.
                    coordinator.didDelete(change)
                } else {
                    handleFailure(error, change: change)
                }
            }
            saveLocal()
            mirrorPendingIntoEngine()

        case .fetchedDatabaseChanges(let changes):
            if changes.deletions.contains(where: { $0.zoneID == zoneID }) {
                // The owner stopped sharing (or, on the owner's Mac, it was
                // stopped on his other Mac).
                shareEnded()
            }

        case .didFetchChanges:
            // The first download is done; from now on new words are news.
            announcesArrivals = true
            status.lastSync = .now
            publish()

        case .didSendChanges:
            status.lastSync = .now
            publish()

        default:
            break
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let outgoing = coordinator.outgoingBatch(limit: 300)
        guard !outgoing.isEmpty else { return nil }
        var toSave: [CKRecord] = []
        var toDelete: [CKRecord.ID] = []
        for item in outgoing {
            switch item {
            case .save(let record, let name, let systemFields, let change):
                let ckRecord = CloudKitRecordCoding.ckRecord(
                    from: record,
                    recordName: name,
                    zoneID: zoneID,
                    systemFields: systemFields,
                    assetFile: { [previews] asset in
                        let mediaID = record.fields["mediaID"]?.stringValue ?? ""
                        let url = previews.url(mediaID: mediaID)
                        return FileManager.default.fileExists(atPath: url.path) ? url : nil
                    }
                )
                inFlight[name] = change
                toSave.append(ckRecord)
            case .delete(_, let name, let change):
                inFlight[name] = change
                toDelete.append(CKRecord.ID(recordName: name, zoneID: zoneID))
            }
        }
        return CKSyncEngine.RecordZoneChangeBatch(recordsToSave: toSave, recordIDsToDelete: toDelete, atomicByZone: false)
    }

    // MARK: Helpers

    /// Tells the engine there is something to send. The coordinator's queue
    /// is the source of truth; the engine only needs to know to call back.
    private func mirrorPendingIntoEngine() {
        status.pendingCount = coordinator.pending.count
        publish()
        guard let engine, !coordinator.pending.isEmpty else { return }
        let known = Set(engine.state.pendingRecordZoneChanges.map { change -> String in
            switch change {
            case .saveRecord(let id), .deleteRecord(let id): return id.recordName
            @unknown default: return ""
            }
        })
        var additions: [CKSyncEngine.PendingRecordZoneChange] = []
        for item in coordinator.outgoingBatch(limit: 500) {
            switch item {
            case .save(_, let name, _, _) where !known.contains(name):
                additions.append(.saveRecord(CKRecord.ID(recordName: name, zoneID: zoneID)))
            case .delete(_, let name, _) where !known.contains(name):
                additions.append(.deleteRecord(CKRecord.ID(recordName: name, zoneID: zoneID)))
            default:
                break
            }
        }
        if !additions.isEmpty { engine.state.add(pendingRecordZoneChanges: additions) }
    }

    /// Errors CloudKit may clear by itself are left to `CKSyncEngine`,
    /// which retries them; anything else is dropped from the queue (the next
    /// edit queues the record again), so a refused change is not resent
    /// forever.
    private func handleFailure(_ error: CKError, change: SyncPendingChange) {
        switch error.code {
        case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited,
             .zoneBusy, .notAuthenticated, .accountTemporarilyUnavailable, .operationCancelled:
            break
        default:
            coordinator.sendRefused(change)
        }
        report(error: error)
    }

    private func shareEnded() {
        engine = nil
        inFlight.removeAll()
        try? state.reset()
        onShareEnded?()
    }

    /// Copies a fetched preview next to the others and describes it. The
    /// photo it belongs to is in the record's `mediaID` field.
    private func storePreview(at url: URL, of record: CKRecord) -> SyncAssetRef? {
        guard let data = try? Data(contentsOf: url),
              let mediaID = record["mediaID"] as? String else { return nil }
        _ = try? previews.write(data, mediaID: mediaID)
        return SyncAssetRef(sha256: SharedPreview.sha256(data), byteCount: data.count, pixelWidth: 0, pixelHeight: 0)
    }

    private func saveLocal() {
        do {
            try store.save()
            try coordinator.flush()
        } catch {
            report(error: error)
        }
    }

    private func report(error: Error) {
        status.lastError = error.localizedDescription
        publish()
    }

    private func publish() {
        status.pendingCount = coordinator.pending.count
        onStatus?(status)
    }
}
