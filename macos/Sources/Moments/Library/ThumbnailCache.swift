import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import SwiftUI

/// Renders synthetic thumbnails without touching the main thread or a photo file.
private enum DeterministicThumbnailRenderer {
    static func pngData(id: String, width: Int, height: Int) -> Data? {
        let width = max(8, width)
        let height = max(8, height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let hue = Double(hash % 360) / 360
        let saturation = 0.24 + Double((hash >> 8) % 32) / 100
        let brightness = 0.78 + Double((hash >> 16) % 18) / 100
        let baseRGB = rgb(hue: hue, saturation: saturation, brightness: brightness)
        let accentRGB = rgb(hue: (hue + 0.14).truncatingRemainder(dividingBy: 1), saturation: min(1, saturation + 0.18), brightness: max(0, brightness - 0.16))
        let base = CGColor(red: baseRGB.red, green: baseRGB.green, blue: baseRGB.blue, alpha: 1)
        let accent = CGColor(red: accentRGB.red, green: accentRGB.green, blue: accentRGB.blue, alpha: 1)
        context.drawLinearGradient(
            CGGradient(colorsSpace: colorSpace, colors: [base, accent] as CFArray, locations: [0, 1])!,
            start: CGPoint(x: 0, y: CGFloat(height)),
            end: CGPoint(x: CGFloat(width), y: 0),
            options: []
        )

        let inset = CGFloat(min(width, height)) * 0.14
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.22))
        context.setLineWidth(max(1, CGFloat(min(width, height)) * 0.012))
        context.strokeEllipse(in: CGRect(x: inset, y: inset, width: CGFloat(width) - inset * 2, height: CGFloat(height) - inset * 2))
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.12))
        context.setLineWidth(1)
        let step = max(18, min(width, height) / 4)
        for x in stride(from: 0, through: width, by: step) {
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: height))
        }
        for y in stride(from: 0, through: height, by: step) {
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: width, y: y))
        }
        context.strokePath()

        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func rgb(hue: Double, saturation: Double, brightness: Double) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        let scaled = hue * 6
        let sector = Int(floor(scaled))
        let fraction = scaled - floor(scaled)
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * fraction)
        let t = brightness * (1 - saturation * (1 - fraction))
        let values: (Double, Double, Double)
        switch sector % 6 {
        case 0: values = (brightness, t, p)
        case 1: values = (q, brightness, p)
        case 2: values = (p, brightness, t)
        case 3: values = (p, q, brightness)
        case 4: values = (t, p, brightness)
        default: values = (brightness, p, q)
        }
        return (CGFloat(values.0), CGFloat(values.1), CGFloat(values.2))
    }
}

/// Main-actor access to an NSCache whose expensive bitmap work happens in a detached task.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 320
        return cache
    }()

    func image(for id: String, width: Int, height: Int) async -> NSImage? {
        let key = "\(id)-\(width)x\(height)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let data = await Task.detached(priority: .userInitiated) { () -> Data? in
            DeterministicThumbnailRenderer.pngData(id: id, width: width, height: height)
        }.value
        guard let data, let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    func image(for item: MediaItem, width: Int, height: Int) async -> NSImage? {
        let key = "\(item.id)-\(width)x\(height)" as NSString
        #if DEBUG
        ScrollProbe.count("thumbnail.request")
        #endif
        if let cached = cache.object(forKey: key) { return cached }
        let bookmark = item.originalBookmarkData
        let id = item.id
        let diskURL = Self.diskURL(for: id, width: width, height: height)
        let data = await Task.detached(priority: .userInitiated) { () -> Data? in
            if let existing = try? Data(contentsOf: diskURL) {
                return existing
            }
            if let bookmark, let imageData = Self.importedPNG(bookmark: bookmark, width: width, height: height) {
                try? imageData.write(to: diskURL, options: .atomic)
                return imageData
            }
            let generated = DeterministicThumbnailRenderer.pngData(id: id, width: width, height: height)
            if let generated { try? generated.write(to: diskURL, options: .atomic) }
            return generated
        }.value
        guard let data, let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    nonisolated private static func importedPNG(bookmark: Data, width: Int, height: Int) -> Data? {
        guard let resolved = try? OriginalMediaBookmark.resolve(bookmark),
              resolved.url.startAccessingSecurityScopedResource() else { return nil }
        defer { resolved.url.stopAccessingSecurityScopedResource() }
        guard let source = CGImageSourceCreateWithURL(resolved.url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(width, height)
                ] as CFDictionary
              ) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    private static func diskURL(for id: String, width: Int, height: Int) -> URL {
        let folder = URL.applicationSupportDirectory
            .appending(path: "Moments", directoryHint: .isDirectory)
            .appending(path: "Thumbnails", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "\(id)-\(width)x\(height).png")
    }
}

struct ThumbnailView: View {
    let item: MediaItem
    let width: Int
    let height: Int

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .clipped()
        .task(id: "\(item.id)-\(width)x\(height)") {
            image = await ThumbnailCache.shared.image(for: item, width: width, height: height)
        }
    }
}
