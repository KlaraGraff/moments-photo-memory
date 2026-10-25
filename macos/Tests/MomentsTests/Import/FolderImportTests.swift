import Foundation
import SwiftData
import XCTest
import MomentsCore
@testable import Moments

@MainActor
final class FolderImportTests: XCTestCase {
    func testSyntheticFolderImportIsIdempotentAndLeavesOriginalUntouched() async throws {
        let folder = try SyntheticMediaFixture.makeFolder()
        defer { SyntheticMediaFixture.removeFolder(folder) }
        let url = folder.appendingPathComponent("synthetic-a.jpg")
        try SyntheticMediaFixture.writeJPEG(
            at: url,
            date: Date(timeIntervalSince1970: 1_767_225_600),
            offset: "+02:00",
            latitude: 0.01,
            longitude: 0.02,
            marker: 1
        )
        let before = try MediaMetadataReader.sha256(url: url)
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let importer = FolderImporter(
            geocoder: SyntheticGeocoder(result: ImportGeocodeResult(city: "Synthetic City", area: "Synthetic Area")),
            geocodeCache: ImportGeocodeCache()
        )

        let first = try await importer.importFolder(folder, container: container)
        let second = try await importer.importFolder(folder, container: container)
        let after = try MediaMetadataReader.sha256(url: url)
        let items = try container.mainContext.fetch(FetchDescriptor<MediaItem>())

        XCTAssertEqual(first.importedCount, 1)
        XCTAssertEqual(second.importedCount, 0)
        XCTAssertEqual(second.skippedCount, 1)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.originalContentHash, before)
        XCTAssertEqual(after, before)
        XCTAssertEqual(items.first?.localDayKey, "2026-01-01")
        XCTAssertNotNil(items.first?.originalBookmarkData)
        let bookmark = try XCTUnwrap(items.first?.originalBookmarkData)
        let resolved = try OriginalMediaBookmark.resolve(bookmark)
        XCTAssertEqual(resolved.url.standardizedFileURL, url.standardizedFileURL)
    }

    func testSyntheticTripSplittingNoGPSAndJumpAreFlagged() async throws {
        let folder = try SyntheticMediaFixture.makeFolder()
        defer { SyntheticMediaFixture.removeFolder(folder) }
        let base = Date(timeIntervalSince1970: 1_767_225_600)
        try SyntheticMediaFixture.writeJPEG(at: folder.appendingPathComponent("one.jpg"), date: base, latitude: 0, longitude: 0, marker: 1)
        try SyntheticMediaFixture.writeJPEG(at: folder.appendingPathComponent("two.jpg"), date: base.addingTimeInterval(60), latitude: 0, longitude: 0.01, marker: 2)
        try SyntheticMediaFixture.writeJPEG(at: folder.appendingPathComponent("jump.jpg"), date: base.addingTimeInterval(120), latitude: 5, longitude: 5, marker: 3)
        try SyntheticMediaFixture.writeJPEG(at: folder.appendingPathComponent("return.jpg"), date: base.addingTimeInterval(180), latitude: 0, longitude: 0.02, marker: 4)
        let noGPS = folder.appendingPathComponent("no-gps.jpg")
        try SyntheticMediaFixture.writeJPEG(at: noGPS, date: base.addingTimeInterval(240), marker: 5)
        let fallback = folder.appendingPathComponent("file-date.jpg")
        try SyntheticMediaFixture.writeJPEG(at: fallback, date: nil, marker: 6)
        try FileManager.default.setAttributes([.modificationDate: base], ofItemAtPath: fallback.path)
        try SyntheticMediaFixture.writeJPEG(
            at: folder.appendingPathComponent("far-date.jpg"),
            date: base.addingTimeInterval(400 * 24 * 60 * 60),
            latitude: 0,
            longitude: 0.03,
            marker: 7
        )

        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let importer = FolderImporter(
            geocoder: SyntheticGeocoder(result: ImportGeocodeResult(city: "Synthetic City")),
            geocodeCache: ImportGeocodeCache()
        )
        let summary = try await importer.importFolder(folder, container: container)
        let reasons = Dictionary(uniqueKeysWithValues: summary.flags.map { ($0.fileName, Set($0.reasons)) })

        XCTAssertGreaterThanOrEqual(summary.tripCount, 2)
        XCTAssertTrue(reasons["no-gps.jpg"]?.contains(.missingLocation) == true)
        XCTAssertTrue(reasons["file-date.jpg"]?.contains(.fileDateFallback) == true)
        let importedItems = try container.mainContext.fetch(FetchDescriptor<MediaItem>())
        let fallbackItem = try XCTUnwrap(importedItems.first(where: { $0.title == "file-date.jpg" }))
        XCTAssertNil(fallbackItem.captureDate)
        XCTAssertEqual(fallbackItem.timeConfidence, .low)
        XCTAssertTrue(reasons["jump.jpg"]?.contains(.gpsJump) == true)
        XCTAssertTrue(reasons["far-date.jpg"]?.contains(.captureDateOutsideTrip) == true)
        XCTAssertNotNil(summary.flags.first(where: { $0.fileName == "no-gps.jpg" })?.suggestedPlaceName)
    }

    func testAirDropAndNearDuplicateCandidatesKeepEveryExactSourceReference() async throws {
        let folder = try SyntheticMediaFixture.makeFolder()
        defer { SyntheticMediaFixture.removeFolder(folder) }
        let date = Date(timeIntervalSince1970: 1_767_225_600)
        try SyntheticMediaFixture.writeJPEG(at: folder.appendingPathComponent("duplicate-a.jpg"), date: date, marker: 31)
        try SyntheticMediaFixture.writeJPEG(at: folder.appendingPathComponent("duplicate-b.jpg"), date: date, marker: 31)
        try SyntheticMediaFixture.writeJPEG(at: folder.appendingPathComponent("AirDrop-received.jpg"), date: date, marker: 32)
        let near = folder.appendingPathComponent("near.jpg")
        try SyntheticMediaFixture.writeJPEG(at: near, date: date, marker: 33)

        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let importer = FolderImporter(
            geocoder: SyntheticGeocoder(result: ImportGeocodeResult(city: "Synthetic City")),
            geocodeCache: ImportGeocodeCache()
        )
        let summary = try await importer.importFolder(folder, container: container)
        let byName = Dictionary(uniqueKeysWithValues: summary.flags.map { ($0.fileName, Set($0.reasons)) })
        let items = try container.mainContext.fetch(FetchDescriptor<MediaItem>())

        XCTAssertEqual(items.count, 3)
        XCTAssertTrue(byName["AirDrop-received.jpg"]?.contains(.airDropReceived) == true)
        XCTAssertTrue(byName["AirDrop-received.jpg"]?.contains(.missingLocation) == true)
        XCTAssertTrue(byName["near.jpg"]?.contains(.nearDuplicate) == true)
        let duplicate = try XCTUnwrap(items.first { item in
            guard let data = item.sourceReferencesRaw?.data(using: .utf8),
                  let references = try? JSONDecoder().decode([ImportedSourceReference].self, from: data) else { return false }
            return references.count == 2
        })
        XCTAssertNotNil(duplicate.originalContentHash)
    }

    func testSyntheticImportUsesLocalExifOffsetForDayBoundary() async throws {
        let folder = try SyntheticMediaFixture.makeFolder()
        defer { SyntheticMediaFixture.removeFolder(folder) }
        let first = folder.appendingPathComponent("west.jpg")
        let second = folder.appendingPathComponent("east.jpg")
        try SyntheticMediaFixture.writeJPEG(at: first, date: Date(timeIntervalSince1970: 1_767_310_200), offset: "+02:00", latitude: 0, longitude: 0, marker: 11)
        try SyntheticMediaFixture.writeJPEG(at: second, date: Date(timeIntervalSince1970: 1_767_313_800), offset: "-05:00", latitude: 0, longitude: 0.01, marker: 12)
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let importer = FolderImporter(
            geocoder: SyntheticGeocoder(result: ImportGeocodeResult(city: "Synthetic City")),
            geocodeCache: ImportGeocodeCache()
        )
        _ = try await importer.importFolder(folder, container: container)
        let items = try container.mainContext.fetch(FetchDescriptor<MediaItem>()).sorted { $0.title < $1.title }
        XCTAssertEqual(items.map(\.localDayKey), ["2026-01-01", "2026-01-02"])
        XCTAssertEqual(Set(items.compactMap(\.localTimeZoneOffsetMinutes)), [120, -300])
    }

    func testOffsetlessExifResolvesUsingCoordinateTimeZoneBeforeOrdering() async throws {
        let folder = try SyntheticMediaFixture.makeFolder()
        defer { SyntheticMediaFixture.removeFolder(folder) }
        // The first file stores 22:30 as a local wall-clock value with no
        // offset. Shanghai resolves that to 14:30 UTC, before the 14:45 file.
        try SyntheticMediaFixture.writeJPEG(
            at: folder.appendingPathComponent("wall-clock.jpg"),
            date: Date(timeIntervalSince1970: 1_767_306_600),
            offset: nil,
            latitude: 31.2,
            longitude: 121.5,
            marker: 41
        )
        try SyntheticMediaFixture.writeJPEG(
            at: folder.appendingPathComponent("offset.jpg"),
            date: Date(timeIntervalSince1970: 1_767_278_700),
            offset: "+00:00",
            latitude: 31.2,
            longitude: 121.5,
            marker: 42
        )

        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let importer = FolderImporter(
            geocoder: SyntheticGeocoder(result: ImportGeocodeResult(city: "Shanghai", timeZoneIdentifier: "Asia/Shanghai")),
            geocodeCache: ImportGeocodeCache(),
            geocodeDelay: {}
        )
        let summary = try await importer.importFolder(folder, container: container)
        let items = try container.mainContext.fetch(FetchDescriptor<MediaItem>()).sorted { $0.captureDate! < $1.captureDate! }
        let wallClock = try XCTUnwrap(items.first(where: { $0.title == "wall-clock.jpg" }))
        XCTAssertEqual(items.map(\.title), ["wall-clock.jpg", "offset.jpg"])
        XCTAssertEqual(wallClock.localDayKey, "2026-01-01")
        XCTAssertEqual(wallClock.timeConfidence, .exact)
        XCTAssertTrue(summary.flags.allSatisfy { !$0.reasons.contains(.timeZoneUnknown) })
    }

    func testOffsetlessExifWithoutZoneUsesLowConfidenceAndReviewReason() async throws {
        let folder = try SyntheticMediaFixture.makeFolder()
        defer { SyntheticMediaFixture.removeFolder(folder) }
        try SyntheticMediaFixture.writeJPEG(
            at: folder.appendingPathComponent("unknown-zone.jpg"),
            date: Date(timeIntervalSince1970: 1_767_306_600),
            offset: nil,
            marker: 43
        )
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let importer = FolderImporter(geocoder: SyntheticGeocoder(result: ImportGeocodeResult()), geocodeCache: ImportGeocodeCache(), geocodeDelay: {})
        let summary = try await importer.importFolder(folder, container: container)
        let item = try XCTUnwrap(try container.mainContext.fetch(FetchDescriptor<MediaItem>()).first)
        XCTAssertEqual(item.timeConfidence, .zoneUnknown)
        XCTAssertTrue(summary.flags.first?.reasons.contains(.timeZoneUnknown) == true)
        XCTAssertNotNil(item.captureDate)
    }

    func testGeocodingFailureLeavesPlaceUnnamedAndContinuesImport() async throws {
        let folder = try SyntheticMediaFixture.makeFolder()
        defer { SyntheticMediaFixture.removeFolder(folder) }
        let date = Date(timeIntervalSince1970: 1_767_225_600)
        try SyntheticMediaFixture.writeJPEG(at: folder.appendingPathComponent("named.jpg"), date: date, latitude: 0, longitude: 0, marker: 44)
        try SyntheticMediaFixture.writeJPEG(at: folder.appendingPathComponent("retry.jpg"), date: date.addingTimeInterval(60), latitude: 5, longitude: 5, marker: 45)
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let importer = FolderImporter(
            geocoder: ThrowingSyntheticGeocoder(),
            geocodeCache: ImportGeocodeCache(),
            geocodeDelay: {}
        )
        let summary = try await importer.importFolder(folder, container: container)
        let places = try container.mainContext.fetch(FetchDescriptor<Place>())
        XCTAssertEqual(summary.importedCount, 2)
        XCTAssertTrue(places.contains { $0.name == "Synthetic City" })
        XCTAssertTrue(places.contains { $0.name.isEmpty })
        XCTAssertTrue(summary.flags.contains { $0.reasons.contains(.geocodingRetry) })
    }

    func testOneThousandFiveHundredSyntheticFilesFinishUnderSixtySeconds() async throws {
        let folder = try SyntheticMediaFixture.makeFolder()
        defer { SyntheticMediaFixture.removeFolder(folder) }
        let base = Date(timeIntervalSince1970: 1_767_225_600)
        for index in 0..<1_500 {
            try SyntheticMediaFixture.writeJPEG(
                at: folder.appendingPathComponent(String(format: "image-%04d.jpg", index)),
                date: base.addingTimeInterval(TimeInterval(index * 60)),
                latitude: nil,
                longitude: nil,
                marker: index
            )
        }
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let importer = FolderImporter(geocodeCache: ImportGeocodeCache())
        let started = Date()
        let summary = try await importer.importFolder(folder, container: container)
        let elapsed = Date().timeIntervalSince(started)
        print("Synthetic 1,500-file import: \(String(format: "%.3f", elapsed)) s")
        XCTAssertEqual(summary.importedCount, 1_500)
        XCTAssertLessThan(elapsed, 60)
    }

    func testTripReviewCorrectionsPersistAsOverrides() throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let first = Trip(id: "synthetic-trip-a", name: "Trip A")
        let second = Trip(id: "synthetic-trip-b", name: "Trip B")
        first.overrideName = "Renamed trip"
        first.splitOverrideDayKeys = "2026-01-01"
        second.mergeOverrideID = first.id
        context.insert(first)
        context.insert(second)
        try context.save()

        let trips = try context.fetch(FetchDescriptor<Trip>())
        XCTAssertEqual(trips.first(where: { $0.id == first.id })?.effectiveName, "Renamed trip")
        XCTAssertEqual(trips.first(where: { $0.id == first.id })?.splitOverrideDayKeys, "2026-01-01")
        XCTAssertEqual(trips.first(where: { $0.id == second.id })?.mergeOverrideID, first.id)
    }
}

private struct SyntheticGeocoder: ImportGeocoder {
    let result: ImportGeocodeResult

    func reverseGeocode(coordinate: MomentsCore.GeoPoint) async throws -> ImportGeocodeResult {
        result
    }
}

private struct ThrowingSyntheticGeocoder: ImportGeocoder {
    enum Failure: Error { case unavailable }

    func reverseGeocode(coordinate: MomentsCore.GeoPoint) async throws -> ImportGeocodeResult {
        if coordinate.longitude > 1 { throw Failure.unavailable }
        return ImportGeocodeResult(city: "Synthetic City", timeZoneIdentifier: "UTC")
    }
}
