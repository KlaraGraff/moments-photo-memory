import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import SwiftUI

/// Renders synthetic thumbnails without touching the main thread or a photo file.
private enum DeterministicThumbnailRenderer {
    static func image(id: String, width: Int, height: Int) -> CGImage? {
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

        return context.makeImage()
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

/// What a thumbnail is made from: the Apple Photos asset, the original file,
/// or (for demo items) a generated picture.
struct ThumbnailSource: Sendable, Equatable {
    let id: String
    let photosLocalIdentifier: String?
    let bookmark: Data?

    init(id: String, photosLocalIdentifier: String? = nil, bookmark: Data? = nil) {
        self.id = id
        self.photosLocalIdentifier = photosLocalIdentifier
        self.bookmark = bookmark
    }

    init(item: MediaItem) {
        self.init(id: item.id, photosLocalIdentifier: item.photosLocalIdentifier, bookmark: item.originalBookmarkData)
    }

    /// Items with a real photo behind them never show the generated picture
    /// for good; a failed read is retried next time.
    var hasOriginal: Bool { photosLocalIdentifier != nil || bookmark != nil }
}

/// Thumbnails for every screen. Reading, scaling and decoding happen off the
/// main thread, so a cell only hands an already decoded bitmap to SwiftUI.
/// Apple Photos items come from PhotoKit, folder items from the original file.
/// The disk cache holds small JPEGs; generated stand-ins for a photo that could
/// not be read are never written there.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache(directory: ThumbnailCache.defaultDirectory, photos: PhotoKitAssetSource())

    private let directory: URL?
    private let photos: (any PhotosAssetSource)?
    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 600
        return cache
    }()

    init(directory: URL?, photos: (any PhotosAssetSource)?) {
        self.directory = directory
        self.photos = photos
        if let directory { Self.prepare(directory) }
    }

