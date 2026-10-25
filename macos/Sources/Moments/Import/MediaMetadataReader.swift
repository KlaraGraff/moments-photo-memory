import AVFoundation
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
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
            let creationDate = try? await asset.load(.creationDate)
            let assetMetadata = try? await asset.load(.metadata)
            let captureDate = creationDate?.dateValue ?? values?.contentModificationDate ?? values?.creationDate ?? .now
            let tracks = try? await asset.load(.tracks)
            let videoTrack = tracks?.first(where: { $0.mediaType == .video })
            let size = videoTrack.map { $0.naturalSize.applying($0.preferredTransform) }
            let width = Int(abs(size?.width ?? 0))
            let height = Int(abs(size?.height ?? 0))
            return ImportedMediaMetadata(
                id: hash,
                bookmarkData: bookmark,
                fileName: url.lastPathComponent,
                contentHash: hash,
                captureDate: captureDate,
                captureDateSource: creationDate == nil ? .fileDateFallback : .asset,
                timeZoneOffsetMinutes: nil,
                latitude: nil,
                longitude: nil,
                width: width,
                height: height,
                kind: .video,
                duration: duration,
                exactCaptureDate: creationDate?.dateValue,
                dateHintUTC: creationDate == nil ? captureDate : nil,
                timeConfidence: creationDate == nil ? .low : .exact,
                timeZoneIdentifier: nil,
                parentDirectoryKey: url.deletingLastPathComponent().standardizedFileURL.path,
                appleContentIdentifier: Self.appleContentIdentifier(from: assetMetadata ?? [])
            )
        }
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
        return (signedLatitude, signedLongitude)
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
