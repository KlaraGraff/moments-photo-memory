import Foundation
import SwiftData
import XCTest
@testable import Moments

@MainActor
final class ChapterReorganizeTests: XCTestCase {
    private var container: ModelContainer?
    private var defaults: UserDefaults?
    private var suiteName = ""
    private let origin = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    override func tearDown() {
        container = nil
        if !suiteName.isEmpty {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        defaults = nil
        super.tearDown()
    }

    /// Choices live in their own suite, never in the real ones.
    private func makeDefaults() throws -> UserDefaults {
        suiteName = "ChapterReorganizeTests-\(UUID().uuidString)"
        let suite: UserDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        suite.removePersistentDomain(forName: suiteName)
        defaults = suite
        return suite
    }

    private func makeContext() throws -> ModelContext {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        self.container = container
        return container.mainContext
    }

    private func dayKey(_ date: Date) -> String {
        let parts: DateComponents = utc.dateComponents([.year, .month, .day], from: date)
        let year: Int = parts.year ?? 0
        let month: Int = parts.month ?? 0
        let day: Int = parts.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    @discardableResult
    private func photo(
        _ id: String,
        day: Int,
        hour: Double = 12,
        latitude: Double,
        longitude: Double,
        trip: Trip?,
        in context: ModelContext
    ) -> MediaItem {
        let date: Date = origin.addingTimeInterval(Double(day) * 86_400 + hour * 3_600)
        let key: String = dayKey(date)
        let item = MediaItem(
            id: id,
            captureDate: date,
            latitude: latitude,
            longitude: longitude,
            title: id,
            tripID: trip?.id,
            trip: trip,
            localDayKey: key
        )
        context.insert(item)
        return item
    }

    /// Two months at home (synthetic coordinates) with a four-day trip in the
    /// middle, all in one suggested trip as the old import made it.
    @discardableResult
    private func seedOldImport(in context: ModelContext) -> Trip {
        let old = Trip(id: "old", name: "Trip January 2026", suggestionStatusRaw: "suggestion")
        context.insert(old)
        for day in 0..<60 where !(30..<34).contains(day) {
            photo("home-\(day)", day: day, latitude: 10.0, longitude: 20.0, trip: old, in: context)
        }
        for day in 30..<34 {
            for index in 0..<6 {
                photo("away-\(day)-\(index)", day: day, hour: 9 + Double(index), latitude: 15.0, longitude: 25.0, trip: old, in: context)
            }
        }
        return old
    }

    /// A party at home: forty photos on day 40, five minutes apart, on top of
    /// the one photo the usual day has.
    @discardableResult
    private func seedParty(in context: ModelContext) -> String {
        let date: Date = origin.addingTimeInterval(40 * 86_400 + 9 * 3_600)
        for index in 0..<40 {
            photo("party-\(index)", day: 40, hour: 9 + Double(index) / 12, latitude: 10.0, longitude: 20.0, trip: nil, in: context)
        }
        return dayKey(date)
    }

    func testARenamedTripKeepsAllItsPhotos() throws {
        let context = try makeContext()
        let defaults = try makeDefaults()
        seedOldImport(in: context)
        let renamed = Trip(id: "renamed", name: "Trip", overrideName: "Our weekend", suggestionStatusRaw: "suggestion")
        context.insert(renamed)
        for day in 70..<72 {
            photo("named-\(day)", day: day, latitude: 10.0, longitude: 20.0, trip: renamed, in: context)
        }
        try context.save()

        _ = try ChapterReorganize.run(context: context, defaults: defaults)

        let items: [MediaItem] = try context.fetch(FetchDescriptor<MediaItem>())
        let named: [MediaItem] = items.filter { (item: MediaItem) -> Bool in item.id.hasPrefix("named-") }
        XCTAssertEqual(named.count, 2)
        XCTAssertTrue(named.allSatisfy { (item: MediaItem) -> Bool in item.tripID == "renamed" && item.trip?.id == "renamed" })
    }

    func testRunningTwiceGivesTheSameTrips() throws {
        let context = try makeContext()
        let defaults = try makeDefaults()
        seedOldImport(in: context)
        try context.save()

        let first: ChapterReorganize.Outcome = try ChapterReorganize.run(context: context, defaults: defaults)
        let afterFirst: [String] = try context.fetch(FetchDescriptor<Trip>()).map { (trip: Trip) -> String in trip.id }.sorted()
        XCTAssertEqual(first.regroup.trips, 1)

        let second: ChapterReorganize.Outcome = try ChapterReorganize.run(context: context, defaults: defaults)
        let afterSecond: [String] = try context.fetch(FetchDescriptor<Trip>()).map { (trip: Trip) -> String in trip.id }.sorted()

        XCTAssertEqual(afterSecond, afterFirst)
        XCTAssertEqual(second.regroup.removed, 0)
    }

    func testTheSuggestedDaysListIsRebuilt() throws {
        let context = try makeContext()
        let defaults = try makeDefaults()
        seedOldImport(in: context)
        let partyKey: String = seedParty(in: context)
        try context.save()
        XCTAssertNil(defaults.stringArray(forKey: EventSuggestions.suggestedDaysKey))

        let outcome: ChapterReorganize.Outcome = try ChapterReorganize.run(context: context, defaults: defaults)

        let groups: [UserGroup] = try context.fetch(FetchDescriptor<UserGroup>())
        XCTAssertEqual(outcome.events, 1)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.chapterType, .event)
        let keys: [String] = defaults.stringArray(forKey: EventSuggestions.suggestedDaysKey) ?? []
        XCTAssertEqual(keys, [partyKey])
        XCTAssertEqual(defaults.integer(forKey: TripRegrouping.versionKey), TripRegrouping.currentVersion)
    }
}
