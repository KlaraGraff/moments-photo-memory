import Foundation
import MomentsCore
import SwiftData

/// Which imported folders can still be found. A folder moved on the same
/// disk is followed by its bookmark and quietly gets a fresh one; a folder
/// moved to another disk, renamed together with its disk, deleted, or on a
/// drive that isn't connected is reported missing. Never mounts a drive or
/// shows a dialog, and runs in its own context, off the main thread.
enum FolderLocations {
    struct Missing: Equatable, Identifiable, Sendable {
        let id: String
        let name: String
    }

    static func check(in container: ModelContainer, accountID: String = MomentsAccount.localID) -> [Missing] {
        let context = ModelContext(container)
        var missing: [Missing] = []
        var refreshed = false
        for location in ImportSources.folderLocations(accountID: accountID, context: context) {
            let (url, isStale) = resolve(location.bookmark, path: location.path)
            var exists = false
            if let url {
                var isDirectory: ObjCBool = false
                exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
                    // A folder in the Trash is on its way out.
                    && !url.standardizedFileURL.path.contains("/.Trash/")
            }
            switch FolderLocationCheck.classify(resolved: url != nil, isStale: isStale, existsAsFolder: exists) {
            case .found:
                if let url, ImportSources.locationKey(for: url) != location.path {
                    ImportSources.refreshBookmark(sourceID: location.id, folder: url, context: context)
                    refreshed = true
                }
            case .foundWithStaleBookmark:
                if let url {
                    ImportSources.refreshBookmark(sourceID: location.id, folder: url, context: context)
                    refreshed = true
                }
            case .missing:
                missing.append(Missing(id: location.id, name: location.name))
            }
        }
        if refreshed { try? context.save() }
        return missing
    }

    private static func resolve(_ bookmark: Data?, path: String) -> (URL?, Bool) {
        guard let bookmark else { return (URL(fileURLWithPath: path, isDirectory: true), false) }
        var isStale = false
        let options: URL.BookmarkResolutionOptions = [.withoutUI, .withoutMounting]
        if let url = try? URL(resolvingBookmarkData: bookmark, options: options.union(.withSecurityScope), relativeTo: nil, bookmarkDataIsStale: &isStale) {
            return (url, isStale)
        }
        if let url = try? URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &isStale) {
            return (url, isStale)
        }
        return (nil, false)
    }
}
