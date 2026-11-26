import CoreGraphics
import Foundation
import ImageIO

/// Makes the preview file for each shared photo this Mac owns. Only what is
/// on this Mac is used: nothing is downloaded from iCloud Photos, and a photo
/// whose original can't be read yet simply goes without a preview until a
/// later sync. Videos travel as a still for now.
enum SharedPreviewProducer {
    struct Source: Sendable {
        let mediaID: String
        let photosLocalIdentifier: String?
        let bookmark: Data?
    }

    /// Writes the missing previews and returns how many were made.
    static func produce(_ sources: [Source], into files: SharedPreviewFiles) async -> Int {
        var made = 0
        for source in sources {
            if Task.isCancelled { break }
            guard !FileManager.default.fileExists(atPath: files.url(mediaID: source.mediaID).path),
                  let image = await loadImage(source),
                  let rendered = SharedPreview.render(image),
                  (try? files.write(rendered.data, mediaID: source.mediaID)) != nil else { continue }
            made += 1
        }
        return made
    }

    private static func loadImage(_ source: Source) async -> CGImage? {
        let size = SharedPreview.maxPixelSize
        if let identifier = source.photosLocalIdentifier,
           let image = await PhotoKitAssetSource.shared.thumbnailImage(
            forLocalIdentifier: identifier,
            targetSize: CGSize(width: size, height: size),
            networkAccessAllowed: false
           ) {
            return image
        }
        guard let bookmark = source.bookmark, let resolved = try? OriginalMediaBookmark.resolve(bookmark) else { return nil }
        let scoped = resolved.url.startAccessingSecurityScopedResource()
        defer { if scoped { resolved.url.stopAccessingSecurityScopedResource() } }
        guard let imageSource = CGImageSourceCreateWithURL(resolved.url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: size,
            kCGImageSourceShouldCache: false
        ] as CFDictionary)
    }
}
