import AppKit
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Moments

/// Thumbnails must show the real photo: folder items from the original file,
/// Apple Photos items from PhotoKit. The generated picture is only for demo
/// items and is never saved in place of a photo that could not be read.
@MainActor
final class ThumbnailCacheTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "ThumbnailCacheTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testFolderItemShowsTheOriginalFile() async throws {
        let photo = folder.appending(path: "red.jpg")
        try writeSolidJPEG(red: 255, green: 0, blue: 0, to: photo)
        // The importer stores this fallback when it cannot make a bookmark;
        // outside the sandbox it is not security scoped.
        let bookmark = Data(OriginalMediaBookmark.pathFallbackPrefix.utf8) + Data(photo.path.utf8)
        let cacheFolder = folder.appending(path: "cache", directoryHint: .isDirectory)
        let cache = ThumbnailCache(directory: cacheFolder, photos: nil)

        let image = await cache.image(for: ThumbnailSource(id: "folder-1", bookmark: bookmark), width: 120, height: 90)

        let pixel = try XCTUnwrap(image.flatMap(centrePixel))
        XCTAssertGreaterThan(pixel.red, 200)
        XCTAssertLessThan(pixel.green, 40)
        XCTAssertLessThan(pixel.blue, 40)
        let saved = try FileManager.default.contentsOfDirectory(atPath: cacheFolder.path)
        XCTAssertEqual(saved, ["folder-1-120x90.jpg"])
    }

    func testFolderVideoShowsAFrame() async throws {
        let video = folder.appending(path: "green.mov")
        try await writeSolidVideo(red: 0, green: 255, blue: 0, to: video)
        let bookmark = Data(OriginalMediaBookmark.pathFallbackPrefix.utf8) + Data(video.path.utf8)
        let cacheFolder = folder.appending(path: "cache", directoryHint: .isDirectory)
        let cache = ThumbnailCache(directory: cacheFolder, photos: nil)

        let image = await cache.image(for: ThumbnailSource(id: "video-1", bookmark: bookmark), width: 120, height: 90)

        let pixel = try XCTUnwrap(image.flatMap(centrePixel))
        XCTAssertLessThan(pixel.red, 60)
        XCTAssertGreaterThan(pixel.green, 180)
        XCTAssertLessThan(pixel.blue, 60)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cacheFolder.path), ["video-1-120x90.jpg"])
    }

    func testPhotosItemShowsThePhotoKitImage() async throws {
        let photos = ThumbnailPhotosSource()
        photos.data = try solidPNG(red: 0, green: 0, blue: 255)
        let cache = ThumbnailCache(directory: folder.appending(path: "cache", directoryHint: .isDirectory), photos: photos)

        let image = await cache.image(for: ThumbnailSource(id: "photos-1", photosLocalIdentifier: "ABC/L0/001"), width: 120, height: 90)

        let pixel = try XCTUnwrap(image.flatMap(centrePixel))
        XCTAssertLessThan(pixel.red, 40)
        XCTAssertGreaterThan(pixel.blue, 200)
        XCTAssertEqual(photos.requests, ["ABC/L0/001"])
    }

    func testUnreadablePhotoIsRetriedInsteadOfSavingTheStandIn() async throws {
        let photos = ThumbnailPhotosSource()
        let cacheFolder = folder.appending(path: "cache", directoryHint: .isDirectory)
        let cache = ThumbnailCache(directory: cacheFolder, photos: photos)
        let source = ThumbnailSource(id: "photos-2", photosLocalIdentifier: "DEF/L0/001")

        let standIn = await cache.image(for: source, width: 120, height: 90)
        XCTAssertNotNil(standIn, "A cell still gets something to draw")
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: cacheFolder.path)) ?? [], [])
        XCTAssertNil(cache.cachedImage(for: source.id, width: 120, height: 90))

        // Photos becomes readable (for example after the user allows access).
        photos.data = try solidPNG(red: 0, green: 0, blue: 255)
        let image = await cache.image(for: source, width: 120, height: 90)
        let pixel = try XCTUnwrap(image.flatMap(centrePixel))
        XCTAssertGreaterThan(pixel.blue, 200)
        XCTAssertEqual(photos.requests.count, 2)
    }

    func testNoPhotoKitRequestWithoutAccess() async throws {
        let photos = ThumbnailPhotosSource()
        photos.status = .notDetermined
        photos.data = try solidPNG(red: 0, green: 0, blue: 255)
        let cache = ThumbnailCache(directory: nil, photos: photos)

        _ = await cache.image(for: ThumbnailSource(id: "photos-3", photosLocalIdentifier: "GHI/L0/001"), width: 60, height: 45)

        XCTAssertEqual(photos.requests, [], "Asking PhotoKit before the user allowed access could show the system prompt")
    }

    // MARK: - Helpers

    private func solidImage(red: UInt8, green: UInt8, blue: UInt8) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        return try XCTUnwrap(context.makeImage())
    }

    private func writeSolidJPEG(red: UInt8, green: UInt8, blue: UInt8, to url: URL) throws {
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try solidImage(red: red, green: green, blue: blue), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    /// One second of a single colour, H.264 in a QuickTime file.
    private func writeSolidVideo(red: UInt8, green: UInt8, blue: UInt8, to url: URL) async throws {
        let width = 64, height = 48
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
            let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * rowBytes + x * 4
                    base[offset] = blue; base[offset + 1] = green; base[offset + 2] = red; base[offset + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, String(describing: writer.error))
    }

    private func solidPNG(red: UInt8, green: UInt8, blue: UInt8) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try solidImage(red: red, green: green, blue: blue), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func centrePixel(_ image: NSImage) -> (red: Int, green: Int, blue: Int)? {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            let width = CGFloat(cgImage.width), height = CGFloat(cgImage.height)
            context.draw(cgImage, in: CGRect(x: -width / 2, y: -height / 2, width: width, height: height))
            return true
        }
        return drawn ? (Int(pixel[0]), Int(pixel[1]), Int(pixel[2])) : nil
    }
}

private final class ThumbnailPhotosSource: PhotosAssetSource, @unchecked Sendable {
    var status: PhotosAuthorizationStatus = .authorized
    var data: Data?
    private(set) var requests: [String] = []

    var authorizationStatus: PhotosAuthorizationStatus { status }
    func requestAuthorization() async -> PhotosAuthorizationStatus { status }
    func fetchAssets(selection: PhotosImportSelection) async throws -> [PhotosAssetDescriptor] { [] }
    func observeChanges(_ handler: @escaping @Sendable (PhotosChangeEvent) -> Void) -> any PhotosChangeObservation {
        ThumbnailObservation()
    }

    func thumbnailData(forLocalIdentifier localIdentifier: String, targetSize: CGSize, networkAccessAllowed: Bool) async throws -> Data? {
        requests.append(localIdentifier)
        return data
    }

    func thumbnailImage(forLocalIdentifier localIdentifier: String, targetSize: CGSize, networkAccessAllowed: Bool) async -> CGImage? {
        nil
    }
}

private final class ThumbnailObservation: PhotosChangeObservation {
    func invalidate() {}
}
