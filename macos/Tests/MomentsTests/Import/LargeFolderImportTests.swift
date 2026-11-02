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

/// Says "look up now" for the first `allowed` calls and "leave it to the
/// backfill" after, like a pacer whose rate window is full.
private actor DelayCallCounter {
    private(set) var calls = 0

    func shouldLookUpNow(allowed: Int) -> Bool {
        calls += 1
        return calls <= allowed
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
        let importer = FolderImporter(geocoder: geocoder, geocodeCache: ImportGeocodeCache(), geocodeDelay: { true })
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
        let importer = FolderImporter(geocoder: geocoder, geocodeCache: ImportGeocodeCache(), geocodeDelay: { true })
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

    func testImportNamesEveryPlaceWithoutABudget() async throws {
        let folder = try writeSixtyPlaces()
        defer { SyntheticMediaFixture.removeFolder(folder) }
        let geocoder = NamingGeocoder()
        let cache = ImportGeocodeCache()
        let importer = FolderImporter(geocoder: geocoder, geocodeCache: cache, geocodeDelay: { true })
        let container = try MomentsPersistence.makeContainer(inMemory: true)

        let started = Date()
        let summary = try await importer.importFolder(folder, container: container)
        XCTAssertEqual(summary.importedCount, 60)
        XCTAssertLessThan(Date().timeIntervalSince(started), 30)

        let afterImport = try cityNames(in: container)
        XCTAssertEqual(afterImport.count, 60)
        // No budget: every one of the sixty places is named by the import itself.
        XCTAssertEqual(afterImport.filter(\.isEmpty).count, 0, "Unnamed: \(afterImport.filter(\.isEmpty).count)")
        XCTAssertTrue(
            afterImport.allSatisfy { $0.hasPrefix("City ") },
            "Unnamed: \(afterImport.filter { !$0.hasPrefix("City ") })"
        )
        XCTAssertEqual(try retryFlagCount(in: container), 0)

        let named = try await PlaceNameBackfill(geocoder: geocoder, geocodeCache: cache, pace: {}).run(container: container)
        XCTAssertEqual(named, 0, "Nothing should be left for the backfill")
    }

    func testBackfillStopsOnFailuresAndResumesFromStoredState() async throws {
        let folder = try writeSixtyPlaces()
        defer { SyntheticMediaFixture.removeFolder(folder) }
        let geocoder = NamingGeocoder()
        // Offline during the import: the time-zone pass and the place pass each
        // stop after a few failures, so places stay unnamed.
        await geocoder.setFails(true)
        let importer = FolderImporter(geocoder: geocoder, geocodeCache: ImportGeocodeCache(), geocodeDelay: { true })
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        _ = try await importer.importFolder(folder, container: container)
        let importCalls = await geocoder.calls
        let gate = ImportGeocodeGate()
        let maxFailures = await gate.maxConsecutiveFailures
        XCTAssertLessThanOrEqual(importCalls, maxFailures + 10, "Each pass must stop after a few failures")
        let unnamed = try cityNames(in: container).filter(\.isEmpty).count
        XCTAssertEqual(unnamed, 60, "The test needs places the failed import left unnamed")

        // Offline: three failures in a row end the run, nothing is lost.
        await geocoder.setFails(true)
        let callsBefore = await geocoder.calls
        let offline = try await PlaceNameBackfill(geocoder: geocoder, geocodeCache: ImportGeocodeCache(), pace: {}).run(container: container)
        let offlineCalls = await geocoder.calls - callsBefore
        XCTAssertEqual(offline, 0)
        XCTAssertEqual(offlineCalls, 3)
        XCTAssertEqual(try cityNames(in: container).filter(\.isEmpty).count, unnamed)

        // A later run (a new launch, fresh memory) finds the same work in the store.
        await geocoder.setFails(false)
        let online = try await PlaceNameBackfill(geocoder: geocoder, geocodeCache: ImportGeocodeCache(), pace: {}).run(container: container)
        XCTAssertEqual(online, unnamed)
        XCTAssertTrue(try cityNames(in: container).allSatisfy { !$0.isEmpty })
    }

    /// Sixty far-apart places, one photo each, with an EXIF offset so no
    /// time-zone lookups come on top: every lookup here is a city lookup.
    private func writeSixtyPlacesWithOffsets() throws -> URL {
        let folder = try SyntheticMediaFixture.makeFolder()
        let start = Date(timeIntervalSince1970: 1_767_225_600)
        for index in 0..<60 {
            try SyntheticMediaFixture.writeJPEG(
                at: folder.appendingPathComponent("offset-place-\(index).jpg"),
                date: start.addingTimeInterval(Double(index) * 86_400 * 3),
                offset: "+00:00",
                latitude: Double(index) - 30,
                longitude: 20,
                marker: index
            )
        }
        return folder
    }

    /// A full rate window must end the import's lookups, not hold the import:
    /// the rest is the background backfill's work, and nothing is capped.
    func testImportLeavesPlacesToTheBackfillWhenTheRateWindowIsFull() async throws {
        let folder = try writeSixtyPlacesWithOffsets()
        defer { SyntheticMediaFixture.removeFolder(folder) }
        let geocoder = NamingGeocoder()
        let cache = ImportGeocodeCache()
        let counter = DelayCallCounter()
        let delay: @Sendable () async -> Bool = {
            await counter.shouldLookUpNow(allowed: 10)
        }
        let importer = FolderImporter(geocoder: geocoder, geocodeCache: cache, geocodeDelay: delay)
        let container = try MomentsPersistence.makeContainer(inMemory: true)

        let started = Date()
        let summary = try await importer.importFolder(folder, container: container)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(summary.importedCount, 60)
        XCTAssertLessThan(elapsed, 30, "The import must finish instead of waiting for the rate window")

        let afterImport = try cityNames(in: container)
        XCTAssertEqual(afterImport.count, 60)
        XCTAssertEqual(afterImport.filter { $0.hasPrefix("City ") }.count, 10, "Ten lookups fit the window: \(afterImport)")
        XCTAssertEqual(afterImport.filter(\.isEmpty).count, 50, "The rest waits for the backfill")
        let delayCalls = await counter.calls
        XCTAssertEqual(delayCalls, 11, "Once deferred, no later lookup may ask the closure again")

        let named = try await PlaceNameBackfill(geocoder: geocoder, geocodeCache: cache, pace: {}).run(container: container)
        XCTAssertEqual(named, 50)
        XCTAssertEqual(try cityNames(in: container).filter(\.isEmpty).count, 0, "Nothing may be capped: the backfill names every place")
    }

    /// A trip renamed while one of its cities is unnamed would keep a
    /// half-finished name forever, so the mid-run rename waits for all of them.
    func testTripWaitsForAllItsCitiesBeforeItIsRenamed() async throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let firstCity = Place(id: "trip-city-a", name: "Synthetic City A", kind: .city, latitude: 10, longitude: 20)
        let secondCity = Place(id: "trip-city-b", name: "", kind: .city, latitude: 11, longitude: 21)
        let start = Date(timeIntervalSince1970: 1_767_225_600)
        let trip = Trip(id: "trip-two-cities", name: "Trip 2026-08-20", startDate: start)
        let first = MediaItem(id: "trip-item-a", captureDate: start, place: firstCity, trip: trip)
        let second = MediaItem(id: "trip-item-b", captureDate: start.addingTimeInterval(86_400), place: secondCity, trip: trip)
        context.insert(trip)
        context.insert(firstCity)
        context.insert(secondCity)
        context.insert(first)
        context.insert(second)
        try context.save()
        let geocoder = NamingGeocoder()
        let cache = ImportGeocodeCache()

        let early = try await TripNameBackfill(geocoder: geocoder, geocodeCache: cache, pace: {})
            .run(container: container, onlyFullyNamed: true)
        XCTAssertEqual(early, 0, "One city is still unnamed")
        XCTAssertEqual(Self.tripName("trip-two-cities", in: container), "Trip 2026-08-20")

        secondCity.name = "Synthetic City B"
        try context.save()
        let late = try await TripNameBackfill(geocoder: geocoder, geocodeCache: cache, pace: {})
            .run(container: container, onlyFullyNamed: true)
        XCTAssertEqual(late, 1)
        let renamed = try XCTUnwrap(Self.tripName("trip-two-cities", in: container))
        XCTAssertTrue(renamed.contains("Synthetic City A"), renamed)
        XCTAssertTrue(renamed.contains("Synthetic City B"), renamed)
        XCTAssertNotEqual(renamed, "Trip 2026-08-20")
    }

    /// The stored name, read from a fresh context so the backfill's own
    /// context cannot leave the test looking at a stale object.
    private static func tripName(_ id: String, in container: ModelContainer) -> String? {
        let context = ModelContext(container)
        let trips = try? context.fetch(FetchDescriptor<Trip>())
        return trips?.first { $0.id == id }?.name
    }

    func testPacerStartIfRoomRefusesWithoutWaiting() async throws {
        let pacer = ImportGeocodePacer(limit: 2, window: .seconds(60), spacing: .zero)
        let first = await pacer.startIfRoom()
        let second = await pacer.startIfRoom()
        let clock = ContinuousClock()
        let started = clock.now
        let third = await pacer.startIfRoom()
        let elapsed: Duration = started.duration(to: clock.now)
        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertFalse(third, "Two calls already fill the window")
        XCTAssertLessThan(elapsed, .seconds(0.5), "A full window must refuse at once, not wait for room")
    }

    /// Forty photos in two trips ten days apart, all within one kilometre of
    /// (30, 20): the same city, looked up once.
    private func writeTwoTripsInOneCity() throws -> URL {
        let folder = try SyntheticMediaFixture.makeFolder()
        let start = Date(timeIntervalSince1970: 1_767_225_600)
        for index in 0..<40 {
            let trip = index / 20
            let position = Double(index % 20) * 0.0002
            try SyntheticMediaFixture.writeJPEG(
                at: folder.appendingPathComponent("city-\(index).jpg"),
                date: start.addingTimeInterval(Double(trip) * 10 * 86_400 + Double(index % 20) * 600),
                offset: nil,
                latitude: 30 + position,
                longitude: 20 + position,
                marker: index
            )
        }
        return folder
    }

    func testPlacesInTheSameCityAreLookedUpOnce() async throws {
        let folder = try writeTwoTripsInOneCity()
        defer { SyntheticMediaFixture.removeFolder(folder) }
        let geocoder = NamingGeocoder()
        let importer = FolderImporter(geocoder: geocoder, geocodeCache: ImportGeocodeCache(), geocodeDelay: { true })
        let container = try MomentsPersistence.makeContainer(inMemory: true)

        let summary = try await importer.importFolder(folder, container: container)
        XCTAssertEqual(summary.importedCount, 40)
        let calls = await geocoder.calls
        // One time-zone cell lookup may come on top of at most three place lookups.
        XCTAssertLessThanOrEqual(calls, 4, "Two nearby trips in one city cost \(calls) calls")

        let cities = try cityNames(in: container)
        XCTAssertFalse(cities.isEmpty, "The import must name the city it looked up")
        XCTAssertTrue(cities.allSatisfy { $0 == "City 30" }, "Names: \(cities)")
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

    func testPacerKeepsCallsUnderTheLimit() async throws {
        let pacer = ImportGeocodePacer(limit: 3, window: .milliseconds(300), spacing: .zero)
        let clock = ContinuousClock()
        let started = clock.now
        for _ in 0..<7 {
            await pacer.wait()
        }
        let elapsed: Duration = started.duration(to: clock.now)
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(550), "Seven calls at three per 300 ms need two window waits")
        XCTAssertLessThan(elapsed, .seconds(3))
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
