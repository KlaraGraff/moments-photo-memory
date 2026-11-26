import Foundation
import MomentsCore
import SwiftData

/// Links from a record to a place that has not arrived yet. SwiftData keeps
/// `Place.parent` and `MediaItem.place` only as relationships, so until the
/// place arrives its ID lives here (and in a small file next to the sync
/// state, so a relaunch does not forget it).
final class SyncOrphanLinks {
    enum Kind: String, Codable {
        case placeParent
        case mediaPlace
    }

    private struct Key: Hashable, Codable {
        var kind: Kind
        var id: String
    }

    private var links: [Key: String] = [:]
    private let file: URL?

    init(file: URL?) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([Key: String].self, from: data) {
            links = saved
        }
    }

    /// The target `id` waits for, or nil.
    func target(_ kind: Kind, of id: String) -> String? {
        links[Key(kind: kind, id: id)]
    }

    /// Records waiting for `targetID`.
    func waiting(_ kind: Kind, on targetID: String) -> [String] {
        links.compactMap { key, value in key.kind == kind && value == targetID ? key.id : nil }.sorted()
    }

    /// Remember (or, with nil, forget) that `id` waits for `targetID`.
    func resolve(_ kind: Kind, of id: String, to targetID: String?) {
        links[Key(kind: kind, id: id)] = targetID
    }

    func save() throws {
        guard let file else { return }
        try JSONEncoder().encode(links).write(to: file, options: .atomic)
    }
}

/// The Mac app's ``SyncLocalStore``: SwiftData through one model context.
///
/// Writes from the server go through ``SyncModelApplier`` and are saved
/// together; while they are applied ``isApplyingRemoteChanges`` is true so
/// the change tracker does not report them back as local edits.
final class SwiftDataSyncStore: SyncLocalStore {
    let context: ModelContext
    let orphans: SyncOrphanLinks
    /// Where previews live; nil in tests that do not sync previews.
    let previews: SharedPreviewFiles?
    private(set) var accounts: SyncAccountMap
    private(set) var isApplyingRemoteChanges = false
    /// Errors while applying are kept for the status line, not thrown into
    /// the engine (which would retry the whole fetch forever).
    private(set) var lastApplyError: Error?

    init(context: ModelContext, accounts: SyncAccountMap, orphans: SyncOrphanLinks, previews: SharedPreviewFiles? = nil) {
        self.context = context
        self.accounts = accounts
        self.orphans = orphans
        self.previews = previews
    }

    func updateAccounts(_ accounts: SyncAccountMap) {
        self.accounts = accounts
    }

    func record(for key: SyncRecordKey) -> SyncRecord? {
        if key.type == .previewAsset { return previewRecord(id: key.id) }
        guard let record = try? SyncModelCoding.record(for: key, in: context) else { return nil }
        return withOrphanLinks(record)
    }

    func apply(_ record: SyncRecord) {
        perform { try applier.apply(record) }
    }

    func applyDeletion(_ key: SyncRecordKey) {
        if key.type == .previewAsset {
            if let mediaID = Self.mediaID(previewID: key.id) { previews?.remove(mediaID: mediaID) }
            return
        }
        perform { try applier.delete(key) }
    }

    /// Every syncable record, with links still waiting for their place, and
    /// a preview record for each photo that has a preview file.
    func allRecords() throws -> [SyncRecord] {
        let records = try SyncModelCoding.allRecords(in: context).map { self.withOrphanLinks($0) }
        guard previews != nil else { return records }
        let previewRecords = records.compactMap { record -> SyncRecord? in
            guard record.type == .mediaItem else { return nil }
            return previewRecord(id: SharedPreview.recordID(mediaID: record.id))
        }
        return records + previewRecords
    }

    /// A preview is described by its file: checksum and size. Pixel sizes and
    /// time are fixed so the description does not change between reads.
    func previewRecord(id: String) -> SyncRecord? {
        guard let mediaID = Self.mediaID(previewID: id), let data = previews?.data(mediaID: mediaID) else { return nil }
        let asset = SyncAssetRef(sha256: SharedPreview.sha256(data), byteCount: data.count, pixelWidth: 0, pixelHeight: 0)
        return SharedPreview.record(mediaID: mediaID, asset: asset, updatedAt: Date(timeIntervalSince1970: 0))
    }

    static func mediaID(previewID: String) -> String? {
        guard previewID.hasPrefix("preview:") else { return nil }
        return String(previewID.dropFirst("preview:".count))
    }

    /// Saves the context and the waiting links. Call after a batch.
    func save() throws {
        if context.hasChanges { try context.save() }
        try orphans.save()
    }

    private var applier: SyncModelApplier {
        SyncModelApplier(context: context, accounts: accounts, orphans: orphans)
    }

    private func perform(_ work: () throws -> Void) {
        isApplyingRemoteChanges = true
        defer { isApplyingRemoteChanges = false }
        do {
            try work()
        } catch {
            lastApplyError = error
        }
    }

    /// A place or photo whose parent place has not arrived still reports the
    /// parent's ID, so it is not mistaken for a local edit that removed it.
    private func withOrphanLinks(_ record: SyncRecord) -> SyncRecord {
        var record = record
        switch record.type {
        case .place where record["parentID"] == nil:
            record.setReference("parentID", orphans.target(.placeParent, of: record.id))
        case .mediaItem where record["placeID"] == nil:
            record.setReference("placeID", orphans.target(.mediaPlace, of: record.id))
        default:
            break
        }
        return record
    }
}
