import Foundation
@testable import MomentsCore

/// Synthetic records for the sync tests. No real names, places or dates.
enum SyncFixtures {
    static let ownerAccount = "_owner0000000000000000000000000001"
    static let partnerAccount = "_partner00000000000000000000000002"
    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    static func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    static func trip(_ id: String, name: String = "Synthetic trip", at seconds: Double = 0) -> SyncRecord {
        SyncRecord(type: .trip, id: id, fields: [
            "name": .string(name),
            "updatedAt": .date(at(seconds))
        ])
    }

    static func place(_ id: String, name: String, parent: String? = nil) -> SyncRecord {
        var record = SyncRecord(type: .place, id: id, fields: [
            "name": .string(name),
            "kindRaw": .string("spot"),
            "latitude": .double(0.01),
            "longitude": .double(0.02),
            "updatedAt": .date(t0)
        ])
        if let parent { record["parentID"] = .reference(parent) }
        return record
    }

    static func media(_ id: String, trip: String?, place: String? = nil, day: String = "2023-11-14") -> SyncRecord {
        var record = SyncRecord(type: .mediaItem, id: id, fields: [
            "captureDate": .date(t0),
            "kindRaw": .string("photo"),
            "width": .int(4000),
            "height": .int(3000),
            "isScreenshot": .bool(false),
            "localDayKey": .string(day),
            "updatedAt": .date(t0)
        ])
        if let trip { record["tripID"] = .reference(trip) }
        if let place { record["placeID"] = .reference(place) }
        return record
    }

    static func memory(_ id: String, media: String, text: String, author: String = SyncAccountMap.localAlias, at seconds: Double = 0) -> SyncRecord {
        SyncRecord(type: .memory, id: id, fields: [
            "mediaID": .reference(media),
            "text": .string(text),
            "authorAccountID": .string(author),
            "createdAt": .date(t0),
            "revision": .int(1),
            "updatedAt": .date(at(seconds)),
            "updatedBy": .string(author)
        ])
    }

    static func comment(_ id: String, memory: String, parent: String? = nil, text: String, author: String = SyncAccountMap.localAlias, at seconds: Double = 0) -> SyncRecord {
        var record = SyncRecord(type: .comment, id: id, fields: [
            "memoryID": .reference(memory),
            "text": .string(text),
            "authorAccountID": .string(author),
            "createdAt": .date(at(seconds)),
            "updatedAt": .date(at(seconds))
        ])
        if let parent { record["parentCommentID"] = .reference(parent) }
        return record
    }

    static func favorite(media: String, account: String = SyncAccountMap.localAlias, on: Bool, at seconds: Double = 0) -> SyncRecord {
        SyncRecord(type: .favorite, id: "\(media):\(account)", fields: [
            "mediaID": .reference(media),
            "accountID": .string(account),
            "isFavorite": .bool(on),
            "changedAt": .date(at(seconds))
        ])
    }

    static func tag(_ id: String, name: String) -> SyncRecord {
        SyncRecord(type: .tag, id: id, fields: [
            "normalizedName": .string(name.lowercased()),
            "displayName": .string(name),
            "updatedAt": .date(t0)
        ])
    }

    static func mediaTag(media: String, tag: String) -> SyncRecord {
        SyncRecord(type: .mediaTag, id: "\(media):\(tag)", fields: [
            "mediaID": .reference(media),
            "tagID": .reference(tag),
            "updatedAt": .date(t0)
        ])
    }

    static func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("moments-sync-tests-" + UUID().uuidString, isDirectory: true)
    }
}

/// One device: its local records, its sync state and its connection.
final class SimulatedDevice {
    let local: InMemorySyncLocalStore
    let coordinator: SyncCoordinator
    let driver: InMemorySyncDriver
    let folder: URL

    init(account: String, partner: String?, server: InMemorySyncServer, database: SyncDatabaseScope, records: [SyncRecord] = []) throws {
        let folder = SyncFixtures.temporaryFolder()
        let state: SyncStateStore = try SyncStateStore(folder: folder)
        let local = InMemorySyncLocalStore(records)
        let accounts = SyncAccountMap(currentAccountID: account, partnerAccountID: partner)
        let coordinator = SyncCoordinator(accounts: accounts, state: state, database: database, local: local)
        self.folder = folder
        self.local = local
        self.coordinator = coordinator
        self.driver = InMemorySyncDriver(coordinator: coordinator, server: server)
    }

    /// A local edit the app reports to the sync layer.
    func edit(_ record: SyncRecord) {
        local.write(record)
        coordinator.localRecordChanged(record.key)
    }

    func delete(_ key: SyncRecordKey) {
        local.remove(key)
        coordinator.localRecordDeleted(key)
    }

    func text(of memoryID: String) -> String? {
        local.record(for: SyncRecordKey(.memory, memoryID))?["text"]?.stringValue
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }
}
