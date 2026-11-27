import AVFoundation
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import MomentsCore
import UniformTypeIdentifiers

enum MediaMetadataReaderError: LocalizedError {
    case unsupported(URL)
    case unreadable(URL)

    var errorDescription: String? {
        switch self {
        case .unsupported(let url): return String(localized: "Unsupported media type.") + " " + url.lastPathComponent
        case .unreadable(let url): return String(localized: "Moments could not read media metadata.") + " " + url.lastPathComponent
        }
    }
}

struct MediaMetadataReader {
    func read(url: URL) async throws -> ImportedMediaMetadata {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let kind = mediaKind(for: url, contentType: nil)
        let hash = try Self.sha256(url: url)
        // Sandboxed releases receive a security-scoped bookmark. The regular
        // bookmark fallback keeps synthetic/unit-test folders usable in an
        // unsandboxed test host while preserving the same in-place reference.
        let bookmark: Data
        if let scoped = try? url.bookmarkData(options: [.withSecurityScope]) {
            bookmark = scoped
        } else if let regular = try? url.bookmarkData() {
            bookmark = regular
        } else {
            // Some unsandboxed command-line test hosts cannot create Cocoa
            // bookmarks. Keep an explicitly tagged runtime-only fallback so
            // the test still verifies in-place access without committing paths.
            bookmark = Data(OriginalMediaBookmark.pathFallbackPrefix.utf8) + Data(url.path.utf8)
        }

        switch kind {
        case .photo, .live:
            guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                throw MediaMetadataReaderError.unreadable(url)
            }
            let properties = (CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]) ?? [:]
            let pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 64,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            let perceptualHash = CGImageSourceCreateThumbnailAtIndex(
                imageSource,
                0,
                thumbnailOptions as CFDictionary
            ).flatMap(PerceptualHash.dHash)
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
            let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any]
            let parsedDate = Self.captureDate(from: exif)
            let captureDate = parsedDate?.date ?? values?.contentModificationDate ?? values?.creationDate ?? .now
            let source: ImportCaptureDateSource = parsedDate == nil ? .fileDateFallback : .exif
            let coordinate = Self.coordinate(from: gps)

            return ImportedMediaMetadata(
                id: hash,
                bookmarkData: bookmark,
                fileName: url.lastPathComponent,
                contentHash: hash,
                captureDate: captureDate,
                captureDateSource: source,
                timeZoneOffsetMinutes: parsedDate?.offsetMinutes,
                latitude: coordinate?.latitude,
                longitude: coordinate?.longitude,
                width: pixelWidth,
                height: pixelHeight,
                kind: kind,
                duration: nil,
                exactCaptureDate: parsedDate?.wallClockDate == nil ? parsedDate?.date : nil,
                dateHintUTC: parsedDate == nil ? captureDate : nil,
                timeConfidence: parsedDate?.wallClockDate == nil
                    ? (parsedDate == nil ? .low : .exact)
                    : .zoneUnknown,
                timeZoneIdentifier: parsedDate?.offsetMinutes.flatMap { TimeZone(secondsFromGMT: $0 * 60)?.identifier },
                parentDirectoryKey: url.deletingLastPathComponent().standardizedFileURL.path,
                appleContentIdentifier: Self.appleContentIdentifier(from: properties),
                wallClockDate: parsedDate?.wallClockDate,
                perceptualHash: perceptualHash
            )
        case .video:
            let asset = AVURLAsset(url: url)
            let durationTime = try? await asset.load(.duration)
            let duration = durationTime?.seconds
            let creationItem = try? await asset.load(.creationDate)
            let assetMetadata = (try? await asset.load(.metadata)) ?? []
            let quickTime = await Self.quickTimeValues(from: assetMetadata, creationItem: creationItem)
            let date = Self.videoCaptureDate(quickTime: quickTime)
            let fileDate = values?.contentModificationDate ?? values?.creationDate ?? .now
            let captureDate = date?.date ?? fileDate
            let wallClockDate = date?.isWallClock == true ? date?.date : nil
            let tracks = try? await asset.load(.tracks)
            let videoTrack = tracks?.first(where: { $0.mediaType == .video })
            let size = videoTrack.map { $0.naturalSize.applying($0.preferredTransform) }
            let width = Int(abs(size?.width ?? 0))
            let height = Int(abs(size?.height ?? 0))
            let coordinate = quickTime.location.flatMap {
                ImportLocation.usable(latitude: $0.latitude, longitude: $0.longitude)
            }
            return ImportedMediaMetadata(
                id: hash,
                bookmarkData: bookmark,
                fileName: url.lastPathComponent,
                contentHash: hash,
                captureDate: captureDate,
                captureDateSource: date == nil ? .fileDateFallback : .asset,
                timeZoneOffsetMinutes: date?.offsetMinutes,
                latitude: coordinate?.latitude,
                longitude: coordinate?.longitude,
                width: width,
                height: height,
                kind: .video,
                duration: duration,
                exactCaptureDate: date == nil || wallClockDate != nil ? nil : captureDate,
                dateHintUTC: date == nil ? captureDate : nil,
                timeConfidence: date == nil ? .low : (wallClockDate == nil ? .exact : .zoneUnknown),
                timeZoneIdentifier: date?.offsetMinutes.flatMap { TimeZone(secondsFromGMT: $0 * 60)?.identifier },
                parentDirectoryKey: url.deletingLastPathComponent().standardizedFileURL.path,
                appleContentIdentifier: Self.appleContentIdentifier(from: assetMetadata),
                wallClockDate: wallClockDate
            )
        }
    }

    /// The QuickTime values a video's place and time come from, as text.
    struct QuickTimeValues: Equatable {
        /// `com.apple.quicktime.location.ISO6709`, or the user-data and
        /// common location an MP4 may carry instead.
        var location: GeoPoint?
        /// `com.apple.quicktime.creationdate`, which phones write with the
        /// local offset, e.g. `2026-01-01T12:34:56+0200`.
        var creationDate: QuickTimeMetadata.CreationDate?
        /// The asset's own creation date (the movie header's UTC time).
        var assetCreationDate: Date?
    }

    private static func quickTimeValues(from metadata: [AVMetadataItem], creationItem: AVMetadataItem?) async -> QuickTimeValues {
        var values = QuickTimeValues()
        // Phones write the full metadata key; older cameras and MP4 files the
        // user-data or common one. The first readable one wins, in this order.
        let locationIdentifiers: [AVMetadataIdentifier] = [
            .quickTimeMetadataLocationISO6709,
            .quickTimeUserDataLocationISO6709,
            .commonIdentifierLocation
        ]
        for identifier in locationIdentifiers where values.location == nil {
            for item in metadata where item.identifier == identifier {
                if let text = try? await item.load(.stringValue),
                   let point = QuickTimeMetadata.location(iso6709: text) {
                    values.location = point
                    break
                }
            }
        }
        for item in metadata where item.identifier == .quickTimeMetadataCreationDate {
            if let text = try? await item.load(.stringValue),
               let parsed = QuickTimeMetadata.creationDate(text) {
                values.creationDate = parsed
                break
            }
        }
        if let creationItem {
            let text = try? await creationItem.load(.stringValue)
            let parsed = text.flatMap(QuickTimeMetadata.creationDate)
            if values.creationDate == nil { values.creationDate = parsed }
            // A zone-less text's date value was read in this Mac's zone, not
            // the place's, so only a value with a zone (or none) is absolute.
            if parsed?.isWallClock != true {
                values.assetCreationDate = try? await creationItem.load(.dateValue)
            }
        }
        return values
    }

    /// A stated offset or `Z` wins; then the movie header's UTC time; a
    /// zone-less wall-clock value comes last, so the import resolves its zone
    /// from the place the same way it does for offset-less photos.
    static func videoCaptureDate(quickTime: QuickTimeValues) -> QuickTimeMetadata.CreationDate? {
        if let parsed = quickTime.creationDate, !parsed.isWallClock { return parsed }
        if let absolute = quickTime.assetCreationDate {
            return QuickTimeMetadata.CreationDate(date: absolute, offsetMinutes: nil, isWallClock: false)
        }
        return quickTime.creationDate
    }

    private func mediaKind(for url: URL, contentType: UTType?) -> MediaKind {
        let type = contentType ?? UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true { return .video }
        return .photo
    }

    private static func captureDate(from exif: [CFString: Any]?) -> (date: Date, offsetMinutes: Int?, wallClockDate: Date?)? {
        guard let exif,
              let value = (exif[kCGImagePropertyExifDateTimeOriginal] as? String)
                ?? (exif[kCGImagePropertyExifDateTimeDigitized] as? String) else { return nil }
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateFormatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let parsed = dateFormatter.date(from: value)
        guard let parsed else { return nil }

        let offsetString = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String
            ?? exif[kCGImagePropertyExifOffsetTimeDigitized] as? String
        guard let offsetString, let offsetMinutes = parseOffset(offsetString) else {
            // DateFormatter deliberately used UTC here: this preserves the
            // wall-clock components without claiming that they are UTC.
            return (parsed, nil, parsed)
        }
        // The EXIF wall-clock value is interpreted in the declared offset.
        let utcDate = parsed.addingTimeInterval(TimeInterval(-offsetMinutes * 60))
        return (utcDate, offsetMinutes, nil)
    }

    private static func appleContentIdentifier(from properties: [CFString: Any]) -> String? {
        if let makerApple = properties[kCGImagePropertyMakerAppleDictionary] as? [CFString: Any],
           let value = makerApple.first(where: { String(describing: $0.key) == "17" })?.value as? String {
            return value
        }
        if let makerApple = properties[kCGImagePropertyMakerAppleDictionary] as? [String: Any],
           let value = makerApple["17"] as? String {
            return value
        }
        return nil
    }

    private static func appleContentIdentifier(from metadata: [AVMetadataItem]) -> String? {
        metadata.first { item in
            let identifier = String(describing: item.identifier)
            let key = String(describing: item.key)
            return identifier.contains("com.apple.quicktime.content.identifier")
                || key.contains("com.apple.quicktime.content.identifier")
        }?.stringValue
    }

    private static func parseOffset(_ value: String) -> Int? {
        guard value.count >= 6 else { return nil }
        let sign = value.first == "-" ? -1 : 1
        let components = value.dropFirst().split(separator: ":")
        guard components.count == 2,
              let hours = Int(components[0]),
              let minutes = Int(components[1]) else { return nil }
        return sign * (hours * 60 + minutes)
    }

    private static func coordinate(from gps: [CFString: Any]?) -> (latitude: Double, longitude: Double)? {
        guard let gps,
              let latitude = (gps[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue,
              let longitude = (gps[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue else { return nil }
        let latitudeRef = (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased()
        let longitudeRef = (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased()
        let signedLatitude = latitudeRef == "S" ? -latitude : latitude
        let signedLongitude = longitudeRef == "W" ? -longitude : longitude
        guard (-90...90).contains(signedLatitude), (-180...180).contains(signedLongitude) else { return nil }
        return ImportLocation.usable(latitude: signedLatitude, longitude: signedLongitude)
    }

    static func sha256(url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw MediaMetadataReaderError.unreadable(url)
        }
        defer { try? handle.close() }
        var digest = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            digest.update(data: chunk)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
