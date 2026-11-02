import Foundation
import XCTest
@testable import MomentsCore

final class BigDayFinderEdgeCaseTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01

    func testEmptyInputGivesNoBigDays() {
        XCTAssertTrue(BigDayFinder().bigDays([]).isEmpty)
    }

    func testADayWithNineteenMomentsIsNeverBig() {
        let ordinaryDays = (0..<60).filter { $0 != 30 }.flatMap { photos(day: $0, count: 1) }
        let almostBig = photos(day: 30, count: 19)

        XCTAssertTrue(BigDayFinder().bigDays(ordinaryDays + almostBig).isEmpty)
    }

    func testTheMultipleOfUsualRuleUsesTheMedianOfNearbyPhotoDays() {
        let target = photos(day: 50, count: 30)
        let usualFive = [45, 46, 47, 48, 49].flatMap { photos(day: $0, count: 5) }
        XCTAssertEqual(BigDayFinder().bigDays(usualFive + target), [[key(50)]])

        let usualTwelve = [45, 46, 47, 48, 49].flatMap { photos(day: $0, count: 12) }
        XCTAssertTrue(BigDayFinder().bigDays(usualTwelve + target).isEmpty)
    }

    func testFourBigDaysInARowGiveRunsOfThreeAndOne() {
        let ordinaryDays = (0..<60).filter { !(20..<24).contains($0) }.flatMap { photos(day: $0, count: 3) }
        let longEvent = (20..<24).flatMap { photos(day: $0, count: 30) }

        XCTAssertEqual(
            BigDayFinder().bigDays(ordinaryDays + longEvent),
            [[key(20), key(21), key(22)], [key(23)]]
        )
    }

    func testDayKeysThatAreNotYYYYMMDDAreIgnored() {
        let validDay = photos(day: 30, count: 30)
        let malformed = ["not-a-date", "2026/01/05", "2026-01"].flatMap { dayKey in
            (0..<30).map { index in
                BigDayFinder.Photo(dayKey: dayKey, date: date(day: 30, hour: 9).addingTimeInterval(Double(index) * 300))
            }
        }

        XCTAssertEqual(BigDayFinder().bigDays(validDay + malformed), [[key(30)]])
    }

    // MARK: - Helpers

    /// `count` photos five minutes apart from `from` o'clock.
    private func photos(day: Int, count: Int, from hour: Double = 9) -> [BigDayFinder.Photo] {
        (0..<count).map { index in
            BigDayFinder.Photo(dayKey: key(day), date: date(day: day, hour: hour + Double(index) / 12))
        }
    }

    private func date(day: Int, hour: Double) -> Date {
        origin.addingTimeInterval(Double(day) * 86_400 + hour * 3_600)
    }

    private func key(_ day: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day], from: date(day: day, hour: 12))
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
}
