import Foundation
import SwiftData
import XCTest
@testable import Moments

@MainActor
final class EventSuggestionsTests: XCTestCase {
    private var container: ModelContainer?
    private var defaults: UserDefaults!
    private var suiteName = ""
    private let origin = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    override func setUp() {
        super.setUp()
        suiteName = "EventSuggestionsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        container = nil
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// Sixty ordinary days and a party on day 30, all in no trip.
    private func seed() throws -> ModelContext {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        self.container = container
        let context = container.mainContext
        for day in 0..<60 {
            let count = day == 30 ? 40 : 3
            for index in 0..<count {
                let date = origin.addingTimeInterval(Double(day) * 86_400 + 9 * 3_600 + Double(index) * 300)
                let key = String(format: "2026-%02d-%02d", utc.component(.month, from: date), utc.component(.day, from: date))
                context.insert(MediaItem(id: "photo-\(day)-\(index)", captureDate: date, title: "photo", localDayKey: key))
            }
        }
        try context.save()
        return context
    }

    func testABigDayAtTheUsualPlaceBecomesAnEvent() throws {
        let context = try seed()

        XCTAssertEqual(EventSuggestions.suggest(in: context, defaults: defaults, calendar: utc), 1)

        let groups = try context.fetch(FetchDescriptor<UserGroup>())
        let event = try XCTUnwrap(groups.first)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(event.chapterType, .event)
        XCTAssertEqual(TripEdits.memberIDs(of: event, context: context).count, 40)
        XCTAssertTrue(TripEdits.memberIDs(of: event, context: context).allSatisfy { $0.hasPrefix("photo-30-") })
    }

    func testADeletedEventStaysGone() throws {
        let context = try seed()
        EventSuggestions.suggest(in: context, defaults: defaults, calendar: utc)
        for group in try context.fetch(FetchDescriptor<UserGroup>()) { context.delete(group) }
        try context.save()

        XCTAssertEqual(EventSuggestions.suggest(in: context, defaults: defaults, calendar: utc), 0)
    }
}
