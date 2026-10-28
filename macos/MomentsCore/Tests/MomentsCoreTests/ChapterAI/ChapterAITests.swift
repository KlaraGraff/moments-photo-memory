import Foundation
import XCTest
@testable import MomentsCore

final class DayKeyTests: XCTestCase {
    func testRoundTripsAndRejectsNonsense() {
        XCTAssertEqual(DayKey.ordinal("1970-01-02"), 1)
        XCTAssertEqual(DayKey.key(ordinal: DayKey.ordinal("2026-02-28")! + 1), "2026-03-01")
        XCTAssertEqual(DayKey.adding(-1, to: "2026-01-01"), "2025-12-31")
        XCTAssertEqual(DayKey.length(from: "2026-03-01", to: "2026-03-03"), 3)
        XCTAssertNil(DayKey.ordinal("2026-02-30"))
        XCTAssertNil(DayKey.ordinal("2026-2-3"))
        XCTAssertNil(DayKey.ordinal("photos"))
    }
}

final class ChapterDigestTests: XCTestCase {
    func testADayLineCarriesWhatTheModelNeeds() {
        let day = DayEvidence(
            dayKey: "2026-03-07", photos: 46, videos: 3, moments: 12, isAway: true,
            places: ["Kyoto", "Gion"], people: ["Lin"], notes: ["first night\nin Kyoto"],
            captions: ["temple gate, two people", "matcha dessert", "temple gate, two people"],
            documents: 2, ruleTrip: 4
        )
        let line = ChapterDigest().line(for: day)
        XCTAssertEqual(
            line,
            "2026-03-07 Sat · away · Kyoto, Gion · 46 photos, 3 videos, 12 moments · with Lin · notes: \"first night in Kyoto\" · seen: temple gate, two people | matcha dessert · 2 documents · rules: trip candidate 4"
        )
    }

    func testQuietDaysAreSummedUpInOneLine() {
        var digest = ChapterDigest()
        digest.tokenBudget = 10_000
        let days = [
            DayEvidence(dayKey: "2026-03-01", photos: 2),
            DayEvidence(dayKey: "2026-03-02", photos: 1),
            DayEvidence(dayKey: "2026-03-04", photos: 3),
            DayEvidence(dayKey: "2026-03-05", photos: 40, isBigDay: true)
        ]
        let windows = digest.windows(days)
        XCTAssertEqual(windows.count, 1)
        let lines = windows[0].text.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0], "2026-03-01 to 2026-03-04 · usual places · 3 days with photos, 6 photos in all")
        XCTAssertTrue(lines[1].hasPrefix("2026-03-05 Thu · usual places · 40 photos"))
        XCTAssertEqual(windows[0].firstDay, "2026-03-01")
        XCTAssertEqual(windows[0].lastDay, "2026-03-05")
    }

    func testWindowsStayInBudgetAndShareTheirEdges() {
        var digest = ChapterDigest()
        digest.tokenBudget = 300
        digest.overlapDays = 3
        let days = (0..<60).map { offset in
            DayEvidence(dayKey: DayKey.key(ordinal: DayKey.ordinal("2026-01-01")! + offset), photos: 5, isAway: true, places: ["Somewhere far"], captions: ["a view"])
        }
        let windows = digest.windows(days)
        XCTAssertGreaterThan(windows.count, 2)
        for window in windows {
            XCTAssertLessThanOrEqual(ChapterDigest.estimatedTokens(window.text), 300 + window.dayCount)
        }
        for (earlier, later) in zip(windows, windows.dropFirst()) {
            XCTAssertLessThanOrEqual(later.firstDay, earlier.lastDay, "neighbours share days")
            XCTAssertGreaterThan(later.firstDay, earlier.firstDay, "each window moves on")
            XCTAssertEqual(DayKey.length(from: later.firstDay, to: earlier.lastDay), 3)
        }
        XCTAssertEqual(windows.first?.firstDay, "2026-01-01")
        XCTAssertEqual(windows.last?.lastDay, days.last?.dayKey)
    }

    func testSpreadKeepsBothEnds() {
        XCTAssertEqual(ChapterDigest.spread(Array(1...10), limit: 4), [1, 4, 7, 10])
        XCTAssertEqual(ChapterDigest.spread([1, 2], limit: 4), [1, 2])
        XCTAssertEqual(ChapterDigest.spread([1, 2, 3], limit: 1), [2])
    }

    func testChineseCountsAsAboutOneTokenACharacter() {
        XCTAssertEqual(ChapterDigest.estimatedTokens("京都祇园"), 4)
        XCTAssertEqual(ChapterDigest.estimatedTokens("abcdefg"), 2)
    }
}

