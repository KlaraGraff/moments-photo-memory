import CryptoKit
import Foundation

public struct PhotosMetadataMapper: Sendable {
    public init() {}

    public func map(_ asset: PhotosAssetDescriptor) -> PhotosMappedAsset {
        let stableID = Self.stableID(for: asset.localIdentifier)
        let captureDate = asset.creationDate ?? asset.modificationDate ?? Date(timeIntervalSince1970: 0)
        let hasCaptureDate = asset.creationDate != nil
        let kind: MediaKind
        switch asset.mediaType {
        case .video:
            kind = .video
        case .image where asset.mediaSubtypes.contains(.live):
            kind = .live
        default:
            kind = .photo
        }
        let bookmark = Data("photos-reference:\(asset.localIdentifier)".utf8)
        let metadata = ImportedMediaMetadata(
            id: "photos-\(stableID)",
            bookmarkData: bookmark,
            fileName: "Apple Photos asset",
            contentHash: "photos-\(stableID)",
            captureDate: captureDate,
            captureDateSource: hasCaptureDate ? .asset : .fileDateFallback,
            timeZoneOffsetMinutes: nil,
            latitude: asset.location?.latitude,
            longitude: asset.location?.longitude,
            width: asset.pixelWidth,
            height: asset.pixelHeight,
            kind: kind,
            duration: asset.duration,
            exactCaptureDate: asset.creationDate,
            dateHintUTC: hasCaptureDate ? nil : captureDate,
            timeConfidence: hasCaptureDate ? .exact : .low,
            timeZoneIdentifier: nil
        )
        return PhotosMappedAsset(
            asset: asset,
            metadata: metadata,
            isScreenshot: asset.mediaSubtypes.contains(.screenshot),
            isFavorite: asset.isFavorite
        )
    }

    public static func stableID(for localIdentifier: String) -> String {
        let digest = SHA256.hash(data: Data(localIdentifier.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
