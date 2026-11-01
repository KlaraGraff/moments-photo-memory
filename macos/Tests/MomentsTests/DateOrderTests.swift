import Foundation
import XCTest
@testable import Moments

/// The helpers that replace Foundation's `Date.>=` and `Date.<=`, which some
/// macOS 27.2 seed builds lack (see `Design/DateOrder.swift`).
final class DateOrderTests: XCTestCase {
    // MARK: Earlier, equal and later dates

    func testIsOnOrAfterWithEarlierEqualAndLaterDates() {
        let earlier: Date = Date(timeIntervalSinceReferenceDate: 100)
        let equal: Date = Date(timeIntervalSinceReferenceDate: 100)
        let later: Date = Date(timeIntervalSinceReferenceDate: 200)

        XCTAssertFalse(earlier.isOnOrAfter(later), "An earlier date is not on or after a later one.")
        XCTAssertTrue(equal.isOnOrAfter(earlier), "A date is on or after itself.")
        XCTAssertTrue(later.isOnOrAfter(equal), "A later date is on or after an earlier one.")
    }

    func testIsOnOrBeforeWithEarlierEqualAndLaterDates() {
        let earlier: Date = Date(timeIntervalSinceReferenceDate: 100)
        let equal: Date = Date(timeIntervalSinceReferenceDate: 100)
        let later: Date = Date(timeIntervalSinceReferenceDate: 200)

        XCTAssertTrue(earlier.isOnOrBefore(later), "An earlier date is on or before a later one.")
        XCTAssertTrue(equal.isOnOrBefore(earlier), "A date is on or before itself.")
        XCTAssertFalse(later.isOnOrBefore(equal), "A later date is not on or before an earlier one.")
    }

    // MARK: The same answers as the negated `<` comparisons

    func testHelpersMatchNegatedLessThanOverTwentyDates() {
        let dates: [Date] = (0..<20).map { (index: Int) -> Date in
            let seconds: Double = Double(index) * 1.5
            return Date(timeIntervalSinceReferenceDate: seconds)
        }

        var wrongAfter: [String] = []
        var wrongBefore: [String] = []
        for left in dates {
            for right in dates {
                let expectedAfter: Bool = !(left < right)
                let expectedBefore: Bool = !(right < left)
                if left.isOnOrAfter(right) != expectedAfter {
                    wrongAfter.append("\(left.timeIntervalSinceReferenceDate) vs \(right.timeIntervalSinceReferenceDate)")
                }
                if left.isOnOrBefore(right) != expectedBefore {
                    wrongBefore.append("\(left.timeIntervalSinceReferenceDate) vs \(right.timeIntervalSinceReferenceDate)")
                }
            }
        }

        XCTAssertTrue(wrongAfter.isEmpty, "isOnOrAfter must equal !(a < b), but these pairs differ: \(wrongAfter)")
        XCTAssertTrue(wrongBefore.isEmpty, "isOnOrBefore must equal !(b < a), but these pairs differ: \(wrongBefore)")
    }
}
