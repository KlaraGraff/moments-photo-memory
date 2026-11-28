import Foundation
import XCTest
@testable import MomentsCore

/// How well the rules sort a made-up library, and how they learn from the
/// person. The figures are floors that a change to the rules must keep.
final class ChapterJudgeEvaluationTests: XCTestCase {
    private func outcome(_ cases: [SyntheticSegments.Case], book: ChapterJudgeBook = ChapterJudgeBook())
        -> (applied: Int, right: Int, asked: Int, sureAndWrong: [String])
    {
        var applied = 0, right = 0, asked = 0
        var sureAndWrong: [String] = []
        for item in cases {
            let verdict = RuleJudge.judge(item.evidence, book: book)
            if ConfidencePolicy.action(for: verdict, level: book.askLevel) == .ask {
                asked += 1
                continue
            }
            applied += 1
            if verdict.kind == item.truth {
                right += 1
            } else if verdict.confidence == .high {
                sureAndWrong.append("\(item.name): \(verdict.kind.key)")
            }
        }
        return (applied, right, asked, sureAndWrong)
    }

    func testRulesSortTheLibrary() {
        let cases = SyntheticSegments.library()
        let result = outcome(cases)
        let accuracy = Double(result.right) / Double(max(result.applied, 1))
        let askedShare = Double(result.asked) / Double(cases.count)
        print("chapter judge: \(result.right)/\(result.applied) right, \(result.asked) of \(cases.count) asked, sure and wrong: \(result.sureAndWrong)")
        XCTAssertGreaterThanOrEqual(accuracy, 0.92)
        XCTAssertLessThanOrEqual(askedShare, 0.25)
        XCTAssertTrue(result.sureAndWrong.isEmpty, "\(result.sureAndWrong)")
    }

    func testUnclearStretchesAreAskedOrChecked() {
        for item in SyntheticSegments.unclear() {
            let verdict = RuleJudge.judge(item.evidence, book: ChapterJudgeBook())
            XCTAssertNotEqual(verdict.confidence, .high, item.name)
            XCTAssertNotEqual(ConfidencePolicy.action(for: verdict, level: .balanced), .apply, item.name)
        }
    }

    func testAskingMoreAsksMoreOften() {
        let cases = SyntheticSegments.library() + SyntheticSegments.unclear()
        var more = ChapterJudgeBook(); more.askLevel = .more
        var less = ChapterJudgeBook(); less.askLevel = .less
        let balanced = outcome(cases).asked
        XCTAssertGreaterThanOrEqual(outcome(cases, book: more).asked, balanced)
        XCTAssertLessThanOrEqual(outcome(cases, book: less).asked, balanced)
        XCTAssertGreaterThan(outcome(cases, book: more).asked, outcome(cases, book: less).asked)
    }

    /// A kind the person named for one stretch is given to the next stretch
    /// like it, with no rule written for it.
    func testOneCorrectionTeachesAnOwnKind() {
        var random = SyntheticSegments.Random(state: 3)
        let visit = { (random: inout SyntheticSegments.Random) in
            SyntheticSegments.evidence(
                &random, days: 2, weekendDays: 0, perDay: 4...8, workHours: 0.6...0.9,
                km: 120...180, work: 0.3...0.6, leisure: 0.0...0.1, place: "Oldtown"
            )
        }
        let first = visit(&random)
        var book = ChapterJudgeBook()
        XCTAssertEqual(RuleJudge.judge(first, book: book).kind, .businessTrip)

        book.decide(.custom("Project visit"), for: "trip-1", title: "Oldtown", evidence: first, now: first.end)
        XCTAssertTrue(book.candidates.contains(.custom("Project visit")))
        let next = visit(&random)
        let verdict = RuleJudge.judge(next, book: book)
        XCTAssertEqual(verdict.kind, .custom("Project visit"))
        XCTAssertTrue(verdict.reasons.contains { if case .similar = $0 { return true } else { return false } })

        // A holiday far away stays a trip: the example only speaks for days like it.
        let holiday = SyntheticSegments.library().first { $0.truth == .trip }!.evidence
        XCTAssertEqual(RuleJudge.judge(holiday, book: book).kind, .trip)
    }

    /// The person says a weekday stretch away was a holiday: the next one
    /// like it is no longer called a business trip.
    func testCorrectionOverridesTheRulesForSimilarDays() {
        var random = SyntheticSegments.Random(state: 5)
        let away = { (random: inout SyntheticSegments.Random) in
            SyntheticSegments.evidence(
                &random, days: 3, weekendDays: 0, perDay: 6...9, workHours: 0.6...0.8,
                km: 300...350, work: nil, leisure: nil, place: "Seaside"
            )
        }
        let first = away(&random)
        var book = ChapterJudgeBook()
        XCTAssertEqual(RuleJudge.judge(first, book: book).kind, .businessTrip)
        book.decide(.trip, for: "trip-a", title: "Seaside", evidence: first, now: first.end)
        XCTAssertEqual(RuleJudge.judge(away(&random), book: book).kind, .trip)
    }
}
