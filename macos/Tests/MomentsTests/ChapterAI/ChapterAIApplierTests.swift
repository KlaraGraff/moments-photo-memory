import Foundation
import MomentsCore
import SwiftData
import XCTest
@testable import Moments

@MainActor
final class ChapterAIApplierTests: XCTestCase {
    private var container: ModelContainer?
    private var defaults: UserDefaults!
    private var suiteName = ""

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    override func setUp() {
        super.setUp()
        suiteName = "ChapterAIApplierTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        container = nil
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// Three photos a day, 2026-08-01 to 2026-08-20.
    private func seed() throws -> ModelContext {
        let container = try MomentsPersistence.makeContainer(inMemory: true)
        self.container = container
        let context = container.mainContext
        for day in 1...20 {
            for index in 0..<3 {
                let date = utc.date(from: DateComponents(year: 2026, month: 8, day: day, hour: 10 + index))!
                context.insert(MediaItem(id: "p-\(day)-\(index)", captureDate: date, title: "photo", localDayKey: String(format: "2026-08-%02d", day)))
            }
        }
        try context.save()
        return context
    }

    private func applier(_ context: ModelContext, now: Date = .now) -> ChapterAIApplier {
        ChapterAIApplier(context: context, defaults: defaults, calendar: utc, now: now)
    }

    private func items(_ context: ModelContext) throws -> [MediaItem] {
        try context.fetch(FetchDescriptor<MediaItem>())
    }

    private func chapters(_ context: ModelContext) throws -> [UserGroup] {
        try context.fetch(FetchDescriptor<UserGroup>(predicate: #Predicate { $0.kindRaw == "chapter" }))
    }

    private let trip = ChapterProposal(start: "2026-08-05", end: "2026-08-08", type: .trip, title: "Lisbon", summary: "Tiles and trams.")
    private let party = ChapterProposal(start: "2026-08-15", end: "2026-08-15", type: .celebration, title: "Birthday")

    func testWritesTripsAndChaptersAndRemembersThem() throws {
        let context = try seed()

        let written = try applier(context).apply([trip, party])

        XCTAssertEqual(written.outcome.trips, 1)
        XCTAssertEqual(written.outcome.chapters, 1)
        let trips = try context.fetch(FetchDescriptor<Trip>())
        XCTAssertEqual(trips.map(\.name), ["Lisbon"])
        XCTAssertEqual(Set(trips[0].items.map(\.id)), Set((5...8).flatMap { day in (0..<3).map { "p-\(day)-\($0)" } }))
        XCTAssertTrue(trips[0].isSuggestion)
        let group = try XCTUnwrap(chapters(context).first)
        XCTAssertEqual(group.name, "Birthday")
        XCTAssertEqual(group.chapterInfo.madeBy, "ai")
        XCTAssertEqual(TripEdits.memberIDs(of: group, context: context).count, 3)
        let registry = ChapterAIRegistry.load(defaults)
        XCTAssertEqual(Set(registry.made.keys), [trips[0].id, group.id])
    }

    func testARunReplacesWhatTheLastRunMadeInsteadOfAddingMore() throws {
        let context = try seed()
        try applier(context).apply([trip, party])

        let longer = ChapterProposal(start: "2026-08-04", end: "2026-08-09", type: .trip, title: "Lisbon and Sintra")
        let written = try applier(context, now: .now.addingTimeInterval(60)).apply([longer, party])

        let trips = try context.fetch(FetchDescriptor<Trip>())
        XCTAssertEqual(trips.map(\.name), ["Lisbon and Sintra"])
        XCTAssertEqual(trips[0].items.count, 18)
        XCTAssertEqual(try chapters(context).count, 1)
        XCTAssertEqual(written.outcome.removed, 1)
    }

    func testADeletedChapterIsNotMadeAgain() throws {
        let context = try seed()
        try applier(context).apply([party])
        let session = TripEdits.Session(context: context, calendar: utc, defaults: defaults)
        TripEdits.delete(try XCTUnwrap(chapters(context).first), session: session)

        let written = try applier(context, now: .now.addingTimeInterval(60)).apply([party])

        XCTAssertTrue(try chapters(context).isEmpty)
        XCTAssertEqual(written.outcome.skipped, [party])
        XCTAssertEqual(ChapterAIRegistry.load(defaults).dismissed.count, 1)
    }

    func testAChapterChangedByHandIsKept() throws {
        let context = try seed()
        try applier(context).apply([party])
        let group = try XCTUnwrap(chapters(context).first)
        group.name = "Mia's birthday"
        group.updatedAt = .now.addingTimeInterval(30)
        try context.save()

        try applier(context, now: .now.addingTimeInterval(60)).apply([party])

        XCTAssertEqual(try chapters(context).map(\.name), ["Mia's birthday"])
    }

    func testATripPeopleKeptIsLeftAlone() throws {
        let context = try seed()
        let kept = Trip(
            id: "kept", name: "Porto",
            startDate: utc.date(from: DateComponents(year: 2026, month: 8, day: 6, hour: 10)),
            endDate: utc.date(from: DateComponents(year: 2026, month: 8, day: 7, hour: 12)),
            suggestionStatusRaw: "confirmed"
        )
        context.insert(kept)
        for item in try items(context) where ["2026-08-06", "2026-08-07"].contains(item.localDayKey ?? "") {
            item.trip = kept
            item.tripID = kept.id
        }
        try context.save()

        let written = try applier(context).apply([trip])

        XCTAssertEqual(written.outcome.trips, 0)
        XCTAssertEqual(written.outcome.skipped, [trip])
        XCTAssertEqual(try context.fetch(FetchDescriptor<Trip>()).map(\.id), ["kept"])
        XCTAssertEqual(kept.items.count, 6)
    }

    func testARuleTripIsReplacedAndUndoPutsItBack() throws {
        let context = try seed()
        let rule = Trip(id: "rule", name: "August", suggestionStatusRaw: "suggestion")
        context.insert(rule)
        for item in try items(context) where (item.localDayKey ?? "") >= "2026-08-10" && (item.localDayKey ?? "") <= "2026-08-12" {
            item.trip = rule
            item.tripID = rule.id
        }
        try context.save()

        let written = try applier(context).apply([trip, party])

        XCTAssertEqual(try context.fetch(FetchDescriptor<Trip>()).map(\.name), ["Lisbon"])
        XCTAssertEqual(written.outcome.left, 9)

        ChapterAIApplier.undo(written, context: context, defaults: defaults)

        let trips = try context.fetch(FetchDescriptor<Trip>())
        XCTAssertEqual(trips.map(\.id), ["rule"])
        XCTAssertEqual(trips[0].items.count, 9)
        XCTAssertTrue(try chapters(context).isEmpty)
        XCTAssertEqual(ChapterAIRegistry.load(defaults), ChapterAIRegistry())
    }

    func testAScopedRunLeavesOtherDaysAlone() throws {
        let context = try seed()
        try applier(context).apply([trip, party])

        let written = try applier(context, now: .now.addingTimeInterval(60)).apply([], scope: "2026-08-14"..."2026-08-16")

        XCTAssertEqual(written.outcome.removed, 1)
        XCTAssertTrue(try chapters(context).isEmpty)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Trip>()).map(\.name), ["Lisbon"])
    }

    func testDaysTheModelCouldNotLookAtStayAsTheyWere() throws {
        let context = try seed()
        try applier(context).apply([trip, party])

        let written = try applier(context, now: .now.addingTimeInterval(60)).apply([], frozen: ["2026-08-01"..."2026-08-16"])

        XCTAssertEqual(written.outcome.removed, 0)
        XCTAssertEqual(written.outcome.left, 0)
        XCTAssertEqual(try chapters(context).map(\.name), ["Birthday"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<Trip>()).first?.items.count, 12)
    }

    func testChaptersBroughtBackByUndoAreMomentsOwnAgain() throws {
        let context = try seed()
        try applier(context).apply([party])
        let other = ChapterProposal(start: "2026-08-15", end: "2026-08-16", type: .event, title: "Weekend")
        let written = try applier(context, now: .now.addingTimeInterval(60)).apply([other])

        ChapterAIApplier.undo(written, context: context, defaults: defaults, now: .now.addingTimeInterval(120))

        XCTAssertEqual(try chapters(context).map(\.name), ["Birthday"])
        XCTAssertEqual(try applier(context).state().machineGroups.count, 1)
    }

    func testUndoIsRefusedOnceSomeoneChangedWhatTheRunMade() throws {
        let context = try seed()
        let written = try applier(context).apply([trip])
        XCTAssertFalse(try applier(context).changedSince(written))

        let made = try XCTUnwrap(context.fetch(FetchDescriptor<Trip>()).first)
        made.overrideName = "Lisboa"
        try context.save()

        XCTAssertTrue(try applier(context).changedSince(written))
    }

    func testATripDeletedByHandIsNotMadeAgain() throws {
        let context = try seed()
        try applier(context).apply([trip])
        let made = try XCTUnwrap(context.fetch(FetchDescriptor<Trip>()).first)
        TripEdits.delete(made, session: TripEdits.Session(context: context, calendar: utc, defaults: defaults))

        let written = try applier(context, now: .now.addingTimeInterval(60)).apply([trip])

        XCTAssertEqual(written.outcome.trips, 0)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Trip>()).isEmpty)
    }

    func testAnEventTheRulesSuggestedAndSomeoneDeletedStaysGone() throws {
        let context = try seed()
        defaults.set(["2026-08-15"], forKey: EventSuggestions.suggestedDaysKey)

        let written = try applier(context).apply([party])

        XCTAssertEqual(written.outcome.chapters, 0)
    }

    func testOnlyDaysNoOtherWindowCoversStayFrozen() {
        let frozen = ChapterAIOrganizer.uncovered("2026-08-01"..."2026-08-20", by: ["2026-07-20"..."2026-08-05", "2026-08-16"..."2026-09-01"])
        XCTAssertEqual(frozen, ["2026-08-06"..."2026-08-15"])
        XCTAssertEqual(ChapterAIOrganizer.uncovered("2026-08-01"..."2026-08-03", by: ["2026-07-01"..."2026-09-01"]), [])
    }
}

