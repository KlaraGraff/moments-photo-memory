import AppKit
import CryptoKit
import Foundation

@MainActor
public final class PhotosThumbnailCache {
    public static let shared = PhotosThumbnailCache(source: PhotoKitAssetSource())

    private let source: any PhotosAssetSource
    private let memory = NSCache<NSString, NSImage>()

    public init(source: any PhotosAssetSource) {
        self.source = source
        memory.countLimit = 320
    }

    public func image(
        forLocalIdentifier localIdentifier: String,
        width: Int,
        height: Int,
        networkAccessAllowed: Bool = true
    ) async -> NSImage? {
        let key = "\(PhotosMetadataMapper.stableID(for: localIdentifier))-\(width)x\(height)" as NSString
        if let cached = memory.object(forKey: key) { return cached }
        let diskURL = Self.diskURL(for: localIdentifier, width: width, height: height)
        let data = await Task.detached(priority: .userInitiated) { [source] () async -> Data? in
            if let cached = try? Data(contentsOf: diskURL) { return cached }
            guard let data = try? await source.thumbnailData(
                forLocalIdentifier: localIdentifier,
                targetSize: CGSize(width: width, height: height),
                networkAccessAllowed: networkAccessAllowed
            ) else { return nil }
            try? data.write(to: diskURL, options: .atomic)
            return data
        }.value
        guard let data, let image = NSImage(data: data) else { return nil }
        memory.setObject(image, forKey: key)
        return image
    }

    private static func diskURL(for localIdentifier: String, width: Int, height: Int) -> URL {
        let folder = URL.applicationSupportDirectory
            .appending(path: "Moments", directoryHint: .isDirectory)
            .appending(path: "Thumbnails", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let digest = PhotosMetadataMapper.stableID(for: localIdentifier)
        return folder.appending(path: "Photos-\(digest)-\(width)x\(height).data")
    }
}
