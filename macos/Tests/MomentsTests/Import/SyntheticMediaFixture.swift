import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum SyntheticMediaFixture {
    static func writeJPEG(
        at url: URL,
        date: Date? = nil,
        offset: String? = "+00:00",
        latitude: Double? = nil,
        longitude: Double? = nil,
        marker: Int = 0
    ) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: 4,
            height: 4,
            bitsPerComponent: 8,
            bytesPerRow: 16,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let value = CGFloat((marker % 255)) / 255
        context.setFillColor(CGColor(red: value, green: 0.2, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }

        var metadata: [CFString: Any] = [:]
        if let date {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            // Cameras write local wall-clock time plus OffsetTimeOriginal, so format in that offset.
            formatter.timeZone = offset.flatMap(Self.timeZone(fromOffset:)) ?? TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            // The marker also goes into the metadata: tiny images with close colours can encode to identical bytes.
            var exif: [CFString: Any] = [
                kCGImagePropertyExifDateTimeOriginal: formatter.string(from: date),
                kCGImagePropertyExifUserComment: "synthetic-\(marker)"
            ]
            if let offset { exif[kCGImagePropertyExifOffsetTimeOriginal] = offset }
            metadata[kCGImagePropertyExifDictionary] = exif
        }
        if let latitude, let longitude {
            metadata[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: abs(latitude),
                kCGImagePropertyGPSLatitudeRef: latitude < 0 ? "S" : "N",
                kCGImagePropertyGPSLongitude: abs(longitude),
                kCGImagePropertyGPSLongitudeRef: longitude < 0 ? "W" : "E"
            ]
        }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, metadata as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    static func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("moments-synthetic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func removeFolder(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder)
    }

    static func timeZone(fromOffset offset: String) -> TimeZone? {
        let sign = offset.hasPrefix("-") ? -1 : 1
        let parts = offset.dropFirst().split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return TimeZone(secondsFromGMT: sign * (parts[0] * 3_600 + parts[1] * 60))
    }
}
