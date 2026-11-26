import AppKit
import CloudKit
import Foundation
import MomentsCore
import Observation
import Security
import SwiftData

/// Everything the Sharing page and the trip "Share" actions need: whether
/// sharing can work on this Mac, who is on the share, which trips are shared,
/// and how syncing is going. It owns the one `CloudSyncEngine` this Mac runs.
///
/// Nothing touches iCloud until the app is built with a CloudKit container
/// (Info.plist key `MomentsCloudKitContainerIdentifier` and the matching
/// iCloud entitlement, which only the signed build carries) and the person is
/// signed in to iCloud. Unit tests and the unsigned
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
    /// The engine's own context: its saves are fetched changes, not edits.
    private var engineContextID: ObjectIdentifier?
    private var saveObserver: NSObjectProtocol?
    private var pendingReconcile: Task<Void, Never>?

    /// The container identifier from Info.plist, if this build has a real one.
    static var configuredContainerIdentifier: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: containerInfoKey) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("iCloud."), !trimmed.contains("$("),
              // Every build has the Info.plist key; only a signed one may
              // use the container (CloudKit stops an app that isn't
              // entitled). Tests never reach iCloud.
              isEntitled(toContainer: trimmed),
              NSClassFromString("XCTestCase") == nil else { return nil }
        return trimmed
    }

    private static func isEntitled(toContainer identifier: String) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil),
              let containers = value as? [String] else { return false }
        return containers.contains(identifier)
    }

    /// An invitation opened before the main window set the controller up.
    static var pendingInvitation: CKShare.Metadata?

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
        Task {
            await refresh()
            if let invitation = Self.pendingInvitation {
                Self.pendingInvitation = nil
                await accept(invitation)
            }
        }
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

    /// The share for the system sharing panel (Messages, Mail, copy link),
    /// or nil with `lastError` set.
    func shareForInvitation(tripIDs: Set<String>) async -> CKShare? {
        do {
            lastError = nil
            return try await makeShare(tripIDs: tripIDs)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Creates the shared zone and the share. The first time, `tripIDs`
    /// becomes the shared set; sending the invitation again reuses the share
    /// and leaves the shared trips as they are.
    func makeShare(tripIDs: Set<String>) async throws -> CKShare {
        guard let cloud, let accounts, let store = settingsStore else { throw SharingError.notReady }
        let database = cloud.privateCloudDatabase
        let zone = CKRecordZone(zoneName: Self.zoneName)
        let zones = try await database.modifyRecordZones(saving: [zone], deleting: [])
        if case .failure(let error)? = zones.saveResults[zone.zoneID] { throw error }
        let share: CKShare
        if let existing = try await existingShare(in: database, zoneID: zone.zoneID) {
            share = existing
        } else {
            let created = CKShare(recordZoneID: zone.zoneID)
            created[CKShare.SystemFieldKey.title] = String(localized: "Our memories") as NSString
            created.publicPermission = .none
            let saved = try await database.modifyRecords(saving: [created], deleting: [])
            switch saved.saveResults[created.recordID] {
            case .success(let record)?:
                guard let savedShare = record as? CKShare else { throw SharingError.notReady }
                share = savedShare
            case .failure(let error)?:
                throw error
            case nil:
                throw SharingError.notReady
            }
        }
        if settings.role != .owner {
            settings.role = .owner
            settings.scope = .selectedTrips(tripIDs)
            settings.zoneOwnerName = accounts.currentAccountID
            try store.saveSettings(settings)
            if case .selectedTrips(let ids) = settings.scope { sharedTripIDs = ids }
        }
        if phase != .shared(isOwner: true) { phase = .invited }
        try startEngine(folder: store.folder)
        scheduleSync(after: 0)
        return share
    }

    /// The zone-wide share, or nil when there is none yet. Other errors
    /// (offline, signed out) are thrown, so a failed read never makes a
    /// second share.
    private func existingShare(in database: CKDatabase, zoneID: CKRecordZone.ID) async throws -> CKShare? {
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        do {
            return try await database.record(for: shareID) as? CKShare
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
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
            engineContextID = nil
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
        let found: CKShare?
        do {
            found = try await existingShare(in: cloud.privateCloudDatabase, zoneID: zoneID)
        } catch {
            // Offline or busy: keep what was known, and let the engine
            // start; it syncs once the network is back.
            phase = settings.partnerAccountID == nil ? .invited : .shared(isOwner: true)
            return
        }
        guard let share = found else {
            // The zone and share are gone (stopped on his other Mac).
            await shareEnded()
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
            engineContextID = nil
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

    /// The share ended elsewhere: the owner stopped sharing, or (on the
    /// owner's Mac) it was stopped on his other Mac. Sync state is
    /// forgotten; on the partner's Mac the shared trips leave too, as the
    /// owner's confirmation said.
    func shareEnded() async {
        guard let store = settingsStore else { return }
        let wasParticipant = settings.role == .participant
        await engine?.forget()
        engine = nil
        engineContextID = nil
        do {
            if wasParticipant { try removeReceivedRecords() }
            try store.reset()
        } catch {
            lastError = error.localizedDescription
        }
        settings = SyncStateStore.Settings()
        sharedTripIDs = []
        phase = .notShared
    }

    /// Photos that came from the other Mac, and the trips that held only them.
    private func removeReceivedRecords() throws {
        guard let modelContainer else { return }
        let context = ModelContext(modelContainer)
        let shared = SyncModelCoding.sharedSourceRaw
        let items = try context.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.sourceRaw == shared }))
        var tripIDs = Set<String>()
        let previews = SharedPreviewFiles.standard
        for item in items {
            if let trip = item.trip?.id { tripIDs.insert(trip) }
            previews?.remove(mediaID: item.id)
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
        engineContextID = engine.contextID
        let handler: @Sendable (CloudSyncEngine.Status) -> Void = { [weak self] status in
            Task { @MainActor in self?.sync = status }
        }
        let ended: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in await self?.shareEnded() }
        }
        Task {
            await engine.setStatusHandler(handler)
            await engine.setShareEndedHandler(ended)
            await engine.start()
        }
        observeSaves()
        scheduleSync(after: 0)
    }

    /// Any save in the app schedules one reconcile-and-sync a moment later,
    /// so a burst of edits is sent together.
    private func observeSaves() {
        guard saveObserver == nil else { return }
        saveObserver = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] note in
            let source = note.object.map { ObjectIdentifier($0 as AnyObject) }
            Task { @MainActor [weak self] in
                guard let self, source == nil || source != self.engineContextID else { return }
                self.scheduleSync(after: 2)
            }
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
