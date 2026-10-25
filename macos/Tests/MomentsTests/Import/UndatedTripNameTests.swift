import CoreGraphics
import ImageIO
import MomentsCore
import SwiftData
import UniformTypeIdentifiers
import XCTest
@testable import Moments

final class UndatedTripNameTests: XCTestCase {
    func testUndatedTripUsesSpecificFolderName() {
        XCTAssertEqual(ImportOrganizer.undatedTripName(folderName: "Synthetic Coast Weekend"), "Synthetic Coast Weekend")
        XCTAssertEqual(ImportOrganizer.undatedTripName(folderName: "  Synthetic Hills  "), "Synthetic Hills")
        for name in ["2025Rome", "2024Bali", "2023_ITA", "1000days", "2025 Rome", "100 days"] {
            XCTAssertEqual(ImportOrganizer.undatedTripName(folderName: name), name)
        }
    }

    func testUndatedTripFallsBackForGenericOrMissingFolderNames() {
        let fallback = String(localized: "Undated photos")
        for name in [nil, "", "Downloads", "DCIM", "100APPLE", "101MSDCF", "100_PANA", "Untitled", "NO NAME", "EOS_DIGITAL", "Desktop", "下载", "New Folder"] {
            XCTAssertEqual(ImportOrganizer.undatedTripName(folderName: name), fallback, "\(String(describing: name))")
        }
    }

    @MainActor
    func testFolderImportWithoutCaptureDatesNamesTripAfterFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "moments-undated-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "Synthetic Lake Trip", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<3 {
            let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.setFillColor(CGColor(red: CGFloat(index) / 3, green: 0.4, blue: 0.6, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
            let url = folder.appending(path: "synthetic-\(index).jpg")
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let importer = FolderImporter(geocoder: UndatedSyntheticGeocoder(), geocodeCache: ImportGeocodeCache())

        let summary = try await importer.importFolder(folder, container: container)

        XCTAssertEqual(summary.trips.map(\.name), ["Synthetic Lake Trip"])
        XCTAssertTrue(summary.trips.allSatisfy(\.isSuggestion))
    }
}

private struct UndatedSyntheticGeocoder: ImportGeocoder {
    func reverseGeocode(coordinate: MomentsCore.GeoPoint) async throws -> ImportGeocodeResult {
        ImportGeocodeResult(city: "Synthetic City", area: "Synthetic Area")
    }
}
