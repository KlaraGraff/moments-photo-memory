import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import MomentsCore
import UniformTypeIdentifiers

/// The small copy of a photo that goes to the other person's Mac. Originals
/// never leave this Mac; the preview is redrawn from pixels, so it carries
/// no EXIF, GPS or camera data.
enum SharedPreview {
    /// Long edge in pixels: sharp on a Retina screen in the large viewer,
    /// about 300 to 600 KB as JPEG.
    static let maxPixelSize = 2048
    static let jpegQuality = 0.8

    struct Rendered: Equatable {
        let data: Data
        let asset: SyncAssetRef
    }

    /// Downscales (never upscales) and re-encodes as JPEG without metadata.
    static func render(_ image: CGImage, maxPixelSize: Int = SharedPreview.maxPixelSize) -> Rendered? {
        let longEdge = max(image.width, image.height)
        guard longEdge > 0 else { return nil }
        let scale = min(1, Double(maxPixelSize) / Double(longEdge))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, scaled, [
            kCGImageDestinationLossyCompressionQuality: jpegQuality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let data = output as Data
        return Rendered(
            data: data,
            asset: SyncAssetRef(sha256: sha256(data), byteCount: data.count, pixelWidth: width, pixelHeight: height)
        )
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The preview record for a photo. One preview per photo, so its ID is
    /// derived from the photo's.
    static func record(mediaID: String, asset: SyncAssetRef, updatedAt: Date) -> SyncRecord {
        var record = SyncRecord(type: .previewAsset, id: recordID(mediaID: mediaID))
        record.setReference("mediaID", mediaID)
        record["preview"] = .asset(asset)
        record.set("updatedAt", updatedAt)
        return record
    }

    static func recordID(mediaID: String) -> String {
        "preview:" + mediaID
    }
}

/// Preview files on disk, one per photo, under the app's Application
/// Support folder (never in the repository, never in the library folder).
struct SharedPreviewFiles {
    let folder: URL

    static var defaultFolder: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "Moments", directoryHint: .isDirectory)
            .appending(path: "SharedPreviews", directoryHint: .isDirectory)
    }

    /// The app's preview folder, shared by the sync engine and the screens.
    static var standard: SharedPreviewFiles? {
        defaultFolder.map { SharedPreviewFiles(folder: $0) }
    }

    /// The preview to show for a photo that came from the other person, if
    /// it has arrived.
    static func previewURL(for item: MediaItem) -> URL? {
        guard item.sourceRaw == SyncModelCoding.sharedSourceRaw, let files = standard else { return nil }
        let url = files.url(mediaID: item.id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func url(mediaID: String) -> URL {
        folder.appending(path: SyncDigest.hex(mediaID) + "-" + SyncDigest.hex(String(mediaID.reversed())) + ".jpg")
    }

    func write(_ data: Data, mediaID: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = url(mediaID: mediaID)
        try data.write(to: url, options: .atomic)
        return url
    }

    func data(mediaID: String) -> Data? {
        try? Data(contentsOf: url(mediaID: mediaID))
    }

    func remove(mediaID: String) {
        try? FileManager.default.removeItem(at: url(mediaID: mediaID))
    }
}
