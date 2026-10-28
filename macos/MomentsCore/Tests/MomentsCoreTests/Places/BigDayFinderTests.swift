import Foundation
import XCTest
@testable import MomentsCore

final class BigDayFinderTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01

    func testADayWithFarMorePhotosThanUsualIsBig() {
        let usual = (0..<60).flatMap { photos(day: $0, count: 4) }
        let party = photos(day: 30, count: 40, from: 14)
        XCTAssertEqual(BigDayFinder().bigDays(usual + party), [[key(30)]])
    }

    func testBusyStretchesSetTheirOwnUsual() {
        // Someone who takes 30 photos most days: 40 is an ordinary day.
        let busy = (0..<60).flatMap { photos(day: $0, count: 30) }
        let more = photos(day: 30, count: 10, from: 20)
        XCTAssertTrue(BigDayFinder().bigDays(busy + more).isEmpty)
    }

    func testABurstCountsOnce() {
        let usual = (0..<60).flatMap { photos(day: $0, count: 2) }
        let burst = (0..<50).map { BigDayFinder.Photo(dayKey: key(30), date: date(day: 30, hour: 15).addingTimeInterval(Double($0))) }
        XCTAssertTrue(BigDayFinder().bigDays(usual + burst).isEmpty)
    }

    func testBigDaysInARowAreOneEvent() {
        let usual = (0..<60).flatMap { photos(day: $0, count: 3) }
        let wedding = photos(day: 20, count: 30, from: 10) + photos(day: 21, count: 30, from: 10)
        XCTAssertEqual(BigDayFinder().bigDays(usual + wedding), [[key(20), key(21)]])
    }

    // MARK: - Helpers

    /// `count` photos five minutes apart from `from` o'clock.
    private func photos(day: Int, count: Int, from hour: Double = 9) -> [BigDayFinder.Photo] {
        (0..<count).map { BigDayFinder.Photo(dayKey: key(day), date: date(day: day, hour: hour + Double($0) / 12)) }
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
