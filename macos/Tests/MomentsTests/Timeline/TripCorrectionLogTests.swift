import Foundation
import MomentsCore
import SwiftData
import XCTest
@testable import Moments

/// The local correction log: one line per hand change, written off the main
/// thread through the actor, with a snapshot of the trips or chapters it
/// touched. Synthetic data only, in memory, with a temporary file.
@MainActor
final class TripCorrectionLogTests: XCTestCase {
    private var container: ModelContainer?
    private var defaults: UserDefaults!
    private var suiteName = ""
    private var logURL: URL!

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Midday UTC on 2026-08-`day`.
    private func day(_ day: Int, hour: Int = 12) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 8, day: day, hour: hour))!
    }

    /// A day in the Mac's own calendar, for the snapshot built with `.current`.
    private func localDay(_ day: Int, hour: Int = 12) -> Date {
        let parts = DateComponents(year: 2026, month: 8, day: day, hour: hour)
        return Calendar.current.date(from: parts)!
    }

    override func setUp() {
        super.setUp()
        suiteName = "TripCorrectionLogTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        logURL = FileManager.default.temporaryDirectory
            .appending(path: "trip-corrections-\(UUID().uuidString).jsonl")
        TripCorrectionRecorder.log = TripCorrectionLog(fileURL: logURL)
        TripCorrectionRecorder.defaults = defaults
        // No real geocoding folder is read: synthetic countries only.
        TripCorrectionRecorder.countryLookup = { (_: GeoPoint) -> String? in "Portugal" }
    }

    override func tearDown() {
        TripCorrectionRecorder.log = .shared
        TripCorrectionRecorder.defaults = .standard
        TripCorrectionRecorder.countryLookup = { (coordinate: GeoPoint) -> String? in
            FootprintsGeocodeCache().result(for: coordinate)?.countryName
        }
        container = nil
        defaults.removePersistentDomain(forName: suiteName)
        if let logURL {
            try? FileManager.default.removeItem(at: logURL)
        }
        super.tearDown()
    }

    // MARK: Fixtures

    private func makeContext() throws -> ModelContext {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        self.container = container
        return container.mainContext
    }

    @discardableResult
    private func photo(_ id: String, on date: Date?, trip: Trip?, in context: ModelContext) -> MediaItem {
        let item = MediaItem(id: id, captureDate: date, title: id, tripID: trip?.id, trip: trip)
        context.insert(item)
        return item
    }

    private func session(_ context: ModelContext) -> TripEdits.Session {
        TripEdits.Session(context: context, calendar: utc, defaults: defaults)
    }

    /// Every entry written so far, oldest first.
    private func entries() throws -> [TripCorrectionLog.Entry] {
        guard FileManager.default.fileExists(atPath: logURL.path) else { return [] }
        let data: Data = try Data(contentsOf: logURL)
        let text: String = String(decoding: data, as: UTF8.self)
        let decoder = JSONDecoder()
        var result: [TripCorrectionLog.Entry] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let row: Data = Data(line.utf8)
            let entry: TripCorrectionLog.Entry = try decoder.decode(TripCorrectionLog.Entry.self, from: row)
            result.append(entry)
        }
        return result
    }

    // MARK: Actions write one entry each

    func testSplitWritesOneEntryWithBothTrips() async throws {
        let context = try makeContext()
        let trip = Trip(id: "t", name: "Trip", startDate: day(10, hour: 0), endDate: day(12, hour: 23))
        context.insert(trip)
        photo("a", on: day(10), trip: trip, in: context)
        photo("b", on: day(12), trip: trip, in: context)
        try context.save()

        let split = session(context)
        let part: Trip? = TripEdits.split(trip, at: "2026-08-12", session: split)
        XCTAssertNotNil(part)
        await TripCorrectionRecorder.flush()

        let written: [TripCorrectionLog.Entry] = try entries()
        XCTAssertEqual(written.count, 1)
        let entry: TripCorrectionLog.Entry = try XCTUnwrap(written.first)
        XCTAssertEqual(entry.action, .split)
        XCTAssertEqual(entry.version, 1)
        XCTAssertEqual(entry.rulesVersion, 4)
        XCTAssertEqual(entry.before.count, 1)
        XCTAssertEqual(entry.after.count, 2)
        XCTAssertEqual(entry.before.first?.id, "t")
        XCTAssertEqual(entry.before.first?.photoCount, 2)
        XCTAssertEqual(entry.after.first?.photoCount, 1)
        XCTAssertEqual(entry.movedPhotoIDs, ["b"])
    }

    func testMergeWritesOneEntry() async throws {
        let context = try makeContext()
        let trip = Trip(id: "t", name: "Trip", startDate: day(10), endDate: day(11))
        let other = Trip(id: "o", name: "Other", startDate: day(12), endDate: day(13))
        context.insert(trip)
        context.insert(other)
        photo("a", on: day(10), trip: trip, in: context)
        photo("b", on: day(12), trip: other, in: context)
        try context.save()

        TripEdits.merge(other, into: trip, session: session(context))
        await TripCorrectionRecorder.flush()

        let written: [TripCorrectionLog.Entry] = try entries()
        XCTAssertEqual(written.count, 1)
        let entry: TripCorrectionLog.Entry = try XCTUnwrap(written.first)
        XCTAssertEqual(entry.action, .merge)
        XCTAssertEqual(entry.before.count, 2)
        XCTAssertEqual(entry.after.count, 1)
        XCTAssertEqual(entry.after.first?.photoCount, 2)
        XCTAssertEqual(entry.movedPhotoIDs, ["b"])
    }

    func testDeleteWritesOneEntryWithNothingAfter() async throws {
        let context = try makeContext()
        let trip = Trip(id: "t", name: "Trip", startDate: day(10), endDate: day(11))
        context.insert(trip)
        photo("a", on: day(10), trip: trip, in: context)
        try context.save()

        TripEdits.delete(trip, session: session(context))
        await TripCorrectionRecorder.flush()

        let written: [TripCorrectionLog.Entry] = try entries()
        XCTAssertEqual(written.count, 1)
        let entry: TripCorrectionLog.Entry = try XCTUnwrap(written.first)
        XCTAssertEqual(entry.action, .delete)
        XCTAssertEqual(entry.before.count, 1)
        XCTAssertTrue(entry.after.isEmpty)
        XCTAssertEqual(entry.movedPhotoIDs, ["a"])
    }

    func testRenameWritesOneEntryWithBothNames() async throws {
        let context = try makeContext()
        let trip = Trip(id: "t", name: "Trip 2026-08-10", startDate: day(10), endDate: day(11))
        context.insert(trip)
        try context.save()

        TripRenaming.rename(trip, to: "Lisbon", context: context)
        await TripCorrectionRecorder.flush()

        let written: [TripCorrectionLog.Entry] = try entries()
        XCTAssertEqual(written.count, 1)
        let entry: TripCorrectionLog.Entry = try XCTUnwrap(written.first)
        XCTAssertEqual(entry.action, .rename)
        XCTAssertEqual(entry.before.first?.name, "Trip 2026-08-10")
        XCTAssertEqual(entry.before.first?.overrideName, nil)
        XCTAssertEqual(entry.after.first?.name, "Lisbon")
        XCTAssertEqual(entry.after.first?.overrideName, "Lisbon")
    }

    func testCreateWritesASingleEntry() async throws {
        let context = try makeContext()
        photo("a", on: day(10), trip: nil, in: context)
        try context.save()

        let created: (trip: Trip, outcome: TripEdits.DatesOutcome) = TripEdits.create(
            named: "Lisbon",
            start: day(10),
            end: day(11),
            session: session(context)
        )
        XCTAssertEqual(created.outcome.joined, 1)
        await TripCorrectionRecorder.flush()

        let written: [TripCorrectionLog.Entry] = try entries()
        XCTAssertEqual(written.count, 1, "A new trip's dates are part of create, not a second entry")
        let entry: TripCorrectionLog.Entry = try XCTUnwrap(written.first)
        XCTAssertEqual(entry.action, .create)
        XCTAssertTrue(entry.before.isEmpty)
        XCTAssertEqual(entry.after.first?.photoCount, 1)
    }

    func testEveryDayOfTheTripHasARowWithItsCounts() async throws {
        let context = try makeContext()
        let city = Place(id: "city", name: "Lisbon", kind: .city, latitude: 38.72, longitude: -9.14)
        context.insert(city)
        let trip = Trip(id: "t", name: "Trip", startDate: localDay(10, hour: 0), endDate: localDay(12, hour: 23))
        context.insert(trip)
        photo("a", on: localDay(10, hour: 9), trip: trip, in: context).place = city
        let shot = photo("shot", on: localDay(11, hour: 9), trip: trip, in: context)
        shot.isScreenshot = true
        let video = photo("clip", on: localDay(12, hour: 9), trip: trip, in: context)
        video.kind = .video
        let empty = photo("outside", on: localDay(20), trip: nil, in: context)
        empty.place = city
        try context.save()

        TripRenaming.rename(trip, to: "Lisbon", context: context)
        await TripCorrectionRecorder.flush()

        let entry: TripCorrectionLog.Entry = try XCTUnwrap(try entries().first)
        let snapshot: TripCorrectionSnapshot = try XCTUnwrap(entry.after.first)
        XCTAssertEqual(snapshot.days.count, 3, "Every day from start to end has a row")
        XCTAssertEqual(snapshot.days.map(\.date), ["2026-08-10", "2026-08-11", "2026-08-12"])
        XCTAssertEqual(snapshot.days.map(\.weekday), ["Monday", "Tuesday", "Wednesday"])
        XCTAssertEqual(snapshot.days.map(\.photos), [1, 1, 1])
        XCTAssertEqual(snapshot.days.map(\.located), [1, 0, 0])
        XCTAssertEqual(snapshot.days.map(\.screenshots), [0, 1, 0])
        XCTAssertEqual(snapshot.days.first?.city, "Lisbon")
        XCTAssertEqual(snapshot.photoCount, 3)
        XCTAssertEqual(snapshot.videoCount, 1)
        XCTAssertEqual(snapshot.cities, ["Lisbon"])
        XCTAssertEqual(snapshot.countries, ["Portugal"])
        XCTAssertEqual(snapshot.dayCount, 3)
        XCTAssertEqual(snapshot.photoDayShare, 1)
        XCTAssertEqual(snapshot.medianPhotosPerPhotoDay, 1)
    }

    func testUndoWritesAnEntryPointingAtTheOneItReverses() async throws {
        let context = try makeContext()
        let trip = Trip(id: "t", name: "Trip", startDate: day(10, hour: 0), endDate: day(12, hour: 23))
        context.insert(trip)
        photo("a", on: day(10), trip: trip, in: context)
        photo("b", on: day(12), trip: trip, in: context)
        try context.save()

        let split = session(context)
        TripEdits.split(trip, at: "2026-08-12", session: split)
        await TripCorrectionRecorder.flush()
        let original: TripCorrectionLog.Entry = try XCTUnwrap(try entries().first)

        TripEdits.undo(split.undo, context: context, defaults: defaults)
        await TripCorrectionRecorder.flush()

        let written: [TripCorrectionLog.Entry] = try entries()
        XCTAssertEqual(written.count, 2)
        let undo: TripCorrectionLog.Entry = try XCTUnwrap(written.last)
        XCTAssertEqual(undo.action, .undo)
        XCTAssertEqual(undo.reverses, original.id)
    }

    func testAutomaticRegroupingWritesNothing() async throws {
        let context = try makeContext()
        let trip = Trip(id: "t", name: "", suggestionStatusRaw: "suggestion")
        context.insert(trip)
        photo("a", on: day(10), trip: trip, in: context)
        try context.save()

        _ = try TripRegrouping.regroup(
            context: context,
            locked: [],
            configuration: ImportConfiguration(),
            calendar: utc
        )
        await TripCorrectionRecorder.flush()

        XCTAssertTrue(try entries().isEmpty, "Only hand edits count")
    }

    func testFileRoundTripsThroughJSONDecoder() async throws {
        let entry = TripCorrectionLog.Entry(
            at: "2026-08-12T10:00:00+02:00",
            editor: "maple",
            appVersion: "1.0",
            rulesVersion: 4,
            action: .changeDates,
            before: [],
            after: [],
            movedPhotoIDs: ["a"],
            note: "note"
        )
        await TripCorrectionRecorder.log.append(entry)
        let written: [TripCorrectionLog.Entry] = try entries()
        XCTAssertEqual(written, [entry])
    }
}
