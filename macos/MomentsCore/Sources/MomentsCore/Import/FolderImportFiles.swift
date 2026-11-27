import Foundation

/// Which files a folder import reads. By file extension, not by content
/// type: a content-type lookup needs LaunchServices, which test hosts and
/// synthetic files don't have.
public enum SupportedMediaFile {
    /// Pictures ImageIO reads on every supported macOS: JPEG, HEIF/HEIC,
    /// PNG, GIF (its first frame), TIFF and WebP.
    public static let pictureExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "hif", "png", "gif", "tif", "tiff", "webp"
    ]
    /// Camera RAW files ImageIO reads: Adobe DNG, Canon, Nikon, Sony,
    /// Fujifilm, Olympus/OM System, Panasonic, Pentax, Samsung, Leica,
    /// Hasselblad, Phase One and Epson.
    public static let rawExtensions: Set<String> = [
        "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf",
        "orf", "rw2", "pef", "srw", "rwl", "3fr", "fff", "iiq", "erf"
    ]
    public static let videoExtensions: Set<String> = ["mov", "mp4"]

    public static func isSupported(pathExtension: String) -> Bool {
        let ext = pathExtension.lowercased()
        return pictureExtensions.contains(ext) || rawExtensions.contains(ext) || videoExtensions.contains(ext)
    }

    public static func isRaw(pathExtension: String) -> Bool {
        rawExtensions.contains(pathExtension.lowercased())
    }

    /// A camera set to RAW+JPEG writes the same shot twice, as IMG_0001.CR3
    /// and IMG_0001.JPG. The JPEG (or HEIF) is kept and the RAW file beside
    /// it is left out, so the shot shows once; a RAW file on its own is
    /// imported. Order is kept.
    public static func droppingRawCompanions(_ files: [URL]) -> [URL] {
        var picturesByFolder: [String: Set<String>] = [:]
        for file in files where pictureExtensions.contains(file.pathExtension.lowercased()) {
            picturesByFolder[folderKey(file), default: []].insert(baseKey(file))
        }
        return files.filter { file in
            guard isRaw(pathExtension: file.pathExtension) else { return true }
            return picturesByFolder[folderKey(file)]?.contains(baseKey(file)) != true
        }
    }

    private static func folderKey(_ file: URL) -> String {
        file.deletingLastPathComponent().standardizedFileURL.path
    }

    private static func baseKey(_ file: URL) -> String {
        file.deletingPathExtension().lastPathComponent.lowercased()
    }
}

/// What dropping files and folders on the window imports: each folder as a
/// folder import, and loose photos grouped by the folder they are in.
public enum DroppedImport {
    public enum Job: Equatable, Sendable {
        case folder(URL)
        case files(in: URL, [URL])
    }

    public struct Item: Equatable, Sendable {
        public let url: URL
        public let isDirectory: Bool

        public init(url: URL, isDirectory: Bool) {
            self.url = url
            self.isDirectory = isDirectory
        }
    }

    /// The imports to run, in the order dropped. A folder dropped twice, or
    /// inside another dropped folder, and a file inside a dropped folder are
    /// imported once. Files Moments can't import are left out.
    public static func jobs(_ items: [Item]) -> [Job] {
        let folders = items.filter(\.isDirectory).map { $0.url.standardizedFileURL }
        let roots = folders.filter { folder in
            !folders.contains { other in other != folder && isInside(folder, other) }
        }
        var jobs: [Job] = []
        var seenFolders = Set<String>()
        var filesByParent: [String: [URL]] = [:]
        var parentOrder: [String] = []
        for item in items {
            let url = item.url.standardizedFileURL
            if item.isDirectory {
                guard roots.contains(url), seenFolders.insert(url.path).inserted else { continue }
                jobs.append(.folder(url))
            } else {
                guard SupportedMediaFile.isSupported(pathExtension: url.pathExtension),
                      !roots.contains(where: { isInside(url, $0) }) else { continue }
                let parent = url.deletingLastPathComponent().path
                if filesByParent[parent] == nil { parentOrder.append(parent) }
                if filesByParent[parent]?.contains(url) != true {
                    filesByParent[parent, default: []].append(url)
                }
            }
        }
        for parent in parentOrder {
            jobs.append(.files(in: URL(fileURLWithPath: parent, isDirectory: true), filesByParent[parent] ?? []))
        }
        return jobs
    }

    private static func isInside(_ url: URL, _ folder: URL) -> Bool {
        let root = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        return url.path.hasPrefix(root)
    }
}

/// Whether an imported folder can still be found, from what resolving its
/// bookmark gave.
public enum FolderLocationCheck: Equatable, Sendable {
    /// Found where the bookmark says.
    case found
    /// Found, but the bookmark is out of date: make a new one.
    case foundWithStaleBookmark
    /// Moved, renamed, deleted, or on a drive that isn't connected.
    case missing

    public static func classify(resolved: Bool, isStale: Bool, existsAsFolder: Bool) -> FolderLocationCheck {
        guard resolved, existsAsFolder else { return .missing }
        return isStale ? .foundWithStaleBookmark : .found
    }

    /// The missing folders to show: not those someone closed the note for,
    /// sorted by name so the list doesn't jump between launches.
    public static func toShow(
        missing: [(id: String, name: String)],
        dismissed: Set<String>
    ) -> [(id: String, name: String)] {
        missing
            .filter { !dismissed.contains($0.id) }
            .sorted { lhs, rhs in
                let order = lhs.name.compare(rhs.name, options: [.caseInsensitive, .numeric])
                return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
            }
    }
}
