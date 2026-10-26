import Foundation
import SwiftData
import XCTest
@testable import Moments

@MainActor
final class TripEditsTests: XCTestCase {
    private var container: ModelContainer?
    private var defaults: UserDefaults!
    private var suiteName = ""

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Midday UTC on 2026-08-`day`.
    private func day(_ day: Int, hour: Int = 12) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 8, day: day, hour: hour))!
    }

    override func setUp() {
        super.setUp()
        suiteName = "TripEditsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        container = nil
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

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

    private func session(_ context: ModelContext, continuing undo: TripEdits.Undo = TripEdits.Undo()) -> TripEdits.Session {
        TripEdits.Session(context: context, calendar: utc, defaults: defaults, continuing: undo)
    }

    private func tripID(of id: String, in context: ModelContext) throws -> String? {
        try context.fetch(FetchDescriptor<MediaItem>()).first { $0.id == id }?.tripID
    }

    private func relatedTripID(of id: String, in context: ModelContext) throws -> String? {
        try context.fetch(FetchDescriptor<MediaItem>()).first { $0.id == id }?.trip?.id
    }

    // MARK: Plan

    func testPlanJoinsFreePhotosLeavesOutsideOnesAndOffersOtherTrips() {
        let plan = TripEdits.plan(tripID: "t", first: "2026-08-10", last: "2026-08-12", members: [
            .init(id: "in-free", dayKey: "2026-08-11", tripID: nil, isLocked: false),
            .init(id: "in-mine", dayKey: "2026-08-10", tripID: "t", isLocked: false),
            .init(id: "out-mine", dayKey: "2026-08-13", tripID: "t", isLocked: false),
            .init(id: "in-other", dayKey: "2026-08-12", tripID: "o", isLocked: false),
            .init(id: "locked-out", dayKey: "2026-08-20", tripID: "t", isLocked: true),
            .init(id: "locked-free", dayKey: "2026-08-11", tripID: nil, isLocked: true),
            .init(id: "undated", dayKey: nil, tripID: "t", isLocked: false),
        ])
        XCTAssertEqual(plan.joining, ["in-free"])
        XCTAssertEqual(plan.leaving, ["out-mine"])
        XCTAssertEqual(plan.elsewhere, ["o": ["in-other"]])
    }

    /// Days follow the photo's own local day, not the Mac's time zone.
    func testDaysFollowThePhotosLocalDay() throws {
        let context = try makeContext()
        let trip = Trip(id: "t", name: "t", startDate: day(10, hour: 0), endDate: day(11, hour: 23))
        context.insert(trip)
        let late = photo("late", on: day(11, hour: 23), trip: trip, in: context)
        late.localDayKey = "2026-08-12"
        photo("a", on: day(10), trip: trip, in: context)
        try context.save()

        TripEdits.removeDay("2026-08-12", from: trip, session: session(context))
        XCTAssertNil(try tripID(of: "late", in: context))
        XCTAssertEqual(try tripID(of: "a", in: context), "t")
    }

    func testPhotosOfAVanishedTripCountAsFree() throws {
        let context = try makeContext()
        let trip = Trip(id: "t", name: "t", startDate: day(10), endDate: day(10))
        context.insert(trip)
        let stray = photo("stray", on: day(11), trip: nil, in: context)
        stray.tripID = "gone"
        try context.save()
        let outcome = TripEdits.changeDates(of: trip, start: day(10), end: day(11), session: session(context), locked: [])
        XCTAssertEqual(outcome.joined, 1)
        XCTAssertTrue(outcome.elsewhere.isEmpty)
    }

    // MARK: Dates

    func testChangingDatesResortsPhotosAndUndoPutsEverythingBack() throws {
        let context = try makeContext()
        let trip = Trip(id: "t", name: "Trip 2026-08-10", startDate: day(10, hour: 0), endDate: day(11, hour: 23))
        let other = Trip(id: "o", name: "Other", startDate: day(13), endDate: day(14))
        context.insert(trip)
        context.insert(other)
        photo("a", on: day(10), trip: trip, in: context)
        photo("b", on: day(11), trip: trip, in: context)
        photo("free", on: day(12), trip: nil, in: context)
        photo("theirs", on: day(13), trip: other, in: context)
        photo("far", on: day(20), trip: nil, in: context)
        try context.save()

        let outcome = TripEdits.changeDates(of: trip, start: day(11), end: day(13), session: session(context), locked: [])
        XCTAssertEqual(outcome.joined, 1)
        XCTAssertEqual(outcome.left, 1)
        XCTAssertEqual(outcome.elsewhere.map(\.tripID), ["o"])
        XCTAssertNil(try tripID(of: "a", in: context))
        XCTAssertEqual(try tripID(of: "free", in: context), "t")
        XCTAssertEqual(try tripID(of: "theirs", in: context), "o", "Another trip's photos stay until asked")
        XCTAssertNil(try tripID(of: "far", in: context))
        XCTAssertEqual(trip.startDate, day(11, hour: 0))

        // "Move them here", then one Undo for both.
        let adopting = session(context, continuing: outcome.undo)
        TripEdits.add(outcome.elsewhere.flatMap(\.itemIDs), to: trip, session: adopting)
        XCTAssertEqual(try tripID(of: "theirs", in: context), "t")

        TripEdits.undo(adopting.undo, context: context, defaults: defaults)
        XCTAssertEqual(try tripID(of: "a", in: context), "t")
        XCTAssertNil(try tripID(of: "free", in: context))
        XCTAssertEqual(try tripID(of: "theirs", in: context), "o")
        XCTAssertEqual(trip.startDate, day(10, hour: 0))
        XCTAssertEqual(trip.name, "Trip 2026-08-10")
        XCTAssertFalse(TripAssignmentLocks.isLocked("theirs", defaults: defaults), "Undo also forgets the lock it added")
    }

    func testLockedPhotosNeverMoveWithTheDates() throws {
        let context = try makeContext()
        let trip = Trip(id: "t", name: "t", startDate: day(10), endDate: day(11))
        context.insert(trip)
        photo("placed", on: day(10), trip: trip, in: context)
        photo("kept-out", on: day(11), trip: nil, in: context)
        try context.save()

        _ = TripEdits.changeDates(of: trip, start: day(11), end: day(12), session: session(context), locked: ["placed", "kept-out"])
        XCTAssertEqual(try tripID(of: "placed", in: context), "t")
        XCTAssertNil(try tripID(of: "kept-out", in: context))
    }

    func testATypedNameStaysWhenTheDatesChange() throws {
        let context = try makeContext()
        let trip = Trip(id: "t", name: "auto", startDate: day(10), endDate: day(11), overrideName: "Our honeymoon")
        context.insert(trip)
        photo("a", on: day(10), trip: trip, in: context)
        try context.save()
        _ = TripEdits.changeDates(of: trip, start: day(9), end: day(11), session: session(context), locked: [])
        XCTAssertEqual(trip.effectiveName, "Our honeymoon")
    }

    // MARK: By hand

    func testSplitStartsANewTripAndUndoRemovesIt() throws {
        let context = try makeContext()
        let trip = Trip(id: "t", name: "t", startDate: day(10, hour: 0), endDate: day(13, hour: 23))
        context.insert(trip)
        for (index, date) in [day(10), day(11), day(12), day(13)].enumerated() {
            photo("p\(index)", on: date, trip: trip, in: context)
        }
        try context.save()

        let edit = session(context)
        let part = try XCTUnwrap(TripEdits.split(trip, at: "2026-08-12", session: edit))
        XCTAssertEqual(try tripID(of: "p1", in: context), "t")
        XCTAssertEqual(try tripID(of: "p2", in: context), part.id)
        XCTAssertEqual(try tripID(of: "p3", in: context), part.id)
        XCTAssertEqual(trip.endDate, TripEdits.endOfDay(day(11), calendar: utc))
        XCTAssertEqual(part.startDate, day(12, hour: 0))

        TripEdits.undo(edit.undo, context: context, defaults: defaults)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Trip>()).map(\.id), ["t"])
        XCTAssertEqual(try tripID(of: "p3", in: context), "t")
        XCTAssertEqual(try relatedTripID(of: "p3", in: context), "t", "The photo's trip relationship came back too")
        XCTAssertEqual(trip.endDate, day(13, hour: 23))
    }

    func testSplitOnTheFirstDayDoesNothing() throws {
        let context = try makeContext()
        let trip = Trip(id: "t", name: "t")
        context.insert(trip)
        photo("a", on: day(10), trip: trip, in: context)
        photo("b", on: day(11), trip: trip, in: context)
        try context.save()
        XCTAssertNil(TripEdits.split(trip, at: "2026-08-10", session: session(context)))
    }

    func testMergeMovesPhotosAndMemoriesAndUndoBringsTheTripBack() throws {
        let context = try makeContext()
        let trip = Trip(id: "t", name: "t", startDate: day(10), endDate: day(11))
        let other = Trip(id: "o", name: "Other", startDate: day(14), endDate: day(15), overrideName: "Lisbon")
        context.insert(trip)
        context.insert(other)
        photo("a", on: day(10), trip: trip, in: context)
        photo("b", on: day(15), trip: other, in: context)
        let memory = CollectionMemory(scope: .trip, scopeKey: "o", text: "Tram 28")
        context.insert(memory)
        try context.save()

        let edit = session(context)
        TripEdits.merge(other, into: trip, session: edit)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Trip>()).map(\.id), ["t"])
        XCTAssertEqual(try tripID(of: "b", in: context), "t")
        XCTAssertEqual(try relatedTripID(of: "b", in: context), "t", "Deleting the merged trip kept the photo's new trip")
        XCTAssertEqual(memory.scopeKey, "t")
        XCTAssertEqual(trip.endDate, day(15))

        TripEdits.undo(edit.undo, context: context, defaults: defaults)
        let restored = try XCTUnwrap(try context.fetch(FetchDescriptor<Trip>()).first { $0.id == "o" })
        XCTAssertEqual(restored.effectiveName, "Lisbon")
        XCTAssertEqual(try tripID(of: "b", in: context), "o")
        XCTAssertEqual(memory.scopeKey, "o")
        XCTAssertEqual(trip.endDate, day(11))
    }

    func testRemovingTheLastDayShrinksTheTripAndLocksItsPhotos() throws {
        let context = try makeContext()
        let trip = Trip(id: "t", name: "t", startDate: day(10, hour: 0), endDate: day(12, hour: 23))
        context.insert(trip)
        photo("a", on: day(10), trip: trip, in: context)
        photo("b", on: day(11), trip: trip, in: context)
        photo("c", on: day(12), trip: trip, in: context)
        try context.save()

        TripEdits.removeDay("2026-08-12", from: trip, session: session(context))
        XCTAssertNil(try tripID(of: "c", in: context))
        XCTAssertEqual(trip.endDate, TripEdits.endOfDay(day(11), calendar: utc))
        XCTAssertTrue(TripAssignmentLocks.isLocked("c", defaults: defaults), "A day taken out by hand stays out")
    }

    func testAddingADayStretchesTheDates() throws {
        let context = try makeContext()
        let trip = Trip(id: "t", name: "t", startDate: day(10, hour: 0), endDate: day(11, hour: 23))
        context.insert(trip)
        photo("a", on: day(10), trip: trip, in: context)
        photo("before", on: day(8), trip: nil, in: context)
        try context.save()

        TripEdits.add(["before"], to: trip, session: session(context))
        XCTAssertEqual(try tripID(of: "before", in: context), "t")
        XCTAssertEqual(trip.startDate, day(8, hour: 0))
    }

    func testCreatingATripGathersFreePhotosAndUndoRemovesIt() throws {
        let context = try makeContext()
        let other = Trip(id: "o", name: "Other", startDate: day(12), endDate: day(12))
        context.insert(other)
        photo("free", on: day(11), trip: nil, in: context)
        photo("theirs", on: day(12), trip: other, in: context)
        photo("far", on: day(20), trip: nil, in: context)
        try context.save()

        let edit = session(context)
        let created = TripEdits.create(named: "  Weekend  ", start: day(11), end: day(12), session: edit, locked: [])
        XCTAssertEqual(created.trip.effectiveName, "Weekend")
        XCTAssertEqual(try tripID(of: "free", in: context), created.trip.id)
        XCTAssertEqual(try tripID(of: "theirs", in: context), "o")
        XCTAssertEqual(created.outcome.elsewhere.map(\.tripID), ["o"])

        TripEdits.undo(edit.undo, context: context, defaults: defaults)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Trip>()).map(\.id), ["o"])
        XCTAssertNil(try tripID(of: "free", in: context))
    }

    func testWorldOutlineShipsWithTheApp() {
        let outline = WorldOutline.shared
        XCTAssertGreaterThan(outline.rings.count, 100, "The base map file is missing from the app bundle")
        let morocco = outline.rings(longitudes: -8 ... -4, latitudes: 31...34)
        XCTAssertFalse(morocco.isEmpty)
        for ring in outline.rings {
            for (previous, next) in zip(ring.points, ring.points.dropFirst()) {
                XCTAssertLessThanOrEqual(abs(next.x - previous.x), 180, "A ring jumps across the 180° meridian")
            }
        }
        // Northern Iceland must not catch a band of Russia's far east.
        let iceland = outline.rings(longitudes: -20 ... -16, latitudes: 64...67)
        XCTAssertFalse(iceland.contains { $0.maxLongitude - $0.minLongitude > 300 })
        XCTAssertFalse(outline.rings(longitudes: -179 ... -172, latitudes: 64...70).isEmpty, "Chukotka still shows west of the line")
    }

    // MARK: Chapters that are not trips

    func testAChapterSharesPhotosWithATripAndKeepsHandRemovalsOut() throws {
        let context = try makeContext()
        let trip = Trip(id: "t", name: "t", startDate: day(10), endDate: day(14))
        context.insert(trip)
        photo("a", on: day(11), trip: trip, in: context)
        photo("b", on: day(12), trip: trip, in: context)
        photo("c", on: day(13), trip: nil, in: context)
        try context.save()

        let edit = session(context)
        let birthday = TripEdits.createChapter(named: "Birthday", type: .celebration, symbol: nil, start: day(11), end: day(12), session: edit)
        XCTAssertTrue(birthday.isChapter)
        XCTAssertEqual(birthday.chapterType, .celebration)
        XCTAssertEqual(TripEdits.memberIDs(of: birthday, context: context), ["a", "b"])
        XCTAssertEqual(try tripID(of: "a", in: context), "t", "The photo stays in its trip too")

        TripEdits.removeDay(PhotoNoteDay.key(for: day(12)), from: birthday, session: session(context))
        XCTAssertEqual(TripEdits.memberIDs(of: birthday, context: context), ["a"])
        let widened = TripEdits.changeDates(of: birthday, start: day(11), end: day(13), session: session(context))
        XCTAssertEqual(widened.joined, 1)
        XCTAssertEqual(TripEdits.memberIDs(of: birthday, context: context), ["a", "c"], "A day taken out by hand stays out")

        TripEdits.undo(edit.undo, context: context, defaults: defaults)
        XCTAssertTrue(try context.fetch(FetchDescriptor<UserGroup>()).filter(\.isChapter).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<UserGroupItem>()).isEmpty, "No rows left for a chapter that is gone")
    }

    func testDeletingAChapterCanBeUndone() throws {
        let context = try makeContext()
        photo("a", on: day(11), trip: nil, in: context)
        try context.save()
        let group = TripEdits.createChapter(named: "", type: .custom("Moving house"), symbol: "house", start: day(10), end: day(12), session: session(context))
        XCTAssertTrue(group.name.hasPrefix("Moving house"))
        XCTAssertEqual(group.chapterSymbol, "house")
        let groupID = group.id

        let edit = session(context)
        TripEdits.delete(group, session: edit)
        XCTAssertTrue(try context.fetch(FetchDescriptor<UserGroup>()).isEmpty)
        TripEdits.undo(edit.undo, context: context, defaults: defaults)
        let restored = try XCTUnwrap(try context.fetch(FetchDescriptor<UserGroup>()).first { $0.id == groupID })
        XCTAssertEqual(restored.chapterType, .custom("Moving house"))
        XCTAssertEqual(TripEdits.memberIDs(of: restored, context: context), ["a"])
    }

    func testChapterKindsRoundTrip() {
        for type in ChapterType.presets + [.custom("Exams")] {
            XCTAssertEqual(ChapterType(raw: type.raw), type)
        }
        let info = ChapterInfo(type: "event", symbol: "star", startDate: day(1), endDate: day(2))
        XCTAssertEqual(ChapterInfo.decode(info.encoded()), info)
        XCTAssertNil(ChapterInfo.decode(Data("{\"mode\":\"all\",\"rules\":[]}".utf8)), "Smart-group rules are never read as a chapter")
    }

    // MARK: Route map

    func testRouteMapKeepsStopsInsideTheBoxAndInOrder() {
        let stops = [
            TripRouteStop(name: "Lisbon", latitude: 38.72, longitude: -9.14),
            TripRouteStop(name: "Porto", latitude: 41.15, longitude: -8.61),
            TripRouteStop(name: "Madrid", latitude: 40.42, longitude: -3.70),
        ]
        let box = CGRect(x: 20, y: 20, width: 160, height: 100)
        let points = TripRouteMap.layout(stops, in: box)
        XCTAssertEqual(points.count, 3)
        for point in points {
            XCTAssertTrue(box.insetBy(dx: -0.5, dy: -0.5).contains(point), "\(point) is outside \(box)")
        }
        XCTAssertLessThan(points[1].y, points[0].y, "North is up")
        XCTAssertGreaterThan(points[2].x, points[1].x, "East is right")
        let single = TripRouteMap.layout([stops[0]], in: box)
        XCTAssertEqual(single.count, 1)
        XCTAssertEqual(single[0].x, box.midX, accuracy: 0.01)
        XCTAssertEqual(single[0].y, box.midY, accuracy: 0.01)
        XCTAssertNotNil(TripRouteMap.projection(stops, in: box), "Cities apart get a base map")
        let nearby = [TripRouteStop(name: "A", latitude: 31.2, longitude: 121.4), TripRouteStop(name: "B", latitude: 31.25, longitude: 121.5)]
        XCTAssertNil(TripRouteMap.projection(nearby, in: box), "Spots in one city are spread out instead")
    }
}
