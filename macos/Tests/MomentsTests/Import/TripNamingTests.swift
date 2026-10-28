import Foundation
import XCTest
@testable import Moments

final class TripNamingTests: XCTestCase {
    private let start = ISO8601DateFormatter().date(from: "2026-08-20T10:00:00Z")!

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func testUpToThreeCitiesAreNamedInVisitingOrder() {
        let name = TripNaming.name(
            cities: ["Shanghai", "Chongqing", "Shanghai", "Wulong"],
            countries: ["China"],
            start: start, index: 1, locale: Locale(identifier: "en_US"), calendar: utc
        )
        XCTAssertEqual(name, "Shanghai · Chongqing · Wulong August 2026")
    }

    func testALongTripInOneCountryIsNamedAfterTheCountry() {
        let name = TripNaming.name(
            cities: ["Casablanca", "Fes", "Merzouga", "Tinghir", "Marrakesh"],
            countries: ["摩洛哥", "摩洛哥"],
            start: start, index: 1, locale: Locale(identifier: "zh_Hans_CN"), calendar: utc
        )
        XCTAssertEqual(name, "摩洛哥 2026年8月")
    }

    func testWithoutPlacesTheMonthStillNamesTheTrip() {
        let name = TripNaming.name(cities: [], countries: [], start: start, index: 1, locale: Locale(identifier: "en_US"), calendar: utc)
        XCTAssertTrue(name.hasSuffix(" August 2026"), name)
        XCTAssertFalse(name.contains("2026-08-20"))
    }

    func testOnlyTheOldDateNamesAreRecognised() {
        XCTAssertTrue(TripNaming.isOldDefaultName("Trip 2026-08-20"))
        XCTAssertTrue(TripNaming.isOldDefaultName("旅程 2026-04-21"))
        XCTAssertTrue(TripNaming.isOldDefaultName("Reise 2026-04-21"))
        XCTAssertFalse(TripNaming.isOldDefaultName("Honeymoon 2026-08-20"))
        XCTAssertFalse(TripNaming.isOldDefaultName("Trip 2"))
    }

    func testNamesWithoutPlacesAreRecognisedInEveryLanguage() {
        XCTAssertTrue(TripNaming.isPlacelessDefaultName("Trip August 2026"))
        XCTAssertTrue(TripNaming.isPlacelessDefaultName("旅程 2026年8月"))
        XCTAssertTrue(TripNaming.isPlacelessDefaultName("Reise März 2026"))
        XCTAssertTrue(TripNaming.isPlacelessDefaultName("Trip 2026-08-20"))
        XCTAssertTrue(TripNaming.isPlacelessDefaultName("Trip 3"))
        XCTAssertTrue(TripNaming.isPlacelessDefaultName("Trip July 2026"), "the dates may have moved since")
        XCTAssertFalse(TripNaming.isPlacelessDefaultName("Lisbon August 2026"))
        XCTAssertFalse(TripNaming.isPlacelessDefaultName("Trip to Lisbon 2026"))
    }

    func testTheMonthPartIsWhatTheNameFunctionWrites() {
        for identifier in ["en_US", "de_DE", "zh_Hans_CN"] {
            let name = TripNaming.name(cities: [], countries: [], start: start, index: 1, locale: Locale(identifier: identifier), calendar: utc)
            let month = TripNaming.month(start, locale: Locale(identifier: identifier), calendar: utc)
            for word in ["Trip", "旅程", "Reise"] {
                XCTAssertTrue(TripNaming.isPlacelessDefaultName(word + " " + month), "\(identifier): \(month)")
            }
            XCTAssertTrue(name.hasSuffix(month))
        }
    }
}
