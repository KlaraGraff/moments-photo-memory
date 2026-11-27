import Foundation
import XCTest
@testable import MomentsCore

/// The pieces of the chapter judge: kinds, evidence, the book, the policy
/// and the model's prompt. All places and dates are made up.
final class ChapterJudgeTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private let work = GeoPoint(latitude: 10, longitude: 10)
    private let town = GeoPoint(latitude: 40, longitude: 100)

    /// Friday 2026-01-02 12:00 UTC.
    private let friday = Date(timeIntervalSince1970: 1_767_355_200)

    private func photos(at point: GeoPoint, days: Int, perDay: Int, hour: Int = 12) -> [PhotoStop] {
        (0..<days).flatMap { day in
            (0..<perDay).map { index in
                PhotoStop(
                    id: "p\(day)-\(index)",
                    date: friday.addingTimeInterval(Double(day) * 86_400 + Double(hour - 12) * 3_600 + Double(index) * 60),
                    coordinate: GeoPoint(latitude: point.latitude + Double(index) * 0.001, longitude: point.longitude)
                )
            }
        }
    }

    // MARK: Kinds

    func testKindKeysRoundTrip() throws {
        for kind in ChapterKind.builtIn + [.daily, .custom("Project visit")] {
            XCTAssertEqual(ChapterKind(key: kind.key), kind)
            let data = try JSONEncoder().encode([kind])
            XCTAssertEqual(try JSONDecoder().decode([ChapterKind].self, from: data), [kind])
        }
        XCTAssertNil(ChapterKind(key: "custom:   "))
        XCTAssertNil(ChapterKind(key: "holiday"))
        XCTAssertEqual(ChapterKind.cleanLabel("  Site\nvisit "), "Site visit")
        XCTAssertNil(ChapterKind.cleanLabel(String(repeating: "x", count: 25)))
        XCTAssertFalse(ChapterKind.daily.isChapter)
    }

    // MARK: Evidence

    func testEvidenceCountsDaysWeekendAndDistances() throws {
        let stretch = SyntheticPoint.offset(work, kmNorth: 460)
        let evidence = try XCTUnwrap(SegmentEvidence.make(
            photos: photos(at: stretch, days: 4, perDay: 5),
            bases: [EvidenceBase(role: .work, name: "Site", centre: work), EvidenceBase(role: .homeTown, centre: town)],
            scenes: [["beach", "sea"], ["sand", "beach"], ["construction_vehicle"], []],
            calendar: utc,
            placeName: "Bay"
        ))
        XCTAssertEqual(evidence.dayCount, 4)
        XCTAssertEqual(evidence.weekendDayCount, 2)
        XCTAssertEqual(evidence.firstWeekday, 6)
        XCTAssertEqual(evidence.lastWeekday, 2)
        XCTAssertEqual(evidence.photoCount, 20)
        XCTAssertEqual(evidence.photoDayCount, 4)
        // Friday and Monday at noon are working hours; the weekend is not.
        XCTAssertEqual(evidence.workHourShare, 0.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(evidence.kmFromBase), 460, accuracy: 5)
        XCTAssertEqual(evidence.baseRole, .work)
        XCTAssertEqual(evidence.baseName, "Site")
        XCTAssertGreaterThan(try XCTUnwrap(evidence.kmFromHomeTown), 1_000)
        XCTAssertEqual(evidence.sceneSample, 3)
        XCTAssertEqual(try XCTUnwrap(evidence.leisureSceneShare), 2.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(evidence.workSceneShare), 1.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(evidence.sceneWords.first, "beach")
        XCTAssertNil(SegmentEvidence.make(photos: [], bases: [], calendar: utc))
    }

    func testSceneWordsLeanToWorkOrLeisure() {
        XCTAssertEqual(SceneVocabulary.lean(of: ["construction_vehicle", "crane"]), .work)
        XCTAssertEqual(SceneVocabulary.lean(of: ["beach", "sunset"]), .leisure)
        XCTAssertEqual(SceneVocabulary.lean(of: ["people", "outdoor"]), .neither)
        XCTAssertEqual(SceneVocabulary.lean(of: ["document", "beach"]), .neither)
    }

    // MARK: Rules

    func testHomeTownStretchIsAHomeVisit() throws {
        let evidence = try XCTUnwrap(SegmentEvidence.make(
            photos: photos(at: town, days: 18, perDay: 6),
            bases: [EvidenceBase(role: .work, centre: work), EvidenceBase(role: .homeTown, centre: town)],
            calendar: utc,
            isAbroad: true
        ))
        let verdict = RuleJudge.judge(evidence, book: ChapterJudgeBook())
        XCTAssertEqual(verdict.kind, .homeVisit)
        XCTAssertTrue(verdict.reasons.contains { if case .nearHomeTown = $0 { return true } else { return false } })
    }

    func testVerdictAlternativesNeverRepeatTheKind() {
        let evidence = SyntheticSegments.library()[0].evidence
        let verdict = RuleJudge.judge(evidence, book: ChapterJudgeBook())
        XCTAssertFalse(verdict.alternatives.contains(verdict.kind))
        XCTAssertLessThanOrEqual(verdict.alternatives.count, 3)
        XCTAssertFalse(verdict.reasons.isEmpty)

        // A label that only cleans up to the kind is no alternative either.
        var book = ChapterJudgeBook()
        let stored = ChapterVerdict(kind: .custom("Visit"), confidence: .medium, source: .model, alternatives: [.custom(" Visit "), .trip])
        book.record(stored, for: "a", signature: "s", now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(book.verdict(for: "a")?.alternatives, [.trip])
    }

    func testCombineTrustsTheModelButWeighsTheRules() {
        let evidence = SyntheticSegments.library()[0].evidence
        let book = ChapterJudgeBook()
        let rules = ChapterVerdict(kind: .trip, confidence: .high, source: .rules, alternatives: [.businessTrip])
        let agree = RuleJudge.combine(
            rules: rules, model: ChapterVerdict(kind: .trip, confidence: .medium, source: .model),
            evidence: evidence, book: book
        )
        XCTAssertEqual(agree.confidence, .high)
        XCTAssertEqual(agree.source, .model)
        let disagree = RuleJudge.combine(
            rules: rules, model: ChapterVerdict(kind: .businessTrip, confidence: .high, source: .model),
            evidence: evidence, book: book
        )
        XCTAssertEqual(disagree.kind, .businessTrip)
        XCTAssertEqual(disagree.confidence, .medium)
        XCTAssertEqual(disagree.alternatives.first, .trip)
    }

    // MARK: Policy

    func testPolicyByAskLevel() {
        func action(_ kind: ChapterKind, _ confidence: JudgeConfidence, _ level: AskLevel) -> JudgeAction {
            ConfidencePolicy.action(for: ChapterVerdict(kind: kind, confidence: confidence, source: .rules), level: level)
        }
        XCTAssertEqual(action(.trip, .high, .more), .apply)
        XCTAssertEqual(action(.trip, .medium, .more), .ask)
        XCTAssertEqual(action(.trip, .medium, .balanced), .applyAndCheck)
        XCTAssertEqual(action(.trip, .low, .balanced), .ask)
        XCTAssertEqual(action(.trip, .medium, .less), .apply)
        XCTAssertEqual(action(.trip, .low, .less), .applyAndCheck)
        // Ordinary days remove a chapter, so they are never only checked.
        XCTAssertEqual(action(.daily, .high, .balanced), .apply)
        XCTAssertEqual(action(.daily, .medium, .less), .ask)
        XCTAssertEqual(ConfidencePolicy.action(for: .person(.daily), level: .more), .apply)
    }

    // MARK: Book

    func testBookRemembersDecisionsAndQuestions() {
        let evidence = SyntheticSegments.library()[0].evidence
        let now = evidence.end
        var book = ChapterJudgeBook()
        XCTAssertTrue(book.needsJudging("t1", signature: evidence.signature))
        book.record(ChapterVerdict(kind: .trip, confidence: .low, source: .rules), for: "t1", signature: evidence.signature, now: now)
        XCTAssertFalse(book.needsJudging("t1", signature: evidence.signature))
        XCTAssertTrue(book.needsJudging("t1", signature: "other"))
        XCTAssertTrue(book.isQuestion("t1", now: now))
        XCTAssertNil(book.shownKind(for: "t1"))

        book.deferQuestion(for: "t1", now: now)
        XCTAssertFalse(book.isQuestion("t1", now: now.addingTimeInterval(86_400)))
        XCTAssertTrue(book.isQuestion("t1", now: now.addingTimeInterval(ChapterJudgeBook.deferLifetime + 1)))

        book.record(ChapterVerdict(kind: .trip, confidence: .medium, source: .rules), for: "t2", signature: "s", now: now)
        XCTAssertTrue(book.showsCheck("t2", now: now))
        XCTAssertFalse(book.showsCheck("t2", now: now.addingTimeInterval(ChapterJudgeBook.checkLifetime + 1)))
        book.closeCheck(for: "t2", now: now)
        XCTAssertFalse(book.showsCheck("t2", now: now))
        XCTAssertEqual(book.shownKind(for: "t2"), .trip)

        book.decide(.custom("Visit"), for: "t1", title: "Bay", evidence: evidence, now: now)
        XCTAssertFalse(book.needsJudging("t1", signature: "changed"))
        XCTAssertEqual(book.shownKind(for: "t1"), .custom("Visit"))
        XCTAssertEqual(book.examples.count, 1)
        XCTAssertTrue(book.examples[0].corrected)
        book.decide(.custom("Visit"), for: "t1", title: "Bay", evidence: evidence, now: now)
        XCTAssertEqual(book.examples.count, 1)
        XCTAssertFalse(book.examples[0].corrected)

        book.record(ChapterVerdict(kind: .daily, confidence: .high, source: .rules), for: "t3", signature: "s", now: now)
        book.prune(keeping: [])
        XCTAssertNotNil(book.verdict(for: "t1"))
        XCTAssertNil(book.verdict(for: "t2"))
        XCTAssertNotNil(book.verdict(for: "t3"))

        book.forgetExample("t1")
        XCTAssertTrue(book.examples.isEmpty)
        XCTAssertEqual(book.verdict(for: "t1")?.kind, .custom("Visit"))
    }

    func testSureOrdinaryDaysAreRemovedOrAskedAndUndoKeepsLaterAnswers() {
        let evidence = SyntheticSegments.library()[0].evidence
        let now = evidence.end
        var book = ChapterJudgeBook()
        book.record(ChapterVerdict(kind: .daily, confidence: .high, source: .rules), for: "sure", signature: "s", now: now)
        book.record(ChapterVerdict(kind: .daily, confidence: .medium, source: .rules), for: "unsure", signature: "s", now: now)
        book.record(ChapterVerdict(kind: .trip, confidence: .high, source: .rules), for: "trip", signature: "s", now: now)
        book.decide(.daily, for: "theirs", title: "Site", evidence: evidence, now: now)
        // Only the judge's sure answer, never the person's own.
        XCTAssertEqual(book.removals(among: ["sure", "unsure", "trip", "theirs", "gone"]), ["sure"])
        var off = book
        off.enabled = false
        XCTAssertTrue(off.removals(among: ["sure"]).isEmpty)

        // A trip someone touched, or one brought back, is asked about instead.
        var asked = book
        asked.askInstead(["sure", "theirs"])
        XCTAssertTrue(asked.removals(among: ["sure"]).isEmpty)
        XCTAssertTrue(asked.isQuestion("sure", now: now))
        XCTAssertEqual(asked.verdict(for: "theirs"), book.verdict(for: "theirs"))

        // Undo puts back one chapter's entry and keeps a later answer.
        let before = book.entries(for: ["trip"])
        book.decide(.daily, for: "trip", title: "Bay", evidence: evidence, now: now)
        book.decide(.businessTrip, for: "unsure", title: "Inland", evidence: evidence, now: now)
        book.askLevel = .less
        book.restore(before)
        XCTAssertEqual(book.verdict(for: "trip")?.source, .rules)
        XCTAssertFalse(book.examples.contains { $0.id == "trip" })
        XCTAssertEqual(book.verdict(for: "unsure"), .person(.businessTrip))
        XCTAssertTrue(book.examples.contains { $0.id == "unsure" })
        XCTAssertEqual(book.askLevel, .less)
        // A chapter that had no entry has none again.
        let none = book.entries(for: ["new"])
        book.record(ChapterVerdict(kind: .trip, confidence: .high, source: .rules), for: "new", signature: "s", now: now)
        book.restore(none)
        XCTAssertNil(book.verdict(for: "new"))
    }

    func testBookStorageRoundTripsAndToleratesGaps() {
        let evidence = SyntheticSegments.library()[3].evidence
        var book = ChapterJudgeBook()
        book.askLevel = .less
        book.decide(.businessTrip, for: "t1", title: "Inland", evidence: evidence, now: evidence.end)
        let decoded = ChapterJudgeBook.decode(book.encoded())
        XCTAssertEqual(decoded, book)
        XCTAssertEqual(ChapterJudgeBook.decode(#"{"askLevel":"more"}"#).askLevel, .more)
        XCTAssertEqual(ChapterJudgeBook.decode("not json"), ChapterJudgeBook())
        XCTAssertEqual(ChapterJudgeBook.decode(nil), ChapterJudgeBook())
        XCTAssertFalse(book.encoded().contains("latitude"))
    }

    func testBookKeepsNoBaseNameAndSurvivesBadEntries() throws {
        let evidence = try XCTUnwrap(SegmentEvidence.make(
            photos: photos(at: SyntheticPoint.offset(work, kmNorth: 400), days: 2, perDay: 3),
            bases: [EvidenceBase(role: .work, name: "Secret site", centre: work)],
            calendar: utc
        ))
        var book = ChapterJudgeBook()
        XCTAssertTrue(book.decide(.trip, for: "a", title: "Bay", evidence: evidence, now: friday))
        XCTAssertFalse(book.decide(.custom(String(repeating: "x", count: 30)), for: "b", title: "Hill", evidence: evidence, now: friday))
        XCTAssertNil(book.verdict(for: "b"), "a label that is no type is not stored")
        book.record(ChapterVerdict(kind: .businessTrip, confidence: .high, source: .rules), for: "c", signature: "s", now: friday)
        let stored = book.encoded()
        XCTAssertFalse(stored.contains("Secret site"))
        XCTAssertEqual(ChapterJudgeBook.decode(stored), book)
        // An entry from another version is left out; the rest stays.
        let damaged = stored.replacingOccurrences(of: #""kind":"businessTrip""#, with: #""kind":"custom:""#)
        let mixed = ChapterJudgeBook.decode(damaged)
        XCTAssertEqual(Set(mixed.verdicts.keys), ["a"])
        XCTAssertEqual(mixed.examples.count, 1)
        XCTAssertFalse(book.decide(.custom(""), for: "d", title: "", evidence: evidence, now: friday))

        // Damaged counts never divide by zero.
        let zero = #"{"start":0,"end":0,"dayCount":0,"photoDayCount":0,"photoCount":5,"workHourShare":0.5}"#
        let decoded = try JSONDecoder().decode(SegmentEvidence.self, from: Data(zero.utf8))
        XCTAssertEqual(decoded.photosPerDay, 5)
        XCTAssertEqual(decoded.weekendShare, 0)
        _ = RuleJudge.judge(decoded, book: ChapterJudgeBook())
    }

    func testRenameMovesTheExampleToo() {
        let evidence = SyntheticSegments.library()[0].evidence
        var book = ChapterJudgeBook()
        book.decide(.trip, for: "a", title: "Bay", evidence: evidence, now: evidence.end)
        book.rename("a", to: "b")
        book.decide(.businessTrip, for: "b", title: "Bay", evidence: evidence, now: evidence.end)
        XCTAssertEqual(book.examples.map(\.id), ["b"])
        XCTAssertEqual(book.examples.first?.kind, .businessTrip)
    }

    func testTurnedOffJudgeShowsNothing() {
        var book = ChapterJudgeBook()
        book.record(ChapterVerdict(kind: .trip, confidence: .low, source: .rules), for: "a", signature: "s", now: friday)
        book.enabled = false
        XCTAssertNil(book.action(for: "a"))
        XCTAssertFalse(book.isQuestion("a", now: friday))
        XCTAssertNil(book.shownKind(for: "a"))
    }

    func testModelAloneNeverRemovesAChapterSilently() {
        let evidence = SyntheticSegments.library()[0].evidence
        let combined = RuleJudge.combine(
            rules: ChapterVerdict(kind: .trip, confidence: .medium, source: .rules),
            model: ChapterVerdict(kind: .daily, confidence: .high, source: .model),
            evidence: evidence, book: ChapterJudgeBook()
        )
        XCTAssertEqual(combined.kind, .daily)
        XCTAssertEqual(ConfidencePolicy.action(for: combined, level: .less), .ask)
    }

    func testPromptLeavesOutNamesOfDailyLife() throws {
        let near = try XCTUnwrap(SegmentEvidence.make(
            photos: photos(at: SyntheticPoint.offset(work, kmNorth: 40), days: 1, perDay: 3),
            bases: [EvidenceBase(role: .work, name: "Rivertown", centre: work)],
            calendar: utc, placeName: "Rivertown", title: "Rivertown office"
        ))
        let far = try XCTUnwrap(SegmentEvidence.make(
            photos: photos(at: SyntheticPoint.offset(work, kmNorth: 900), days: 2, perDay: 3),
            bases: [EvidenceBase(role: .work, name: "Rivertown", centre: work)],
            calendar: utc, placeName: "Rivertown", title: "Hills"
        ))
        for evidence in [near, far] {
            let prompt = JudgePrompt.make(evidence: evidence, book: ChapterJudgeBook(), language: "English", calendar: utc)
            XCTAssertFalse(prompt.user.contains("Rivertown"))
        }
        XCTAssertTrue(JudgePrompt.make(evidence: far, book: ChapterJudgeBook(), language: "English", calendar: utc).user.contains("Hills"))
        // A reloaded example's title holding a place's name stays out too.
        var book = ChapterJudgeBook()
        var outing = far
        outing.placeName = "Hills"
        book.decide(.trip, for: "x", title: "Rivertown crew outing", evidence: outing, now: friday)
        let reloaded = ChapterJudgeBook.decode(book.encoded())
        let prompt = JudgePrompt.make(evidence: far, book: reloaded, language: "English", calendar: utc, privateNames: ["Rivertown"])
        XCTAssertFalse(prompt.user.contains("Rivertown"))
        XCTAssertTrue(prompt.user.contains("earlier decisions"))
        let emoji = JudgePrompt(system: "", user: "", allowedKeys: ["trip", "custom:🎉"])
        XCTAssertNil(emoji.parse(#"{"kind":"","confidence":"high"}"#))
    }

    // MARK: Prompt

    func testPromptHoldsFactsAndNoCoordinates() throws {
        let stretch = SyntheticPoint.offset(work, kmNorth: 300)
        let evidence = try XCTUnwrap(SegmentEvidence.make(
            photos: photos(at: stretch, days: 3, perDay: 4),
            bases: [EvidenceBase(role: .work, name: "Secret site", centre: work)],
            scenes: [["beach"]],
            calendar: utc,
            placeName: "Bay"
        ))
        var book = ChapterJudgeBook()
        book.decide(.custom("Project visit"), for: "t0", title: "Hill", evidence: evidence, now: friday)
        let prompt = JudgePrompt.make(evidence: evidence, book: book, language: "Chinese", calendar: utc)
        XCTAssertTrue(prompt.user.contains("2026-01-02 (Friday)"))
        XCTAssertTrue(prompt.user.contains("Place: Bay"))
        XCTAssertTrue(prompt.user.contains("300 km"))
        XCTAssertTrue(prompt.user.contains("custom:Project visit"))
        XCTAssertTrue(prompt.system.contains("Chinese"))
        XCTAssertFalse(prompt.user.contains("Secret site"))
        XCTAssertFalse(prompt.user.contains(String(format: "%.2f", stretch.latitude)))
        XCTAssertEqual(prompt.allowedKeys, ["trip", "businessTrip", "homeVisit", "custom:Project visit", "daily"])
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(prompt.responseSchemaJSON.utf8)) as? [String: Any])
        XCTAssertEqual(schema["type"] as? String, "object")
    }

    func testParsingTheModelsAnswer() {
        let prompt = JudgePrompt(system: "", user: "", allowedKeys: ["trip", "businessTrip", "custom:Project visit", "daily"])
        let plain = prompt.parse(#"{"kind":"businessTrip","confidence":"high","reason":"Three workdays, mostly site photos."}"#)
        XCTAssertEqual(plain?.kind, .businessTrip)
        XCTAssertEqual(plain?.confidence, .high)
        XCTAssertEqual(plain?.modelReason, "Three workdays, mostly site photos.")
        let fenced = prompt.parse("```json\n{\"kind\": \"Project visit\", \"confidence\": \"Medium\", \"reason\": \"“像上次”\\nsecond line\"}\n```")
        XCTAssertEqual(fenced?.kind, .custom("Project visit"))
        XCTAssertEqual(fenced?.confidence, .medium)
        XCTAssertEqual(fenced?.modelReason, "像上次")
        XCTAssertEqual(prompt.parse(#"{"kind":"business_trip","confidence":"sure"}"#)?.confidence, .low)
        XCTAssertNil(prompt.parse(#"{"kind":"homeVisit","confidence":"high"}"#))
        XCTAssertNil(prompt.parse("I think it was a trip."))
        let long = prompt.parse(#"{"kind":"trip","confidence":"low","reason":"\#(String(repeating: "a", count: 200))"}"#)
        XCTAssertEqual(long?.modelReason?.count, 80)
    }
}

/// Points a set distance from another, for made-up libraries.
enum SyntheticPoint {
    static func offset(_ point: GeoPoint, kmNorth: Double) -> GeoPoint {
        GeoPoint(latitude: point.latitude + kmNorth / 111.195, longitude: point.longitude)
    }
}
