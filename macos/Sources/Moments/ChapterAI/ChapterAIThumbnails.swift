import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Small JPEGs of photos for the model to look at. Only copies already on
/// this Mac are used, never a download from iCloud (maple, 2026-10-27): a
/// photo with nothing local is simply not described.
enum ChapterAIThumbnails {
    /// 448 × 336 is 16 × 12 patches: 192 visual tokens.
    static let longEdge = 448
    static let quality = 0.72

    struct Source: Sendable {
        let id: String
        let photosLocalIdentifier: String?
        let bookmark: Data?
        let isVideo: Bool
    }

    static func jpeg(for source: Source, photos: (any PhotosAssetSource)?) async -> Data? {
        var image: CGImage?
        if let identifier = source.photosLocalIdentifier, let photos, photos.authorizationStatus.canRead {
            let side = CGFloat(longEdge)
            image = await photos.thumbnailImage(forLocalIdentifier: identifier, targetSize: CGSize(width: side, height: side), networkAccessAllowed: false)
        }
        if image == nil, let bookmark = source.bookmark, let resolved = try? OriginalMediaBookmark.resolve(bookmark) {
            let scoped = resolved.url.startAccessingSecurityScopedResource()
            defer { if scoped { resolved.url.stopAccessingSecurityScopedResource() } }
            // A file iCloud Drive keeps only in the cloud would be downloaded.
            guard isLocal(resolved.url) else { return nil }
            image = source.isVideo ? await videoFrame(resolved.url) : fileImage(resolved.url)
        }
        guard let image, let fitted = fit(image) else { return nil }
        return encode(fitted)
    }

    static func isLocal(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              values.isUbiquitousItem == true else { return true }
        return values.ubiquitousItemDownloadingStatus == .current
    }

    private static func fileImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longEdge
        ] as CFDictionary)
    }

    private static func videoFrame(_ url: URL) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: longEdge, height: longEdge)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        return try? await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
    }

    /// Scaled down so the long edge is `longEdge` at most.
    static func fit(_ image: CGImage) -> CGImage? {
        let scale = min(1, Double(longEdge) / Double(max(image.width, image.height, 1)))
        guard scale < 1 else { return image }
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// JPEG without any metadata: no place, date or camera goes along.
    static func encode(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