final class ChapterPlanTests: XCTestCase {
    func testParseKeepsSensibleChaptersInsideTheWindow() throws {
        let text = """
        Here you go: {"chapters":[
          {"start":"2026-03-06","end":"2026-03-10","type":"trip","title":"京都赏樱","summary":"在京都看樱花。","confidence":"high"},
          {"start":"2026-03-01","end":"2026-03-20","type":"event","title":"too long","summary":"","confidence":"low"},
          {"start":"2026-03-12","end":"2026-03-11","type":"celebration","title":"生日","summary":"","confidence":"medium"},
          {"start":"2026-03-15","end":"2026-03-15","type":"holiday","title":"unknown kind","summary":"","confidence":"medium"},
          {"start":"2026-03-16","end":"2026-03-16","type":"event","title":"  ","summary":"","confidence":"medium"},
          {"start":"2026-03-29","end":"2026-04-03","type":"trip","title":"海边","summary":"","confidence":"medium"}
        ]}
        """
        let chapters = try ChapterPlan.parse(text, firstDay: "2026-03-01", lastDay: "2026-03-31")
        XCTAssertEqual(chapters.map(\.title), ["京都赏樱", "生日", "海边"])
        XCTAssertEqual(chapters[1].start, "2026-03-11", "swapped ends are put right")
        XCTAssertEqual(chapters[2].end, "2026-03-31", "cut at the window's edge")
        XCTAssertThrowsError(try ChapterPlan.parse("no json", firstDay: "2026-03-01", lastDay: "2026-03-31"))
    }

    func testATripCutByTwoWindowsBecomesOne() {
        let first = [ChapterProposal(start: "2026-03-20", end: "2026-03-31", type: .trip, title: "Japan")]
        let second = [
            ChapterProposal(start: "2026-03-20", end: "2026-04-04", type: .trip, title: "Japan in spring"),
            ChapterProposal(start: "2026-04-20", end: "2026-04-20", type: .celebration, title: "Birthday")
        ]
        let merged = ChapterPlan.merge([first, second])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0], ChapterProposal(start: "2026-03-20", end: "2026-04-04", type: .trip, title: "Japan in spring"))
        XCTAssertEqual(merged[1].title, "Birthday")
    }

    func testTheSameEventFromTwoWindowsIsKeptOnceAndEventsInsideTripsGo() {
        let merged = ChapterPlan.merge([
            [ChapterProposal(start: "2026-05-01", end: "2026-05-01", type: .event, title: "Concert"),
             ChapterProposal(start: "2026-06-01", end: "2026-06-05", type: .trip, title: "Rome")],
            [ChapterProposal(start: "2026-05-01", end: "2026-05-02", type: .event, title: "Concert weekend"),
             ChapterProposal(start: "2026-06-03", end: "2026-06-03", type: .celebration, title: "Birthday in Rome"),
             ChapterProposal(start: "2026-06-01", end: "2026-07-30", type: .period, title: "Summer of moving")]
        ])
        XCTAssertEqual(merged.map(\.title), ["Concert weekend", "Rome", "Summer of moving"])
    }
}

