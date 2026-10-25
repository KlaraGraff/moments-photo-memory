import AppKit
import CloudKit
import Foundation

/// The UI-facing author labels used by Moments. The CloudKit identity that produced
/// a memory is stored separately; this enum is derived at display time.
enum MemoryAuthor: String {
    case me
    case partner
}

enum SharingSpikeError: Error {
    case missingCurrentUserRecordID
}

struct SharingShape {
    static let containerIdentifier = "iCloud.org.example.Moments"
    static let zoneName = "moments-shared"

    /// The owner creates this custom zone in the private database. A participant
    /// sees a corresponding zone in their shared database after accepting the share.
    static func makeZone() -> CKRecordZone {
        let zoneID = CKRecordZone.ID(
            zoneName: zoneName,
            ownerName: CKCurrentUserDefaultName
        )
        return CKRecordZone(zoneID: zoneID)
    }

    /// A zone-wide share includes records in the custom zone. The share is saved
    /// together with its records using CKModifyRecordsOperation in the real app.
    static func makeShare(for zone: CKRecordZone) -> CKShare {
        let share = CKShare(recordZoneID: zone.zoneID)
        share[CKShare.SystemFieldKey.title] = "Moments shared memories"
        share[CKShare.SystemFieldKey.shareType] = "org.example.Moments.shared-zone"
        share.publicPermission = .none
        return share
    }

    /// This is the app-delegate/share-invitation shape. The real app receives
    /// metadata from NSApplicationDelegate and then accepts it on the container.
    static func acceptShare(
        _ metadata: CKShare.Metadata,
        container: CKContainer = CKContainer(identifier: containerIdentifier)
    ) async throws -> CKShare {
        try await container.accept(metadata)
    }

    /// Resolve the stable CloudKit user record ID to the two UI labels. Do not
    /// persist names, email addresses, or phone numbers. `currentUserRecordID`
    /// comes from CKContainer.fetchUserRecordID().
    static func mapAuthor(
        participant: CKShare.Participant,
        currentUserRecordID: CKRecord.ID,
        ownerRecordID: CKRecord.ID
    ) -> MemoryAuthor? {
        if participant.userIdentity.userRecordID == currentUserRecordID {
            return .me
        }
        if participant.userIdentity.userRecordID == ownerRecordID {
            return .partner
        }
        return nil
    }

    /// The sync engine is configured once per database scope. The owner uses the
    /// private database; an invited participant uses the shared database.
    static func makeSyncConfiguration(
        database: CKDatabase,
        delegate: CKSyncEngineDelegate,
        state: CKSyncEngine.State.Serialization? = nil
    ) -> CKSyncEngine.Configuration {
        CKSyncEngine.Configuration(
            database: database,
            stateSerialization: state,
            delegate: delegate
        )
    }
}

/// macOS delivers a share URL through this app-delegate callback after the
/// system has produced CKShare.Metadata. The real app would route the accepted
/// share to its shared-database sync coordinator.
final class ShareAcceptanceHandler: NSObject, NSApplicationDelegate {
    func application(
        _ application: NSApplication,
        userDidAcceptCloudKitShareWith metadata: CKShare.Metadata
    ) {
        Task {
            _ = try? await SharingShape.acceptShare(metadata)
        }
    }
}

let zone = SharingShape.makeZone()
let share = SharingShape.makeShare(for: zone)
print("SharingSpike compiles: \(zone.zoneID.zoneName), \(share.recordID.recordName)")
print("Network calls are intentionally not made by this throwaway executable.")
