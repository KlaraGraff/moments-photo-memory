import CoreGraphics
import Foundation
import ImageIO
import MomentsCore
import XCTest
@testable import Moments

final class SharedPreviewTests: XCTestCase {
    private func syntheticImage(width: Int, height: Int) -> CGImage {
        let space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context: CGContext = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.7, green: 0.4, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 3))
        return context.makeImage()!
    }

    func testLargePhotosShrinkToTheLongEdgeAndKeepTheirShape() throws {
        let rendered: SharedPreview.Rendered = try XCTUnwrap(SharedPreview.render(syntheticImage(width: 4000, height: 3000)))
        XCTAssertEqual(rendered.asset.pixelWidth, 2048)
        XCTAssertEqual(rendered.asset.pixelHeight, 1536)
        XCTAssertEqual(rendered.asset.byteCount, rendered.data.count)
        XCTAssertEqual(rendered.asset.sha256, SharedPreview.sha256(rendered.data))
        XCTAssertEqual(rendered.asset.sha256.count, 64)

        let portrait: SharedPreview.Rendered = try XCTUnwrap(SharedPreview.render(syntheticImage(width: 3000, height: 4000)))
        XCTAssertEqual(portrait.asset.pixelWidth, 1536)
        XCTAssertEqual(portrait.asset.pixelHeight, 2048)
    }

    func testSmallPhotosAreNotEnlarged() throws {
        let rendered: SharedPreview.Rendered = try XCTUnwrap(SharedPreview.render(syntheticImage(width: 640, height: 480)))
        XCTAssertEqual(rendered.asset.pixelWidth, 640)
        XCTAssertEqual(rendered.asset.pixelHeight, 480)
    }

    func testThePreviewCarriesNoLocationOrCameraData() throws {
        let rendered: SharedPreview.Rendered = try XCTUnwrap(SharedPreview.render(syntheticImage(width: 1200, height: 900)))
        let source: CGImageSource = try XCTUnwrap(CGImageSourceCreateWithData(rendered.data as CFData, nil))
        let properties: [String: Any] = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]) ?? [:]
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary as String])
        XCTAssertNil(properties[kCGImagePropertyTIFFDictionary as String].flatMap { ($0 as? [String: Any])?[kCGImagePropertyTIFFModel as String] })
        let exif: [String: Any] = (properties[kCGImagePropertyExifDictionary as String] as? [String: Any]) ?? [:]
        XCTAssertNil(exif[kCGImagePropertyExifDateTimeOriginal as String])
    }

    func testPreviewRecordFollowsItsPhoto() {
        let asset = SyncAssetRef(sha256: String(repeating: "a", count: 64), byteCount: 10, pixelWidth: 2, pixelHeight: 1)
        let record: SyncRecord = SharedPreview.record(mediaID: "m1", asset: asset, updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(record.id, "preview:m1")
        XCTAssertEqual(record["mediaID"], .reference("m1"))
        XCTAssertEqual(SyncSchema.unknownFields(in: record), [])
        let keys: Set<SyncRecordKey> = SharingScopeResolver.includedKeys(scope: .selectedTrips(["t1"]), records: [
            SyncRecord(type: .trip, id: "t1", fields: ["updatedAt": .date(Date(timeIntervalSince1970: 0))]),
            SyncRecord(type: .mediaItem, id: "m1", fields: ["tripID": .reference("t1"), "updatedAt": .date(Date(timeIntervalSince1970: 0))]),
            record
        ])
        XCTAssertTrue(keys.contains(record.key))
    }

    func testPreviewFilesLiveUnderTheirOwnFolderWithoutThePhotoID() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "moments-previews-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = SharedPreviewFiles(folder: folder)
        let url: URL = try files.write(Data([1, 2, 3]), mediaID: "IMG 0001/secret")
        XCTAssertFalse(url.lastPathComponent.contains("IMG"))
        XCTAssertEqual(files.data(mediaID: "IMG 0001/secret"), Data([1, 2, 3]))
        files.remove(mediaID: "IMG 0001/secret")
        XCTAssertNil(files.data(mediaID: "IMG 0001/secret"))
    }
}