    private static var defaultDirectory: URL? {
        #if DEBUG
        // UI and unit tests never write into the user's Application Support.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-MomentsUITesting") || arguments.contains("-MomentsUITestStoreDirectory") || UnitTestHostDelegate.isUnitTestHost {
            return FileManager.default.temporaryDirectory.appending(path: "MomentsTestThumbnails-\(ProcessInfo.processInfo.processIdentifier)", directoryHint: .isDirectory)
        }
        #endif
        return URL.applicationSupportDirectory
            .appending(path: "Moments", directoryHint: .isDirectory)
            .appending(path: "Thumbnails", directoryHint: .isDirectory)
    }

    private static func key(_ id: String, _ width: Int, _ height: Int) -> NSString {
        "\(id)-\(width)x\(height)" as NSString
    }

    /// A thumbnail that is already in memory, for drawing it in the first frame.
    func cachedImage(for id: String, width: Int, height: Int) -> NSImage? {
        cache.object(forKey: Self.key(id, width, height))
    }

    func image(for item: MediaItem, width: Int, height: Int) async -> NSImage? {
        await image(for: ThumbnailSource(item: item), width: width, height: height)
    }

    func image(for source: ThumbnailSource, width: Int, height: Int) async -> NSImage? {
        let key = Self.key(source.id, width, height)
        #if DEBUG
        ScrollProbe.count("thumbnail.request")
        #endif
        if let cached = cache.object(forKey: key) { return cached }
        // Asking PhotoKit before access was granted could raise the system prompt.
        let photoKit = source.photosLocalIdentifier != nil && photos?.authorizationStatus.canRead == true ? photos : nil
        let diskURL = directory?.appending(path: "\(Self.fileName(for: source.id))-\(width)x\(height).jpg")
        let work = Task.detached(priority: .userInitiated) { () async -> (image: CGImage, isFinal: Bool)? in
            await Self.load(source: source, photos: photoKit, diskURL: diskURL, width: width, height: height)
        }
        let result = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        guard let result else { return nil }
        let image = NSImage(cgImage: result.image, size: NSSize(width: result.image.width, height: result.image.height))
        if result.isFinal { cache.setObject(image, forKey: key) }
        return image
    }

    nonisolated private static func load(
        source: ThumbnailSource,
        photos: (any PhotosAssetSource)?,
        diskURL: URL?,
        width: Int,
        height: Int
    ) async -> (image: CGImage, isFinal: Bool)? {
        if let diskURL, let cached = decodedImage(at: diskURL) { return (cached, true) }
        // A cell that scrolled away before the work started needs nothing.
        guard !Task.isCancelled else { return nil }
        var made: CGImage?
        if let identifier = source.photosLocalIdentifier, let photos,
           let data = try? await photos.thumbnailData(
            forLocalIdentifier: identifier,
            targetSize: CGSize(width: width, height: height),
            networkAccessAllowed: true
           ) {
            made = decodedImage(data: data, maxPixelSize: max(width, height))
        }
        if made == nil, let bookmark = source.bookmark {
            made = fileThumbnail(bookmark: bookmark, maxPixelSize: max(width, height))
        }
        if let made {
            if let diskURL { writeJPEG(made, to: diskURL) }
            return (made, true)
        }
        guard let generated = DeterministicThumbnailRenderer.image(id: source.id, width: width, height: height) else { return nil }
        // Demo items have nothing else to show; real photos try again next time.
        if !source.hasOriginal, let diskURL { writeJPEG(generated, to: diskURL) }
        return (generated, !source.hasOriginal)
    }

    nonisolated private static func fileThumbnail(bookmark: Data, maxPixelSize: Int) -> CGImage? {
        guard let resolved = try? OriginalMediaBookmark.resolve(bookmark) else { return nil }
        // Outside the sandbox this returns false for plain paths; the file is
        // still readable, so it only decides whether to stop access again.
        let scoped = resolved.url.startAccessingSecurityScopedResource()
        defer { if scoped { resolved.url.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(resolved.url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary)
    }

    nonisolated private static func decodedImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    nonisolated private static func decodedImage(data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary)
    }

    nonisolated private static func writeJPEG(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }

    /// Photos identifiers contain "/", which cannot be in a file name.
    nonisolated private static func fileName(for id: String) -> String {
        id.replacingOccurrences(of: "/", with: "_")
    }

    /// Creates the folder and, once, removes the PNG thumbnails of earlier
    /// versions: some of them saved the generated picture for real photos.
    private static func prepare(_ directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Task.detached(priority: .utility) {
            let manager = FileManager.default
            guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return }
            for name in names where name.hasSuffix(".png") {
                try? manager.removeItem(at: directory.appending(path: name))
            }
        }
    }
}

struct ThumbnailView: View {
    let source: ThumbnailSource
    let width: Int
    let height: Int

    @State private var image: NSImage?

    init(item: MediaItem, width: Int, height: Int) {
        self.init(source: ThumbnailSource(item: item), width: width, height: height)
    }

    init(source: ThumbnailSource, width: Int, height: Int) {
        self.source = source
        self.width = width
        self.height = height
    }

    var body: some View {
        // A thumbnail already in memory is drawn in the first frame, so cells
        // that scroll back into view do not blink through the placeholder.
        let shown = image ?? ThumbnailCache.shared.cachedImage(for: source.id, width: width, height: height)
        // A still tint, not a spinner per cell: spinners animate every frame
        // and make fast scrolling heavier. The image sits in an overlay so a
        // wide or tall photo fills the frame it is given instead of growing
        // the cell around it.
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.quaternary)
            .overlay {
                if let shown {
                    Image(nsImage: shown)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            // Clipping hides the overflow but not its clicks.
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .task(id: "\(source.id)-\(width)x\(height)") {
                if let cached = ThumbnailCache.shared.cachedImage(for: source.id, width: width, height: height) {
                    image = cached
                    return
                }
                image = nil
                image = await ThumbnailCache.shared.image(for: source, width: width, height: height)
            }
    }
}
