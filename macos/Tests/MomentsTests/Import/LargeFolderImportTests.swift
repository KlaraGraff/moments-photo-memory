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

/// Names each synthetic place after its rounded latitude.
private actor NamingGeocoder: ImportGeocoder {
    private(set) var calls = 0
    var fails = false
    func setFails(_ value: Bool) { fails = value }
    func reverseGeocode(coordinate: GeoPoint) async throws -> ImportGeocodeResult {
        calls += 1
        try await Task.sleep(nanoseconds: 5_000_000)
        if fails { throw URLError(.notConnectedToInternet) }
        let index = Int(coordinate.latitude.rounded())
        return ImportGeocodeResult(city: "City \(index)", area: "Area \(index)", timeZoneIdentifier: "Europe/Berlin")
    }
}

/// Never finishes in time and ignores cancellation, like a stuck CLGeocoder.
private struct StuckGeocoder: ImportGeocoder {
    func reverseGeocode(coordinate: GeoPoint) async throws -> ImportGeocodeResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { continuation.resume() }
        }
        return ImportGeocodeResult(city: "Too late")
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

    /// Sixty far-apart places, one photo each, without an EXIF offset.
    private func writeSixtyPlaces() throws -> URL {
        let folder = try SyntheticMediaFixture.makeFolder()
        let start = Date(timeIntervalSince1970: 1_767_225_600)
        for index in 0..<60 {
            try SyntheticMediaFixture.writeJPEG(
                at: folder.appendingPathComponent("place-\(index).jpg"),
                date: start.addingTimeInterval(Double(index) * 86_400 * 3),
                offset: nil,
                latitude: Double(index) - 30,
                longitude: 20,
                marker: index
            )
        }
        return folder
    }

    private func cityNames(in container: ModelContainer) throws -> [String] {
        let city = PlaceKind.city.rawValue
        return try ModelContext(container)
            .fetch(FetchDescriptor<Place>(predicate: #Predicate { $0.kindRaw == city }))
            .map(\.name)
    }

    private func retryFlagCount(in container: ModelContainer) throws -> Int {
        try ModelContext(container).fetch(FetchDescriptor<MediaItem>())
            .filter { ($0.importReviewReasonsRaw ?? "").contains(ImportReviewReason.geocodingRetry.rawValue) }
            .count
    }

    func testBackfillNamesPlacesTheImportBudgetSkipped() async throws {
        let folder = try writeSixtyPlaces()
        defer { SyntheticMediaFixture.removeFolder(folder) }
        let geocoder = NamingGeocoder()
        let cache = ImportGeocodeCache()
        let importer = FolderImporter(geocoder: geocoder, geocodeCache: cache, geocodeDelay: {})
        let container = try MomentsPersistence.makeContainer(inMemory: true)

        let started = Date()
        let summary = try await importer.importFolder(folder, container: container)
        XCTAssertEqual(summary.importedCount, 60)
        XCTAssertLessThan(Date().timeIntervalSince(started), 30)

        let afterImport = try cityNames(in: container)
        XCTAssertEqual(afterImport.count, 60)
        // Time zones get at most 10 of the 40 lookups, so places get the rest.
        XCTAssertGreaterThanOrEqual(afterImport.filter { !$0.isEmpty }.count, 30)
        XCTAssertGreaterThan(afterImport.filter(\.isEmpty).count, 0, "The test needs places past the budget")
        XCTAssertGreaterThan(try retryFlagCount(in: container), 0)

        let named = try await PlaceNameBackfill(geocoder: geocoder, geocodeCache: cache, interval: .zero).run(container: container)

        let afterBackfill = try cityNames(in: container)
        XCTAssertEqual(named, afterImport.filter(\.isEmpty).count)
        XCTAssertTrue(afterBackfill.allSatisfy { $0.hasPrefix("City ") }, "Unnamed: \(afterBackfill.filter { !$0.hasPrefix("City ") })")
        XCTAssertEqual(try retryFlagCount(in: container), 0)
    }

    func testBackfillStopsOnFailuresAndResumesFromStoredState() async throws {
        let folder = try writeSixtyPlaces()
        defer { SyntheticMediaFixture.removeFolder(folder) }
        let geocoder = NamingGeocoder()
        let importer = FolderImporter(geocoder: geocoder, geocodeCache: ImportGeocodeCache(), geocodeDelay: {})
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        _ = try await importer.importFolder(folder, container: container)
        let unnamed = try cityNames(in: container).filter(\.isEmpty).count

        // Offline: three failures in a row end the run, nothing is lost.
        await geocoder.setFails(true)
        let callsBefore = await geocoder.calls
        let offline = try await PlaceNameBackfill(geocoder: geocoder, geocodeCache: ImportGeocodeCache(), interval: .zero).run(container: container)
        let offlineCalls = await geocoder.calls - callsBefore
        XCTAssertEqual(offline, 0)
        XCTAssertEqual(offlineCalls, 3)
        XCTAssertEqual(try cityNames(in: container).filter(\.isEmpty).count, unnamed)

        // A later run (a new launch, fresh memory) finds the same work in the store.
        await geocoder.setFails(false)
        let online = try await PlaceNameBackfill(geocoder: geocoder, geocodeCache: ImportGeocodeCache(), interval: .zero).run(container: container)
        XCTAssertEqual(online, unnamed)
        XCTAssertTrue(try cityNames(in: container).allSatisfy { !$0.isEmpty })
    }

    func testLookupTimeoutDoesNotWaitForAStuckGeocoder() async throws {
        let geocoder = StuckGeocoder()
        let started = Date()
        let result = try await ImportGeocodeGate.firstResult(within: .milliseconds(200)) {
            try await geocoder.reverseGeocode(coordinate: GeoPoint(latitude: 1, longitude: 1))
        }
        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    func testNearestTimeZoneMatchesLinearSearch() {
        let base = Date(timeIntervalSince1970: 0)
        let sorted: [(date: Date, identifier: String)] = [
            (base, "A"), (base.addingTimeInterval(100), "C"), (base.addingTimeInterval(100), "B"),
            (base.addingTimeInterval(300), "D")
        ].sorted { $0.date == $1.date ? $0.identifier < $1.identifier : $0.date < $1.date }
        for offset in stride(from: -50.0, through: 400, by: 25) {
            let date = base.addingTimeInterval(offset)
            let linear = sorted.min { lhs, rhs in
                let left = abs(lhs.date.timeIntervalSince(date)), right = abs(rhs.date.timeIntervalSince(date))
                return left == right ? lhs.identifier < rhs.identifier : left < right
            }?.identifier
            XCTAssertEqual(ImportOrganizer.nearestIdentifier(in: sorted, to: date), linear, "offset \(offset)")
        }
        XCTAssertNil(ImportOrganizer.nearestIdentifier(in: [], to: base))
    }
}
