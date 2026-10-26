import MomentsCore
import SwiftData
import XCTest
@testable import Moments

/// A slow, counting geocoder standing in for the rate-limited CLGeocoder.
private actor CountingSlowGeocoder: ImportGeocoder {
    private(set) var calls = 0
    let delay: UInt64
    let fails: Bool
    init(delayMilliseconds: UInt64, fails: Bool = false) {
        delay = delayMilliseconds * 1_000_000
        self.fails = fails
    }
    func reverseGeocode(coordinate: GeoPoint) async throws -> ImportGeocodeResult {
        calls += 1
        try await Task.sleep(nanoseconds: delay)
        if fails { throw URLError(.timedOut) }
        return ImportGeocodeResult(city: "Synthetic City", area: "Synthetic Area", timeZoneIdentifier: "Europe/Berlin")
    }
}

/// Regression guard for large folders: thousands of photos without a time-zone
/// offset used to trigger one rate-limited reverse-geocode call per photo.
@MainActor
final class LargeFolderImportTests: XCTestCase {
    private func writeFolder(count: Int) throws -> URL {
        let folder = try SyntheticMediaFixture.makeFolder()
        let start = Date(timeIntervalSince1970: 1_767_225_600)
        for index in 0..<count {
            // Three trips in three areas, a photo every ten minutes, no EXIF offset.
            let area = index * 3 / count
            try SyntheticMediaFixture.writeJPEG(
                at: folder.appendingPathComponent("synthetic-\(index).jpg"),
                date: start.addingTimeInterval(Double(index) * 600 + Double(area) * 864_000),
                offset: nil,
                latitude: 10 + Double(area) * 5 + Double(index % 50) * 0.0004,
                longitude: 10 + Double(area) * 5 + Double(index % 37) * 0.0004,
                marker: index
            )
        }
        return folder
    }

    func testLargeFolderImportsQuicklyWithFewGeocodeCalls() async throws {
        let folder = try writeFolder(count: 1_200)
        defer { SyntheticMediaFixture.removeFolder(folder) }
        let geocoder = CountingSlowGeocoder(delayMilliseconds: 50)
        let importer = FolderImporter(geocoder: geocoder, geocodeCache: ImportGeocodeCache(), geocodeDelay: {})
        let container = try MomentsPersistence.makeContainer(inMemory: true)

        let started = Date()
        let summary = try await importer.importFolder(folder, container: container)
        let elapsed = Date().timeIntervalSince(started)
        let calls = await geocoder.calls

        XCTAssertEqual(summary.importedCount, 1_200)
        XCTAssertLessThanOrEqual(calls, 60, "Geocoding must be grouped by area, not done per photo")
        XCTAssertLessThan(elapsed, 120, "Import of 1,200 photos took \(Int(elapsed)) s")
    }

    func testFailingGeocoderNeverBlocksImport() async throws {
        let folder = try writeFolder(count: 300)
        defer { SyntheticMediaFixture.removeFolder(folder) }
        let geocoder = CountingSlowGeocoder(delayMilliseconds: 50, fails: true)
        let importer = FolderImporter(geocoder: geocoder, geocodeCache: ImportGeocodeCache(), geocodeDelay: {})
        let container = try MomentsPersistence.makeContainer(inMemory: true)

        let summary = try await importer.importFolder(folder, container: container)
        let calls = await geocoder.calls

        XCTAssertEqual(summary.importedCount, 300)
        XCTAssertLessThanOrEqual(calls, 10, "Lookups must stop after repeated failures")
    }
}
