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

/// Names the one synthetic city it serves and puts it in a fixed zone, the way
/// a reverse lookup answers once a deferred city finally gets its name.
private struct ZoneGeocoder: ImportGeocoder {
    let zoneIdentifier: String

    func reverseGeocode(coordinate: GeoPoint) async throws -> ImportGeocodeResult {
        ImportGeocodeResult(city: "Synthetic City", area: "Synthetic Area", timeZoneIdentifier: zoneIdentifier)
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

/// Gives each hemisphere its own zone, so a test can tell which zone a photo got.
private struct HemisphereZoneGeocoder: ImportGeocoder {
    func reverseGeocode(coordinate: GeoPoint) async throws -> ImportGeocodeResult {
        let identifier: String = coordinate.latitude >= 0 ? "Asia/Shanghai" : "America/New_York"
        let index: Int = Int(coordinate.latitude.rounded())
        return ImportGeocodeResult(city: "City \(index)", area: "Area \(index)", timeZoneIdentifier: identifier)
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
        let importer = FolderImporter(geocoder: geocoder, geocodeCache: ImportGeocodeCache(), geocodeDelay: { true }, timeZoneDelay: {})
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
        let importer = FolderImporter(geocoder: geocoder, geocodeCache: ImportGeocodeCache(), geocodeDelay: { true }, timeZoneDelay: {})
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
        let importer = FolderImporter(geocoder: geocoder, geocodeCache: cache, geocodeDelay: { true }, timeZoneDelay: {})
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
        let importer = FolderImporter(geocoder: geocoder, geocodeCache: ImportGeocodeCache(), geocodeDelay: { true }, timeZoneDelay: {})
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
        let importer = FolderImporter(geocoder: geocoder, geocodeCache: cache, geocodeDelay: delay, timeZoneDelay: {})
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

    private func trips(in container: ModelContainer) throws -> [Trip] {
        try ModelContext(container).fetch(FetchDescriptor<Trip>()).sorted { $0.id < $1.id }
    }

    /// Two cities, one geocodeDelay budget: the second city is deferred. The
    /// import must not freeze "City A April 2026" as the trip's name; it uses
    /// the placeless default the backfill can still rename, and a deferred
    /// city is not a failure (no retry reason).
    func testTripAcrossTheDeferralCutGetsThePlacelessName() async throws {
        let folder = try SyntheticMediaFixture.makeFolder()
        defer { SyntheticMediaFixture.removeFolder(folder) }
        let start: Date = Date(timeIntervalSince1970: 1_767_225_600)
        // Two distant cities, well beyond the 300 km trip distance, so the two
        // stretches also form one trip only by time gap, each in its own city.
        for index in 0..<6 {
            let isSecond: Bool = index >= 3
            let latitude: Double = isSecond ? 48.0 : 31.0
            let longitude: Double = isSecond ? 2.0 : 121.0
            let offset: TimeInterval = Double(index) * 600 + (isSecond ? 86_400 : 0)
            try SyntheticMediaFixture.writeJPEG(
                at: folder.appendingPathComponent("deferral-\(index).jpg"),
                date: start.addingTimeInterval(offset),
                offset: "+00:00",
                latitude: latitude,
                longitude: longitude,
                marker: index
            )
        }
        let geocoder = NamingGeocoder()
        let cache = ImportGeocodeCache()
        let counter = DelayCallCounter()
        let delay: @Sendable () async -> Bool = {
            await counter.shouldLookUpNow(allowed: 1)
        }
        let importer = FolderImporter(
            geocoder: geocoder,
            geocodeCache: cache,
            geocodeDelay: delay,
            timeZoneDelay: {}
        )
        let container = try MomentsPersistence.makeContainer(inMemory: true)

        let summary = try await importer.importFolder(folder, container: container)
        XCTAssertEqual(summary.importedCount, 6)
        XCTAssertEqual(summary.tripCount, 1)
        let importedTrips = try trips(in: container)
        XCTAssertEqual(importedTrips.count, 1)
        let importedName: String = try XCTUnwrap(importedTrips.first?.name)
        XCTAssertTrue(TripNaming.isPlacelessDefaultName(importedName), "Half-named: \(importedName)")
        XCTAssertFalse(importedName.contains("City "), "No city may be frozen into the name: \(importedName)")
        XCTAssertEqual(try retryFlagCount(in: container), 0, "Deferred is not failed")

        _ = try await PlaceNameBackfill(geocoder: geocoder, geocodeCache: cache, pace: {}).run(container: container)
        let namedCities: [String] = try cityNames(in: container)
        XCTAssertEqual(namedCities.filter(\.isEmpty).count, 0, "Backfill names every city: \(namedCities)")
        _ = try await TripNameBackfill(geocoder: geocoder, geocodeCache: cache, pace: {}).run(container: container)
        let renamed: String = try XCTUnwrap(Self.tripName(try XCTUnwrap(importedTrips.first?.id), in: container))
        XCTAssertTrue(renamed.contains("City 31"), renamed)
        XCTAssertTrue(renamed.contains("City 48"), renamed)
    }

    /// A wrong zone moves the capture date by hours, so the time-zone pass waits
    /// for the pacer even when the place pass is deferred.
    func testTimeZonePassIsNeverDeferred() async throws {
        let folder = try SyntheticMediaFixture.makeFolder()
        defer { SyntheticMediaFixture.removeFolder(folder) }
        let start: Date = Date(timeIntervalSince1970: 1_767_225_600)
        // Offset-less EXIF times at two distant coordinates: two half-degree cells.
        try SyntheticMediaFixture.writeJPEG(
            at: folder.appendingPathComponent("north.jpg"),
            date: start,
            offset: nil,
            latitude: 31.2,
            longitude: 121.5,
            marker: 1
        )
        try SyntheticMediaFixture.writeJPEG(
            at: folder.appendingPathComponent("south.jpg"),
            date: start.addingTimeInterval(86_400),
            offset: nil,
            latitude: -33.9,
            longitude: 151.2,
            marker: 2
        )
        let geocoder = HemisphereZoneGeocoder()
        // The place pass is out of room from the first call; the time-zone pass
        // must not care.
        let importer = FolderImporter(
            geocoder: geocoder,
            geocodeCache: ImportGeocodeCache(),
            geocodeDelay: { false },
            timeZoneDelay: {}
        )
        let container = try MomentsPersistence.makeContainer(inMemory: true)

        _ = try await importer.importFolder(folder, container: container)
        let items = try ModelContext(container).fetch(FetchDescriptor<MediaItem>()).sorted { $0.title < $1.title }
        XCTAssertEqual(items.map(\.timeConfidence), [.exact, .exact])
        XCTAssertEqual(items.map(\.timeZoneIdentifier), ["Asia/Shanghai", "America/New_York"])
        XCTAssertTrue(items.allSatisfy { $0.localDayKey != nil })
    }

    /// A photo whose zone the import could only guess because its city was still
    /// unnamed gets zone, day key and confidence repaired once the name arrives.
    /// A folder photo whose EXIF wall-clock time was read in the wrong zone also
    /// gets its capture date resolved again in the right one.
    func testBackfillRepairsAZoneLeftUnknown() async throws {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let deviceZone: TimeZone = .autoupdatingCurrent
        var deviceCalendar: Calendar = Calendar(identifier: .gregorian)
        deviceCalendar.timeZone = deviceZone
        // 18:00 on the device clock: ten hours away is the next day, so the day
        // key of an absolute date must change wherever this test runs.
        let date: Date = try XCTUnwrap(deviceCalendar.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: 18)))
        let deviceDayKey: String = UserGroupRuleSet.localDayKey(for: date, calendar: deviceCalendar)
        let deviceOffsetSeconds: Int = deviceZone.secondsFromGMT(for: date)
        let tenHoursAway: TimeZone = try XCTUnwrap(TimeZone(secondsFromGMT: deviceOffsetSeconds + 10 * 3_600))
        var awayCalendar: Calendar = Calendar(identifier: .gregorian)
        awayCalendar.timeZone = tenHoursAway
        let awayDayKey: String = UserGroupRuleSet.localDayKey(for: date, calendar: awayCalendar)
        XCTAssertNotEqual(awayDayKey, deviceDayKey, "The test needs a zone that crosses the day")

        let city = Place(id: "unknown-zone-city", name: "", kind: .city, latitude: 35.0, longitude: 139.0)
        // An Apple Photos asset: an absolute date and no wall-clock reading.
        let absolute = MediaItem(
            id: "unknown-zone-absolute",
            captureDate: date,
            place: city,
            localDayKey: deviceDayKey,
            timeZoneIdentifier: deviceZone.identifier,
            timeConfidenceRaw: ImportTimeConfidence.zoneUnknown.rawValue
        )
        // A folder photo whose EXIF wall-clock time was read in the wrong zone.
        let wallClock = MediaItem(
            id: "unknown-zone-wallclock",
            captureDate: date,
            place: city,
            localDayKey: deviceDayKey,
            captureDateHintUTC: date,
            timeZoneIdentifier: deviceZone.identifier,
            timeConfidenceRaw: ImportTimeConfidence.zoneUnknown.rawValue
        )
        context.insert(city)
        context.insert(absolute)
        context.insert(wallClock)
        try context.save()

        let geocoder = ZoneGeocoder(zoneIdentifier: tenHoursAway.identifier)
        let cache = ImportGeocodeCache()
        let named: Int = try await PlaceNameBackfill(geocoder: geocoder, geocodeCache: cache, pace: {}).run(container: container)
        XCTAssertEqual(named, 1)

        let repaired = try ModelContext(container).fetch(FetchDescriptor<MediaItem>())
        let repairedAbsolute = try XCTUnwrap(repaired.first { $0.id == "unknown-zone-absolute" })
        XCTAssertEqual(repairedAbsolute.timeZoneIdentifier, tenHoursAway.identifier)
        XCTAssertEqual(repairedAbsolute.timeConfidence, .exact)
        XCTAssertEqual(repairedAbsolute.localDayKey, awayDayKey, "The day key must follow the new zone")
        XCTAssertEqual(repairedAbsolute.captureDate, date, "An absolute date does not move")

        let repairedWallClock = try XCTUnwrap(repaired.first { $0.id == "unknown-zone-wallclock" })
        let expectedDate: Date = ImportOrganizer.resolveWallClockDate(date, in: tenHoursAway)
        let expectedDayKey: String = UserGroupRuleSet.localDayKey(for: expectedDate, calendar: awayCalendar)
        XCTAssertEqual(repairedWallClock.timeZoneIdentifier, tenHoursAway.identifier)
        XCTAssertEqual(repairedWallClock.timeConfidence, .exact)
        XCTAssertEqual(repairedWallClock.captureDate, expectedDate, "The wall-clock time is read in the new zone")
        XCTAssertNotEqual(repairedWallClock.captureDate, date)
        XCTAssertEqual(repairedWallClock.localDayKey, expectedDayKey, "The day key follows the resolved date")
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
        let importer = FolderImporter(geocoder: geocoder, geocodeCache: ImportGeocodeCache(), geocodeDelay: { true }, timeZoneDelay: {})
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