final class ChapterPromptsTests: XCTestCase {
    func testCaptionsAreReadByNumber() throws {
        let text = #"{"photos":[{"n":1,"caption":"机场登机口，一个行李箱","kind":"object"},{"n":2,"caption":"生日蛋糕\n和蜡烛","kind":"FOOD"},{"n":9,"caption":"out of range","kind":"other"},{"n":3,"caption":"   ","kind":"other"},{"n":4,"caption":"receipt","kind":"bill"}]}"#
        let captions = try ChapterPrompts.parseCaptions(text, count: 4)
        XCTAssertEqual(captions[1], ChapterPrompts.Caption(text: "机场登机口，一个行李箱", kind: "object"))
        XCTAssertEqual(captions[2], ChapterPrompts.Caption(text: "生日蛋糕 和蜡烛", kind: "food"))
        XCTAssertNil(captions[3])
        XCTAssertEqual(captions[4]?.kind, "other")
        XCTAssertNil(captions[9])
    }

    func testTheLabelSkipsWhatIsUnknown() {
        XCTAssertEqual(ChapterPrompts.captionLabel(number: 3, time: "14:05", place: "Kyoto, Gion"), "Photo 3 · 14:05 · Kyoto, Gion")
        XCTAssertEqual(ChapterPrompts.captionLabel(number: 4, time: nil, place: ""), "Photo 4")
    }

    func testTheInstructionsNameTheLanguage() {
        XCTAssertTrue(ChapterPrompts.chapterInstructions(language: "Simplified Chinese").contains("in Simplified Chinese"))
        XCTAssertTrue(ChapterPrompts.captionInstructions(language: "German").contains("in German"))
    }
}

final class ModelUsageTests: XCTestCase {
    func testHaikuPricesEachRequestByItsPromptLength() {
        let short = ModelUsage(model: "claude-haiku-5-5", input: 50_000, output: 2_000)
        XCTAssertEqual(short.dollars ?? 0, 0.005 + 0.001, accuracy: 1e-9)
        let long = ModelUsage(model: "claude-haiku-5-5", input: 120_000, output: 1_000)
        XCTAssertEqual(long.dollars ?? 0, 0.06 + 0.0025, accuracy: 1e-9)
        let sum = short + long
        XCTAssertEqual(sum.requests, 2)
        XCTAssertEqual(sum.dollars ?? 0, 0.0685, accuracy: 1e-9)
    }

    func testAnUnknownModelHasNoPrice() {
        let sum = ModelUsage(model: "claude-sonnet-5-5", input: 1_000_000, output: 0) + ModelUsage(model: "someone-else", input: 10, output: 10)
        XCTAssertNil(sum.dollars)
        XCTAssertEqual(sum.inputTokens, 1_000_010)
    }

    func testImagesCostOneTokenPerPatch() {
        XCTAssertEqual(ModelPricing.imageTokens(width: 448, height: 336), 16 * 12)
        XCTAssertEqual(ModelPricing.imageTokens(width: 449, height: 1), 17)
    }
}

final class CaptionSamplerTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_767_225_600)

    private func photo(_ id: String, day: String = "2026-01-01", minutes: Double, hash: UInt64? = nil, faces: Bool = false, screenshot: Bool = false) -> CaptionSampler.Photo {
        CaptionSampler.Photo(id: id, dayKey: day, date: origin.addingTimeInterval(minutes * 60), hash: hash, hasFaces: faces, isScreenshot: screenshot)
    }

    func testAllPhotosLeavesOutOnlyScreenshots() {
        let photos = [photo("b", minutes: 2), photo("a", minutes: 1), photo("s", minutes: 3, screenshot: true)]
        XCTAssertEqual(CaptionSampler().choose(photos, vision: .allPhotos), ["a", "b"])
        XCTAssertEqual(CaptionSampler().choose(photos, vision: .textOnly), [])
    }

    func testSampledSpreadsOverTheDayAndSkipsBursts() {
        var photos = (0..<24).map { photo("p\($0)", minutes: Double($0) * 30) }
        // A burst right after p0, with faces: it stands for the burst.
        photos.append(photo("burst", minutes: 0.5, faces: true))
        let chosen = CaptionSampler().choose(photos, vision: .sampled)
        // 24 distinct moments: 2 + 24 / 8 = 5 photos.
        XCTAssertEqual(chosen.count, 5)
        XCTAssertEqual(chosen.first, "burst")
        XCTAssertFalse(chosen.contains("p0"))
        XCTAssertEqual(Set(chosen).count, chosen.count)
    }

    func testNearDuplicatesCountOnce() {
        let photos = [photo("a", minutes: 0, hash: 0xFF), photo("b", minutes: 10, hash: 0xFE), photo("c", minutes: 20, hash: 0xFFFF_0000_0000)]
        XCTAssertEqual(CaptionSampler().distinct(photos).map(\.id), ["a", "c"])
    }
}

