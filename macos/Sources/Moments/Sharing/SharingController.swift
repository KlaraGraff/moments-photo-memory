import AppKit
import CloudKit
import Foundation
import MomentsCore
import Observation
import SwiftData

/// Everything the Sharing page and the trip "Share" actions need: whether
/// sharing can work on this Mac, who is on the share, which trips are shared,
/// and how syncing is going. It owns the one `CloudSyncEngine` this Mac runs.
///
/// Nothing touches iCloud until the app is built with a CloudKit container
/// (Info.plist key `MomentsCloudKitContainerIdentifier`, set by the signed
/// build) and the person is signed in to iCloud. Unit tests and the unsigned
/// CI build therefore never reach CloudKit.
@MainActor
@Observable
final class SharingController {
    enum Phase: Equatable {
        /// This build has no CloudKit container (CI, tests, unsigned builds).
        case unavailable
        case checking
        case signedOut
        /// Signed in, nothing shared yet.
        case notShared
        /// The owner made the share; the partner has not accepted yet.
        case invited
        /// Both are on the share. `isOwner` is false on the partner's Mac.
        case shared(isOwner: Bool)
    }

    static let containerInfoKey = "MomentsCloudKitContainerIdentifier"
    static let zoneName = SyncStateStore.defaultZoneName

    /// The controller the app delegate hands invitations to.
    static weak var current: SharingController?

    private(set) var phase: Phase = .checking
    /// A trip someone pressed "Share" on before sharing was set up; the
    /// Sharing page starts with it chosen.
    private(set) var preselectedTripIDs: Set<String> = []
    private(set) var sharedTripIDs: Set<String> = []
    private(set) var sync = CloudSyncEngine.Status()
    private(set) var partnerJoinedAt: Date?
    private(set) var lastError: String?

    private var modelContainer: ModelContainer?
    private var cloud: CKContainer?
    private var accounts: SyncAccountMap?
    private var settingsStore: SyncStateStore?
    private var settings = SyncStateStore.Settings()
    private var engine: CloudSyncEngine?
    private var saveObserver: NSObjectProtocol?
    private var pendingReconcile: Task<Void, Never>?

