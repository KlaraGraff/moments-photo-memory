import Foundation
import SwiftData

/// Where photos were imported from: a folder on this Mac, or Apple Photos.
/// Lets someone take a whole folder back out of Moments. The folder's path
/// is kept only in the local store, to recognise the folder when it is
/// imported again; nothing on disk is ever changed.
@Model
public final class ImportSource {
    public enum Kind: String, Codable, Sendable {
        case folder
        case photos
    }

    public var id: String
    public var kindRaw: String
    public var name: String
    /// The folder's standardized path; `nil` for Apple Photos.
    public var locationKey: String?
    public var bookmarkData: Data?
    public var ownerAccountID: String
    public var addedAt: Date
    public var lastImportedAt: Date?

    public init(
        id: String = UUID().uuidString,
        kind: Kind,
        name: String,
        locationKey: String? = nil,
        bookmarkData: Data? = nil,
        ownerAccountID: String = MomentsAccount.localID,
        addedAt: Date = .now,
        lastImportedAt: Date? = nil
    ) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.name = name
        self.locationKey = locationKey
        self.bookmarkData = bookmarkData
        self.ownerAccountID = ownerAccountID
        self.addedAt = addedAt
        self.lastImportedAt = lastImportedAt
    }

    public var kind: Kind {
        get { Kind(rawValue: kindRaw) ?? .folder }
        set { kindRaw = newValue.rawValue }
    }
}

extension MediaItem {
    /// The ``ImportSource`` ids this photo was found in.
    var importSourceIDs: [String] {
        get { (importSourceIDsRaw ?? "").split(separator: "\n").map(String.init) }
        set { importSourceIDsRaw = newValue.isEmpty ? nil : newValue.joined(separator: "\n") }
    }

    func addImportSource(_ id: String) {
        guard !importSourceIDs.contains(id) else { return }
        importSourceIDs.append(id)
    }
}

enum ImportSources {
    /// One row in Settings: a source and how many of its photos are in Moments.
    struct Summary: Identifiable, Equatable {
        let id: String
        let kind: ImportSource.Kind
        let name: String
        let location: String?
        let itemCount: Int
    }

    static func locationKey(for folder: URL) -> String {
        folder.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// The source for a folder being imported: the one recorded for the same
    /// folder before, or a new one.
    static func folderSource(for folder: URL, accountID: String = MomentsAccount.localID, now: Date = .now, context: ModelContext) -> ImportSource {
        // Optional, to compare with the optional column inside the predicate.
        let key: String? = locationKey(for: folder)
        let folderKind = ImportSource.Kind.folder.rawValue
        let existing = (try? context.fetch(FetchDescriptor<ImportSource>(predicate: #Predicate {
            $0.kindRaw == folderKind && $0.locationKey == key && $0.ownerAccountID == accountID
        })))?.first
        let source = existing ?? {
            let created = ImportSource(kind: .folder, name: folder.lastPathComponent, locationKey: key, ownerAccountID: accountID, addedAt: now)
            context.insert(created)
            return created
        }()
        source.lastImportedAt = now
        if source.bookmarkData == nil {
            source.bookmarkData = try? folder.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        return source
    }

    /// The one Apple Photos source of `accountID`, made when first needed.
    static func photosSource(accountID: String = MomentsAccount.localID, now: Date = .now, context: ModelContext) -> ImportSource {
        let photosKind = ImportSource.Kind.photos.rawValue
        if let existing = (try? context.fetch(FetchDescriptor<ImportSource>(predicate: #Predicate {
            $0.kindRaw == photosKind && $0.ownerAccountID == accountID
        })))?.first {
            return existing
        }
        let created = ImportSource(kind: .photos, name: "Apple Photos", ownerAccountID: accountID, addedAt: now)
        context.insert(created)
        return created
    }

