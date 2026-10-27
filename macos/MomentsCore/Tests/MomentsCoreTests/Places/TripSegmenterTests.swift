import Foundation
import XCTest
@testable import MomentsCore

final class TripSegmenterTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)
    private let home = GeoPoint(latitude: 52.52, longitude: 13.40)
    private let paris = GeoPoint(latitude: 48.85, longitude: 2.35)
    private let rome = GeoPoint(latitude: 41.90, longitude: 12.50)
    private let tokyo = GeoPoint(latitude: 35.68, longitude: 139.70)
    private let leipzig = GeoPoint(latitude: 51.34, longitude: 12.37)
    private let potsdam = GeoPoint(latitude: 52.40, longitude: 13.06)

    func testDailyLifeIsNotATripAndTheTripIsFoundWhole() {
        let daily = homeDays(0..<60, skipping: 30..<35)
        let trip = days(30..<35, at: paris, prefix: "paris")
        let result = TripSegmenter().segment(daily + trip)

        XCTAssertEqual(result.trips, [trip.map(\.id)])
        XCTAssertEqual(result.homeIDs, Set(daily.map(\.id)))
    }

    func testPhotosWithoutLocationFollowTheNearestPhoto() {
        let daily = homeDays(0..<60, skipping: 30..<33)
        let boardingPass = PhotoStop(id: "boarding-pass", date: date(day: 30, hour: 7))
        let homeScreenshot = PhotoStop(id: "home-screenshot", date: date(day: 40, hour: 13))
        let trip = days(30..<33, at: paris, prefix: "paris")
        let result = TripSegmenter().segment(daily + trip + [boardingPass, homeScreenshot])

        XCTAssertEqual(result.trips.count, 1)
        XCTAssertEqual(result.trips.first?.first, "boarding-pass")
        XCTAssertTrue(result.homeIDs.contains("home-screenshot"))
    }

    func testWeekendInANearbyCityIsATrip() {
        let daily = homeDays(0..<60, skipping: 20..<22)
        let trip = days(20..<22, at: leipzig, prefix: "leipzig")
        let result = TripSegmenter().segment(daily + trip)

        XCTAssertEqual(result.trips, [trip.map(\.id)])
    }

    func testAnOutingNextToHomeIsDailyLife() {
        let daily = homeDays(0..<60, skipping: 20..<21)
        let outing = days(20..<21, at: potsdam, prefix: "potsdam")
        let result = TripSegmenter().segment(daily + outing)

        XCTAssertTrue(result.trips.isEmpty)
    }

    func testAFewPhotosAwayForAnAfternoonAreNoTrip() {
        let daily = homeDays(0..<60)
        let detour = [
            PhotoStop(id: "detour-1", date: date(day: 25, hour: 23), coordinate: leipzig),
            PhotoStop(id: "detour-2", date: date(day: 25, hour: 23.5), coordinate: leipzig)
        ]
        let result = TripSegmenter().segment(daily + detour)

        XCTAssertTrue(result.trips.isEmpty)
        XCTAssertTrue(result.homeIDs.isSuperset(of: ["detour-1", "detour-2"]))
    }

    func testCitiesVisitedInARowAreOneTrip() {
        let daily = homeDays(0..<60, skipping: 30..<36)
        let trip = days(30..<33, at: paris, prefix: "paris") + days(33..<36, at: rome, prefix: "rome")
        let result = TripSegmenter().segment(daily + trip)

        XCTAssertEqual(result.trips, [trip.map(\.id)])
    }

    func testTripsWithNoPhotosAtHomeBetweenThemStaySeparate() {
        let daily = homeDays(0..<80, skipping: 30..<60)
        let first = days(30..<34, at: paris, prefix: "paris")
        let second = days(36..<40, at: tokyo, prefix: "tokyo")
        let again = days(45..<48, at: paris, prefix: "paris-again")
        let result = TripSegmenter().segment(daily + first + second + again)

        XCTAssertEqual(result.trips, [first.map(\.id), second.map(\.id), again.map(\.id)])
    }

    func testWithoutAHomeEveryPhotoIsAway() {
        let trip = days(0..<4, at: paris, prefix: "paris") + days(10..<12, at: rome, prefix: "rome")
        let result = TripSegmenter().segment(trip)

        XCTAssertEqual(result.trips.count, 2)
        XCTAssertTrue(result.homeIDs.isEmpty)
    }

    func testHomeFollowsAMove() {
        let munich = GeoPoint(latitude: 48.14, longitude: 11.58)
        let before = homeDays(0..<200)
        let after = days(200..<400, at: munich, prefix: "munich", perDay: 2)
        let result = TripSegmenter().segment(before + after)

        XCTAssertTrue(result.trips.allSatisfy { $0.count < 40 }, "\(result.trips.map(\.count))")
    }

    func testLibraryPhotosTellASmallImportWhereHomeIs() {
        let library = homeDays(0..<60, skipping: 40..<43)
        let imported = days(40..<43, at: leipzig, prefix: "leipzig") + homeDays(43..<44)
        let result = TripSegmenter().segment(imported, context: library)

        XCTAssertEqual(result.trips, [imported.filter { $0.id.hasPrefix("leipzig") }.map(\.id)])
    }

    func testASetHomeWins() {
        var segmenter = TripSegmenter()
        segmenter.homeCoordinate = paris
        let trip = days(0..<4, at: paris, prefix: "paris")
        let result = segmenter.segment(trip)

        XCTAssertTrue(result.trips.isEmpty)
    }

    // MARK: - Helpers

    private func homeDays(_ range: Range<Int>, skipping skipped: Range<Int> = 0..<0) -> [PhotoStop] {
        range.filter { !skipped.contains($0) && $0 % 3 != 1 }.flatMap { day in
            (0..<2).map { index in
                PhotoStop(
                    id: String(format: "home-%03d-%d", day, index),
                    date: date(day: day, hour: 9 + Double(index) * 9),
                    coordinate: GeoPoint(latitude: home.latitude + Double(index) * 0.01, longitude: home.longitude)
                )
            }
        }
    }

    private func days(_ range: Range<Int>, at place: GeoPoint, prefix: String, perDay: Int = 8) -> [PhotoStop] {
        range.flatMap { day in
            (0..<perDay).map { index in
                PhotoStop(
                    id: String(format: "%@-%03d-%02d", prefix, day, index),
                    date: date(day: day, hour: 9 + Double(index) * 12 / Double(perDay)),
                    coordinate: GeoPoint(latitude: place.latitude + Double(index) * 0.002, longitude: place.longitude)
                )
            }
        }
    }

    private func date(day: Int, hour: Double) -> Date {
        origin.addingTimeInterval(Double(day) * 86_400 + hour * 3_600)
    }
}
