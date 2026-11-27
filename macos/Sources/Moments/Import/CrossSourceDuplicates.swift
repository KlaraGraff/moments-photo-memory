import Foundation
import MomentsCore

/// Flags a photo imported from one source (a folder or Apple Photos) that is
/// probably already in the library from the other source. Both import orders
/// use the same rule (``CrossSourceDuplicateMatcher``); a match only adds a
/// "possible near-duplicate" review flag and never merges anything (#40).
enum CrossSourceDuplicates {
    static let matcher = CrossSourceDuplicateMatcher()

    /// The library items from `source` that a new import from the other
    /// source is compared with. Items in Recently Deleted are left out.
    static func candidates(in library: [MediaItem], from source: MediaSource) -> [DuplicateCandidate] {
        library.compactMap { item in
            guard item.deletedAt == nil, item.source == source else { return nil }
            return candidate(for: item)
        }
    }

    static func candidate(for item: MediaItem) -> DuplicateCandidate? {
        guard let captureDate = item.captureDate else { return nil }
        return DuplicateCandidate(
            id: item.id,
            captureDate: captureDate,
            pixelWidth: item.width,
            pixelHeight: item.height,
            location: point(latitude: item.latitude, longitude: item.longitude),
            perceptualHash: item.perceptualHash
        )
    }

    /// A folder file whose capture time came only from the file's dates is
    /// left out: that time says when the file was copied, not when the photo
    /// was taken.
    static func candidate(for metadata: ImportedMediaMetadata) -> DuplicateCandidate? {
        guard let captureDate = metadata.exactCaptureDate else { return nil }
        return DuplicateCandidate(
            id: metadata.id,
            captureDate: captureDate,
            pixelWidth: metadata.width,
            pixelHeight: metadata.height,
            location: point(latitude: metadata.latitude, longitude: metadata.longitude),
            perceptualHash: metadata.perceptualHash
        )
    }

    /// `knownHash` is the hash already stored for this asset, used when a
    /// refresh did not render a new thumbnail.
    static func candidate(for mapped: PhotosMappedAsset, knownHash: String? = nil) -> DuplicateCandidate? {
        guard let captureDate = mapped.asset.creationDate else { return nil }
        return DuplicateCandidate(
            id: mapped.asset.localIdentifier,
            captureDate: captureDate,
            pixelWidth: mapped.asset.pixelWidth,
            pixelHeight: mapped.asset.pixelHeight,
            location: mapped.asset.location,
            perceptualHash: mapped.perceptualHash ?? knownHash
        )
    }

    /// Merges two flag lists, joining the reasons of flags for the same item.
    static func mergeFlags(_ first: [ImportReviewFlag], _ second: [ImportReviewFlag]) -> [ImportReviewFlag] {
        var values = Dictionary(first.map { ($0.id, $0) }, uniquingKeysWith: { lhs, _ in lhs })
        for flag in second {
            if let old = values[flag.id] {
                let reasons = Array(Set(old.reasons + flag.reasons)).sorted { $0.rawValue < $1.rawValue }
                values[flag.id] = ImportReviewFlag(id: old.id, fileName: old.fileName, reasons: reasons, detail: old.detail ?? flag.detail, suggestedDayKey: old.suggestedDayKey ?? flag.suggestedDayKey, suggestedPlaceName: old.suggestedPlaceName ?? flag.suggestedPlaceName, decision: old.decision)
            } else {
                values[flag.id] = flag
            }
        }
        return values.values.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
    }

    private static func point(latitude: Double?, longitude: Double?) -> GeoPoint? {
        guard let latitude, let longitude else { return nil }
        return GeoPoint(latitude: latitude, longitude: longitude)
    }
}