    /// Records sources for photos imported before sources were kept: each
    /// folder photo is filed under the outermost imported folder that holds
    /// it. Photos whose file can no longer be found share one source.
    /// Runs once per photo; later calls only see photos without a source.
    static func backfill(accountID: String = MomentsAccount.localID, context: ModelContext) {
        let fileSource = MediaSource.file.rawValue
        let photosSourceRaw = MediaSource.photos.rawValue
        // Not photos in Recently Deleted: removing their source just unlinked them.
        let items = (try? context.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate {
            $0.sourceRaw == fileSource && $0.importSourceIDsRaw == nil && $0.deletedAt == nil
        }))) ?? []
        let mine = items.filter { RecentlyDeleted.canDelete($0, accountID: accountID) }
        var changed = false
        if !mine.isEmpty {
            var folderByItem: [String: String] = [:]
            for item in mine {
                guard let data = item.originalBookmarkData, let url = try? OriginalMediaBookmark.resolve(data).url else { continue }
                folderByItem[item.id] = locationKey(for: url.deletingLastPathComponent())
            }
            let roots = outermostFolders(Set(folderByItem.values))
            let folderKind = ImportSource.Kind.folder.rawValue
            let known = (try? context.fetch(FetchDescriptor<ImportSource>(predicate: #Predicate { $0.kindRaw == folderKind && $0.ownerAccountID == accountID }))) ?? []
            var sourceByRoot = Dictionary(known.compactMap { source in source.locationKey.map { ($0, source) } }, uniquingKeysWith: { first, _ in first })
            var unknownSource = known.first { $0.locationKey == nil }
            for item in mine {
                let source: ImportSource
                if let folder = folderByItem[item.id], let root = roots.first(where: { contains($0, folder) }) {
                    if let existing = sourceByRoot[root] {
                        source = existing
                    } else {
                        let created = ImportSource(kind: .folder, name: URL(fileURLWithPath: root).lastPathComponent, locationKey: root, ownerAccountID: accountID, addedAt: item.importedAt ?? .now)
                        context.insert(created)
                        sourceByRoot[root] = created
                        source = created
                    }
                } else {
                    if unknownSource == nil {
                        let created = ImportSource(kind: .folder, name: String(localized: "Folders that moved"), ownerAccountID: accountID, addedAt: item.importedAt ?? .now)
                        context.insert(created)
                        unknownSource = created
                    }
                    source = unknownSource!
                }
                item.addImportSource(source.id)
            }
            changed = true
        }
        let photosItems = (try? context.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.sourceRaw == photosSourceRaw && $0.deletedAt == nil }))) ?? []
        let hasPhotos = photosItems.contains { RecentlyDeleted.canDelete($0, accountID: accountID) }
        let photosKind = ImportSource.Kind.photos.rawValue
        let hasPhotosSource = ((try? context.fetchCount(FetchDescriptor<ImportSource>(predicate: #Predicate { $0.kindRaw == photosKind && $0.ownerAccountID == accountID }))) ?? 0) > 0
        if hasPhotos && !hasPhotosSource {
            _ = photosSource(accountID: accountID, context: context)
            changed = true
        }
        if changed { try? context.save() }
    }

    /// The folders not inside another one of the set.
    static func outermostFolders(_ folders: Set<String>) -> [String] {
        let sorted = folders.sorted { $0.count < $1.count }
        var roots: [String] = []
        for folder in sorted where !roots.contains(where: { contains($0, folder) }) {
            roots.append(folder)
        }
        return roots
    }

    /// True when `folder` is `root` or inside it.
    static func contains(_ root: String, _ folder: String) -> Bool {
        folder == root || folder.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// The photos of a source still in the library (not in Recently Deleted).
    static func items(of source: ImportSource, context: ModelContext) -> [MediaItem] {
        let owner = source.ownerAccountID
        let live = (try? context.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.deletedAt == nil }))) ?? []
        switch source.kind {
        case .photos:
            return live.filter { $0.source == .photos && ($0.ownerAccountID ?? MomentsAccount.localID) == owner }
        case .folder:
            let id = source.id
            return live.filter { $0.importSourceIDs.contains(id) }
        }
    }

    static func summaries(accountID: String = MomentsAccount.localID, context: ModelContext) -> [Summary] {
        let sources = (try? context.fetch(FetchDescriptor<ImportSource>(predicate: #Predicate { $0.ownerAccountID == accountID }))) ?? []
        let live = (try? context.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.deletedAt == nil }))) ?? []
        var countBySource: [String: Int] = [:]
        var photosCount = 0
        for item in live where RecentlyDeleted.canDelete(item, accountID: accountID) {
            if item.source == .photos { photosCount += 1 }
            for id in item.importSourceIDs { countBySource[id, default: 0] += 1 }
        }
        return sources.map { source in
            Summary(
                id: source.id,
                kind: source.kind,
                name: source.name,
                location: source.locationKey.map { ($0 as NSString).abbreviatingWithTildeInPath },
                itemCount: source.kind == .photos ? photosCount : countBySource[source.id] ?? 0
            )
        }
        // Apple Photos first, then folders by name.
        .sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind == .photos }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Takes a source out of Moments: its photos move to Recently Deleted
    /// (for 30 days, recoverable), except photos that another source still
    /// holds. The folder and its files, or Apple Photos, stay as they are.
    /// Returns how many photos moved.
    @MainActor
    @discardableResult
    static func remove(_ source: ImportSource, accountID: String = MomentsAccount.localID, now: Date = .now, context: ModelContext) -> Int {
        guard source.ownerAccountID == accountID else { return 0 }
        var leaving: [MediaItem] = []
        switch source.kind {
        case .photos:
            leaving = items(of: source, context: context)
        case .folder:
            let id = source.id
            // Also unlink the photos already in Recently Deleted, so a later
            // recover doesn't tie them to a source that is gone.
            let all = (try? context.fetch(FetchDescriptor<MediaItem>())) ?? []
            for item in all where item.importSourceIDs.contains(id) {
                item.importSourceIDs.removeAll { $0 == id }
                // Kept if another folder still holds it.
                if item.importSourceIDs.isEmpty, item.deletedAt == nil { leaving.append(item) }
            }
        }
        context.delete(source)
        let moved = RecentlyDeleted.moveToTrash(leaving, accountID: accountID, now: now, context: context)
        try? context.save()
        return moved.count
    }
}
