import Foundation
import XCTest
@testable import MomentsCore

/// Synthetic QuickTime values only: coordinates near 0,0 or textbook
/// examples, never a real place history.
final class QuickTimeMetadataTests: XCTestCase {
    // MARK: ISO 6709 location

    func testDecimalDegreesWithAltitude() throws {
        let point = try XCTUnwrap(QuickTimeMetadata.location(iso6709: "+00.0100+000.0200+035.000/"))
        XCTAssertEqual(point.latitude, 0.01, accuracy: 1e-9)
        XCTAssertEqual(point.longitude, 0.02, accuracy: 1e-9)
    }

    func testNegativeHemispheresWithoutAltitude() throws {
        let point = try XCTUnwrap(QuickTimeMetadata.location(iso6709: "-00.5000-001.2500/"))
        XCTAssertEqual(point.latitude, -0.5, accuracy: 1e-9)
        XCTAssertEqual(point.longitude, -1.25, accuracy: 1e-9)
    }

    func testMixedSignsAndCRSSuffix() throws {
        let point = try XCTUnwrap(QuickTimeMetadata.location(iso6709: "+01.5000-002.2500CRSWGS_84/"))
        XCTAssertEqual(point.latitude, 1.5, accuracy: 1e-9)
        XCTAssertEqual(point.longitude, -2.25, accuracy: 1e-9)
    }

    func testDegreesAndMinutes() throws {
        // 1°30' N, 2°15' E.
        let point = try XCTUnwrap(QuickTimeMetadata.location(iso6709: "+0130+00215/"))
        XCTAssertEqual(point.latitude, 1.5, accuracy: 1e-9)
        XCTAssertEqual(point.longitude, 2.25, accuracy: 1e-9)
    }

    func testDegreesMinutesAndSeconds() throws {
        // 0°30'36" S, 1°00'18" W.
        let point = try XCTUnwrap(QuickTimeMetadata.location(iso6709: "-003036-0010018/"))
        XCTAssertEqual(point.latitude, -(30.0 / 60 + 36.0 / 3_600), accuracy: 1e-9)
        XCTAssertEqual(point.longitude, -(1 + 18.0 / 3_600), accuracy: 1e-9)
    }

    func testWhitespaceAroundTheValueIsIgnored() {
        XCTAssertNotNil(QuickTimeMetadata.location(iso6709: "  +00.0100+000.0200/\n"))
    }

    func testMalformedOrOutOfRangeLocationsAreRejected() {
        let rejected = [
            "",
            "/",
            "+00.0100/",                // longitude missing
            "00.0100+000.0200/",        // latitude has no sign
            "+91.0000+000.0000/",       // latitude out of range
            "+00.0000+181.0000/",       // longitude out of range
            "+0160+00000/",             // 60 minutes
            "+00.01.00+000.0200/",      // two decimal points
            "+00.+000.0200/",           // empty fraction
            "+1234567+000.0000/",       // too many digits
            "unknown"
        ]
        for value in rejected {
            XCTAssertNil(QuickTimeMetadata.location(iso6709: value), value)
        }
    }

    // MARK: Creation date

    private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    func testCreationDateWithCompactOffset() throws {
        let parsed = try XCTUnwrap(QuickTimeMetadata.creationDate("2026-01-01T12:34:56+0200"))
        XCTAssertEqual(parsed.offsetMinutes, 120)
        XCTAssertFalse(parsed.isWallClock)
        XCTAssertEqual(parsed.date, utc(2026, 1, 1, 10, 34, 56))
    }

    func testCreationDateWithColonOffsetAndFraction() throws {
        let parsed = try XCTUnwrap(QuickTimeMetadata.creationDate("2026-01-01T00:30:00.500-05:30"))
        XCTAssertEqual(parsed.offsetMinutes, -330)
        XCTAssertEqual(parsed.date.timeIntervalSince1970, utc(2026, 1, 1, 6, 0, 0).timeIntervalSince1970 + 0.5, accuracy: 1e-6)
    }

    func testCreationDateWithHourOnlyOffsetAndSpaceSeparators() throws {
        let parsed = try XCTUnwrap(QuickTimeMetadata.creationDate("2026-01-01 12:00:00 +01"))
        XCTAssertEqual(parsed.offsetMinutes, 60)
        XCTAssertEqual(parsed.date, utc(2026, 1, 1, 11, 0, 0))
    }

    func testZuluNamesTheInstantButNoLocalOffset() throws {
        let parsed = try XCTUnwrap(QuickTimeMetadata.creationDate("2026-01-01T12:00:00Z"))
        XCTAssertNil(parsed.offsetMinutes)
        XCTAssertFalse(parsed.isWallClock)
        XCTAssertEqual(parsed.date, utc(2026, 1, 1, 12, 0, 0))
    }

    func testCreationDateWithoutZoneIsWallClock() throws {
        let parsed = try XCTUnwrap(QuickTimeMetadata.creationDate("2026-01-01T22:30"))
        XCTAssertNil(parsed.offsetMinutes)
        XCTAssertTrue(parsed.isWallClock)
        XCTAssertEqual(parsed.date, utc(2026, 1, 1, 22, 30, 0))
    }

    func testOffsetCanMoveTheDateAcrossMidnight() throws {
        let parsed = try XCTUnwrap(QuickTimeMetadata.creationDate("2026-01-02T01:00:00+0900"))
        XCTAssertEqual(parsed.date, utc(2026, 1, 1, 16, 0, 0))
    }

    func testMalformedCreationDatesAreRejected() {
        let rejected = [
            "",
            "2026-01-01",                   // no time
            "2026-13-01T00:00:00+0000",     // month 13
            "2026-02-31T00:00:00+0000",     // 31 February
            "2026-01-01T24:00:00+0000",     // hour 24
            "2026-01-01T12:00:00+2500",     // offset too large
            "2026-01-01T12:00:00+02:6",     // half an offset
            "2026-01-01T12:00:00 PST",      // a zone name, not an offset
            "2026-01-01T12:00:00.+0200",    // empty fraction
            "26-01-01T12:00:00+0200"
        ]
        for value in rejected {
            XCTAssertNil(QuickTimeMetadata.creationDate(value), value)
        }
    }
}