final class ChapterAssignmentTests: XCTestCase {
    func testTripsTakeFreePhotosAndChaptersTakeAnyPhoto() {
        let items = [
            ChapterAssignment.Item(id: "home", dayKey: "2026-03-01", isInMachineTrip: true),
            ChapterAssignment.Item(id: "kyoto1", dayKey: "2026-03-06", isInMachineTrip: true),
            ChapterAssignment.Item(id: "kyoto2", dayKey: "2026-03-07"),
            ChapterAssignment.Item(id: "kyotoLocked", dayKey: "2026-03-07", isFree: false),
            ChapterAssignment.Item(id: "ticket", dayKey: "2026-03-07", isScreenshot: true, isInMachineTrip: true),
            ChapterAssignment.Item(id: "party", dayKey: "2026-04-02")
        ]
        let result = ChapterAssignment.assign(items: items, proposals: [
            ChapterProposal(start: "2026-03-06", end: "2026-03-08", type: .trip, title: "Kyoto"),
            ChapterProposal(start: "2026-03-07", end: "2026-03-07", type: .celebration, title: "Birthday in Kyoto"),
            ChapterProposal(start: "2026-04-02", end: "2026-04-02", type: .event, title: "Party"),
            ChapterProposal(start: "2026-05-01", end: "2026-05-01", type: .event, title: "No photos")
        ])
        XCTAssertEqual(result.trips.map(\.itemIDs), [["kyoto1", "kyoto2"]])
        XCTAssertEqual(result.chapters.map(\.itemIDs), [["kyoto2", "kyotoLocked"], ["party"]])
        XCTAssertEqual(result.leaving, ["home", "ticket"])
        XCTAssertEqual(result.skipped.map(\.title), ["No photos"])
    }

    func testTakenDaysAreNotMadeAgain() {
        let items = [ChapterAssignment.Item(id: "a", dayKey: "2026-03-06"), ChapterAssignment.Item(id: "b", dayKey: "2026-07-01")]
        let result = ChapterAssignment.assign(
            items: items,
            proposals: [
                ChapterProposal(start: "2026-03-05", end: "2026-03-08", type: .trip, title: "Kyoto"),
                ChapterProposal(start: "2026-07-01", end: "2026-07-01", type: .event, title: "Party")
            ],
            taken: [
                ChapterAssignment.Taken(start: "2026-03-06", end: "2026-03-09", isTrip: true),
                ChapterAssignment.Taken(start: "2026-07-01", end: "2026-07-01", isTrip: true)
            ]
        )
        XCTAssertEqual(result.skipped.map(\.title), ["Kyoto"])
        XCTAssertEqual(result.chapters.map(\.proposal.title), ["Party"], "a taken trip does not block an event")
    }

    func testOnlyDaysInScopeLeaveTheirTrip() {
        let items = [
            ChapterAssignment.Item(id: "old", dayKey: "2025-01-01", isInMachineTrip: true),
            ChapterAssignment.Item(id: "new", dayKey: "2026-01-01", isInMachineTrip: true)
        ]
        let result = ChapterAssignment.assign(items: items, proposals: [], scope: "2025-12-01"..."2026-02-01")
        XCTAssertEqual(result.leaving, ["new"])
    }
}