final class ClaudeChapterClientTests: XCTestCase {
    func testKnownModelsGetEffortAndThinkingOff() throws {
        let client = ClaudeChapterClient(apiKey: "k", model: ClaudeModel.haiku.rawValue)
        let body = client.requestBody(system: "s", content: [ClaudeChapterClient.text("hi")], schema: ["type": "object"], maxTokens: 100, effort: "low", thinking: false)

        let config = try XCTUnwrap(body["output_config"] as? [String: Any])
        XCTAssertEqual(config["effort"] as? String, "low")
        XCTAssertEqual((body["thinking"] as? [String: Any])?["type"] as? String, "disabled")
        XCTAssertNil(body["fallbacks"])
    }

    func testOtherModelsGetOnlyTheSchema() throws {
        let client = ClaudeChapterClient(apiKey: "k", model: "claude-something-else")
        let body = client.requestBody(system: "s", content: [], schema: ["type": "object"], maxTokens: 100, effort: "low", thinking: false)

        let config = try XCTUnwrap(body["output_config"] as? [String: Any])
        XCTAssertNil(config["effort"])
        XCTAssertNil(body["thinking"])
        XCTAssertNotNil(config["format"])
    }

    func testReplyReadsTextAndUsage() throws {
        let reply = try ClaudeChapterClient.reply(from: [
            "stop_reason": "end_turn",
            "content": [["type": "thinking", "thinking": "…"], ["type": "text", "text": "{\"a\":1}"]],
            "usage": ["input_tokens": 50_000, "output_tokens": 2_000]
        ], model: ClaudeModel.haiku.rawValue)

        XCTAssertEqual(reply.text, "{\"a\":1}")
        XCTAssertEqual(reply.usage.inputTokens, 50_000)
        XCTAssertEqual(reply.usage.dollars ?? 0, 0.006, accuracy: 0.00001)
    }

    func testACutOffAnswerIsAnError() {
        XCTAssertThrowsError(try ClaudeChapterClient.reply(from: ["stop_reason": "max_tokens", "content": []], model: "m")) { error in
            XCTAssertEqual(error as? ChapterAIError, .cutOff)
        }
    }

    func testOnlyBusyErrorsAreRetried() {
        XCTAssertTrue(ClaudeChapterClient.isWorthRetrying(.http(529, "overloaded")))
        XCTAssertTrue(ClaudeChapterClient.isWorthRetrying(.http(429, "")))
        XCTAssertFalse(ClaudeChapterClient.isWorthRetrying(.http(401, "")))
        XCTAssertFalse(ClaudeChapterClient.isWorthRetrying(.http(400, "")))
    }
}
