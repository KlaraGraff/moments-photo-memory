import CoreGraphics
import MomentsCore
import ImageIO
import SwiftData
import UniformTypeIdentifiers
import XCTest
@testable import Moments

/// Regression guard for #42: the main context keeps reading relationships, as
/// LibraryView does while rendering, while a folder import saves through its
/// own context.
@MainActor
final class ImportConcurrencyTests: XCTestCase {
    func testMainContextReadsRelationshipsWhileFolderImportSaves() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "moments-import-concurrency-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "synthetic", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<20 {
            try writeSyntheticJPEG(to: folder.appending(path: "synthetic-\(index).jpg"), shade: CGFloat(index) / 20)
        }
        let container = try MomentsPersistence.makeContainer(url: root.appending(path: "Moments.store"))
        let importer = FolderImporter(
            geocoder: ConcurrencySyntheticGeocoder(),
            geocodeCache: ImportGeocodeCache()
        )
        let importTask = Task { try await importer.importFolder(folder, container: container) }

        // Keep reading until the import finishes; the deadline turns a hang into a failure.
        let deadline = Date.now.addingTimeInterval(30)
        var finished = false
        while !finished {
            let imported = try container.mainContext.fetch(FetchDescriptor<MediaItem>())
            _ = imported.map { ($0.place?.id, $0.trip?.id, $0.memories.count) }
            finished = imported.count >= 20
            if Date.now > deadline {
                importTask.cancel()
                XCTFail("Import did not finish within 30 s")
                break
            }
            await Task.yield()
        }
        let summary = try await importTask.value
        XCTAssertEqual(summary.importedCount, 20)
    }

    private func writeSyntheticJPEG(to url: URL, shade: CGFloat) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: shade, green: 0.5, blue: 1 - shade, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}

private struct ConcurrencySyntheticGeocoder: ImportGeocoder {
    func reverseGeocode(coordinate: MomentsCore.GeoPoint) async throws -> ImportGeocodeResult {
        ImportGeocodeResult(city: "Synthetic City", area: "Synthetic Area")
    }
}
