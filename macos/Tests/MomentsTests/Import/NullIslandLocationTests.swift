import MomentsCore
import SwiftData
import XCTest
@testable import Moments

/// GPS exactly at (0, 0) comes from missing or stripped metadata, so imports
/// treat it as "no location".
final class NullIslandLocationTests: XCTestCase {
    func testPlaceholderRuleKeepsRealCoordinatesNearZero() {
        XCTAssertNil(ImportLocation.usable(latitude: 0, longitude: 0))
        XCTAssertNil(ImportLocation.usable(latitude: nil, longitude: 0.5))
        XCTAssertNotNil(ImportLocation.usable(latitude: 0.0001, longitude: 0))
        XCTAssertNotNil(ImportLocation.usable(latitude: 0, longitude: 0.01))
    }

    @MainActor
    func testFolderImportTreatsZeroZeroAsNoLocation() async throws {
        let folder = try SyntheticMediaFixture.makeFolder()
        defer { SyntheticMediaFixture.removeFolder(folder) }
        try SyntheticMediaFixture.writeJPEG(
            at: folder.appendingPathComponent("synthetic-null-island.jpg"),
            date: Date(timeIntervalSince1970: 1_767_225_600),
            offset: "+00:00",
            latitude: 0,
            longitude: 0,
            marker: 1
        )
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let importer = FolderImporter(geocoder: NullIslandGeocoder(), geocodeCache: ImportGeocodeCache())

        let summary = try await importer.importFolder(folder, container: container)
        let item = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<MediaItem>()).first)

        XCTAssertNil(item.latitude)
        XCTAssertNil(item.longitude)
        XCTAssertNil(item.place)
        XCTAssertTrue(summary.flags.flatMap(\.reasons).contains(.missingLocation))
    }

    func testPhotosImportTreatsZeroZeroAsNoLocation() {
        let asset = PhotosAssetDescriptor(
            localIdentifier: "synthetic-null-island",
            creationDate: Date(timeIntervalSince1970: 1_767_225_600),
            location: GeoPoint(latitude: 0, longitude: 0),
            mediaType: .image,
            pixelWidth: 10,
            pixelHeight: 10
        )
        let mapped = PhotosMetadataMapper().map(asset)
        XCTAssertNil(mapped.metadata.latitude)
        XCTAssertNil(mapped.metadata.longitude)
    }
}

private struct NullIslandGeocoder: ImportGeocoder {
    func reverseGeocode(coordinate: MomentsCore.GeoPoint) async throws -> ImportGeocodeResult {
        ImportGeocodeResult(city: "Synthetic City", area: "Synthetic Area")
    }
}