    /// The container identifier from Info.plist, if this build has a real one.
    static var configuredContainerIdentifier: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: containerInfoKey) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("iCloud."), !trimmed.contains("$(") else { return nil }
        return trimmed
    }

    static var stateRoot: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "Moments", directoryHint: .isDirectory)
            .appending(path: "Sync", directoryHint: .isDirectory)
    }

    func configure(container: ModelContainer) {
        guard modelContainer == nil else { return }
        modelContainer = container
        Self.current = self
        guard let identifier = Self.configuredContainerIdentifier else {
            phase = .unavailable
            return
        }
        cloud = CKContainer(identifier: identifier)
        Task { await refresh() }
    }

    /// Reads the iCloud account and the share, and starts syncing if there is
    /// something to sync.
    func refresh() async {
        guard let cloud, let root = Self.stateRoot else {
            phase = .unavailable
            return
        }
        do {
            guard try await cloud.accountStatus() == .available else {
                phase = .signedOut
                return
            }
            let userID = try await cloud.userRecordID().recordName
            let folder = SyncStateStore.accountFolder(root: root, accountID: userID)
            let store = try SyncStateStore(folder: folder)
            settingsStore = store
            settings = store.loadSettings()
            accounts = SyncAccountMap(currentAccountID: userID, partnerAccountID: settings.partnerAccountID)
            if case .selectedTrips(let ids) = settings.scope { sharedTripIDs = ids }
            switch settings.role {
            case .owner?:
                try await refreshOwnerShare()
                try startEngine(folder: folder)
            case .participant?:
                phase = .shared(isOwner: false)
                try startEngine(folder: folder)
            case nil:
                phase = .notShared
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Owner

    /// Creates the shared zone and the share for the chosen trips, and returns
    /// the share for the system sharing panel (Messages, Mail, copy link).
    func makeShare(tripIDs: Set<String>) async throws -> CKShare {
        guard let cloud, let accounts, let store = settingsStore else { throw SharingError.notReady }
        let database = cloud.privateCloudDatabase
        let zone = CKRecordZone(zoneName: Self.zoneName)
        _ = try await database.modifyRecordZones(saving: [zone], deleting: [])
        let share: CKShare
        if let existing = try? await database.record(for: CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zone.zoneID)) as? CKShare {
            share = existing
        } else {
            let created = CKShare(recordZoneID: zone.zoneID)
            created[CKShare.SystemFieldKey.title] = String(localized: "Our memories") as NSString
            created.publicPermission = .none
            _ = try await database.modifyRecords(saving: [created], deleting: [])
            share = created
        }
        settings.role = .owner
        settings.scope = .selectedTrips(tripIDs)
        settings.zoneOwnerName = accounts.currentAccountID
        try store.saveSettings(settings)
        sharedTripIDs = tripIDs
        phase = .invited
        try startEngine(folder: store.folder)
        scheduleSync(after: 0)
        return share
    }

    /// The item the system sharing panel needs to invite the partner.
    func invitationItem(for share: CKShare) -> NSItemProvider? {
        guard let cloud else { return nil }
        let provider = NSItemProvider()
        let options = CKAllowedSharingOptions(
            allowedParticipantPermissionOptions: .readWrite,
            allowedParticipantAccessOptions: .specifiedRecipientsOnly
        )
        provider.registerCKShare(share, container: cloud, allowedSharingOptions: options)
        return provider
    }

    func setTrip(_ tripID: String, shared: Bool) {
        guard settings.role == .owner, let store = settingsStore else { return }
        settings.scope = shared ? settings.scope.adding(tripID: tripID) : settings.scope.removing(tripID: tripID)
        if case .selectedTrips(let ids) = settings.scope { sharedTripIDs = ids }
        try? store.saveSettings(settings)
        scheduleSync(after: 0)
    }

    func preselect(tripID: String) {
        preselectedTripIDs.insert(tripID)
    }

    /// Whether a trip's toolbar shows the Share button: not in a copy that
    /// can't use iCloud, and not for the partner, who shares nothing of
    /// their own.
    var canOfferSharing: Bool {
        switch phase {
        case .unavailable, .shared(isOwner: false): false
        default: true
        }
    }

    func isShared(tripID: String) -> Bool {
        sharedTripIDs.contains(tripID)
    }

    /// Ends the share for both people. The owner's photos and memories stay
    /// on this Mac, including what the partner wrote.
    func stopSharing() async {
        guard let cloud, let store = settingsStore else { return }
        let zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
        do {
            await engine?.forget()
            engine = nil
            _ = try await cloud.privateCloudDatabase.deleteRecordZone(withID: zoneID)
            try store.reset()
            settings = SyncStateStore.Settings()
            sharedTripIDs = []
            phase = .notShared
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func refreshOwnerShare() async throws {
        guard let cloud else { return }
        let zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        guard let share = try? await cloud.privateCloudDatabase.record(for: shareID) as? CKShare else {
            phase = .notShared
            return
        }
        let partner = share.participants.first { $0.role != .owner && $0.acceptanceStatus == .accepted }
        if let partner {
            phase = .shared(isOwner: true)
            if let id = partner.userIdentity.userRecordID?.recordName, id != settings.partnerAccountID {
                settings.partnerAccountID = id
                try? settingsStore?.saveSettings(settings)
                if let current = accounts?.currentAccountID {
                    accounts = SyncAccountMap(currentAccountID: current, partnerAccountID: id)
                }
            }
        } else {
            phase = .invited
        }
    }

    // MARK: Partner

    /// The partner opened the invitation link. Accepts it and starts syncing
    /// the shared zone.
    func accept(_ metadata: CKShare.Metadata) async {
        guard let cloud else { return }
        do {
            _ = try await cloud.accept(metadata)
            await refresh()
            guard let store = settingsStore, let accounts else { return }
            settings.role = .participant
            settings.zoneOwnerName = metadata.share.recordID.zoneID.ownerName
            settings.partnerAccountID = metadata.ownerIdentity.userRecordID?.recordName
            try store.saveSettings(settings)
            self.accounts = SyncAccountMap(currentAccountID: accounts.currentAccountID, partnerAccountID: settings.partnerAccountID)
            phase = .shared(isOwner: false)
            try startEngine(folder: store.folder)
            scheduleSync(after: 0)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Leaves the other person's share. What this person wrote stays on the
    /// owner's Mac; the shared trips leave this Mac.
    func leave() async {
        guard let cloud, let store = settingsStore, let owner = settings.zoneOwnerName else { return }
        let zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: owner)
        do {
            await engine?.forget()
            engine = nil
            let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
            _ = try await cloud.sharedCloudDatabase.deleteRecord(withID: shareID)
            try removeReceivedRecords()
            try store.reset()
            settings = SyncStateStore.Settings()
            phase = .notShared
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Photos that came from the other Mac, and the trips that held only them.
    private func removeReceivedRecords() throws {
        guard let modelContainer else { return }
        let context = ModelContext(modelContainer)
        let shared = SyncModelCoding.sharedSourceRaw
        let items = try context.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.sourceRaw == shared }))
        var tripIDs = Set<String>()
        for item in items {
            if let trip = item.trip?.id { tripIDs.insert(trip) }
            context.delete(item)
        }
        for trip in try context.fetch(FetchDescriptor<Trip>()) where tripIDs.contains(trip.id) && trip.items.allSatisfy({ $0.sourceRaw == shared }) {
            context.delete(trip)
        }
        try context.save()
    }

    // MARK: Syncing

    private func startEngine(folder: URL) throws {
        guard engine == nil, let cloud, let modelContainer, let accounts, let role = settings.role else { return }
        let database = role == .owner ? cloud.privateCloudDatabase : cloud.sharedCloudDatabase
        let zoneOwner = role == .owner ? CKCurrentUserDefaultName : (settings.zoneOwnerName ?? CKCurrentUserDefaultName)
        let engine = try CloudSyncEngine(
            container: modelContainer,
            database: database,
            scope: role == .owner ? .privateDatabase : .sharedDatabase,
            zoneID: CKRecordZone.ID(zoneName: Self.zoneName, ownerName: zoneOwner),
            accounts: accounts,
            stateFolder: folder.appending(path: role.rawValue, directoryHint: .isDirectory),
            previews: SharedPreviewFiles(folder: SharedPreviewFiles.defaultFolder ?? folder.appending(path: "previews"))
        )
        self.engine = engine
        let handler: @Sendable (CloudSyncEngine.Status) -> Void = { [weak self] status in
            Task { @MainActor in self?.sync = status }
        }
        Task {
            await engine.setStatusHandler(handler)
            await engine.start()
        }
        observeSaves()
        scheduleSync(after: 0)
    }

    /// Any save in the app schedules one reconcile-and-sync a moment later,
    /// so a burst of edits is sent together.
    private func observeSaves() {
        guard saveObserver == nil else { return }
        saveObserver = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleSync(after: 2) }
        }
    }

    func scheduleSync(after seconds: Double = 0) {
        guard let engine else { return }
        let scope: SharingScope? = settings.role == .owner ? settings.scope : nil
        pendingReconcile?.cancel()
        pendingReconcile = Task {
            if seconds > 0 { try? await Task.sleep(for: .seconds(seconds)) }
            guard !Task.isCancelled else { return }
            await engine.reconcile(sharingScope: scope)
            await engine.syncNow()
        }
    }
}

enum SharingError: LocalizedError {
    case notReady

    var errorDescription: String? {
        switch self {
        case .notReady: return String(localized: "Sharing is not ready yet. Check that you are signed in to iCloud.")
        }
    }
}

extension CloudSyncEngine {
    /// Stops this engine and forgets its sync state.
    func forget() {
        try? stopAndForget()
    }
}
