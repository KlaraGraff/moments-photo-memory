import Foundation
import XCTest
@testable import MomentsCore

final class TripSegmenterTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)
    private let usual = GeoPoint(latitude: 52.52, longitude: 13.40)
    private let paris = GeoPoint(latitude: 48.85, longitude: 2.35)
    private let rome = GeoPoint(latitude: 41.90, longitude: 12.50)
    private let tokyo = GeoPoint(latitude: 35.68, longitude: 139.70)
    private let leipzig = GeoPoint(latitude: 51.34, longitude: 12.37)
    private let potsdam = GeoPoint(latitude: 52.40, longitude: 13.06)

    func testDailyLifeIsNotATripAndTheTripIsFoundWhole() {
        let daily = usualDays(0..<60, skipping: 30..<35)
        let trip = days(30..<35, at: paris, prefix: "paris")
        let result = TripSegmenter().segment(daily + trip)

        XCTAssertEqual(result.trips, [trip.map(\.id)])
        XCTAssertEqual(result.atUsualPlaceIDs, Set(daily.map(\.id)))
    }

    func testPhotosWithoutLocationFollowTheNearestPhoto() {
        let daily = usualDays(0..<60, skipping: 30..<33)
        let boardingPass = PhotoStop(id: "boarding-pass", date: date(day: 30, hour: 7))
        let usualScreenshot = PhotoStop(id: "usual-screenshot", date: date(day: 40, hour: 13))
        let trip = days(30..<33, at: paris, prefix: "paris")
        let result = TripSegmenter().segment(daily + trip + [boardingPass, usualScreenshot])

        XCTAssertEqual(result.trips.count, 1)
        XCTAssertEqual(result.trips.first?.first, "boarding-pass")
        XCTAssertTrue(result.atUsualPlaceIDs.contains("usual-screenshot"))
    }

    func testWeekendInANearbyCityIsATrip() {
        let daily = usualDays(0..<60, skipping: 20..<22)
        let trip = days(20..<22, at: leipzig, prefix: "leipzig")
        let result = TripSegmenter().segment(daily + trip)

        XCTAssertEqual(result.trips, [trip.map(\.id)])
    }

    func testAnOutingNearAUsualPlaceIsDailyLife() {
        let daily = usualDays(0..<60, skipping: 20..<21)
        let outing = days(20..<21, at: potsdam, prefix: "potsdam")
        let result = TripSegmenter().segment(daily + outing)

        XCTAssertTrue(result.trips.isEmpty)
    }

    func testAFewPhotosAwayForAnAfternoonAreNoTrip() {
        let daily = usualDays(0..<60)
        let detour = [
            PhotoStop(id: "detour-1", date: date(day: 25, hour: 23), coordinate: leipzig),
            PhotoStop(id: "detour-2", date: date(day: 25, hour: 23.5), coordinate: leipzig)
        ]
        let result = TripSegmenter().segment(daily + detour)

        XCTAssertTrue(result.trips.isEmpty)
        XCTAssertTrue(result.atUsualPlaceIDs.isSuperset(of: ["detour-1", "detour-2"]))
    }

    func testCitiesVisitedInARowAreOneTrip() {
        let daily = usualDays(0..<60, skipping: 30..<36)
        let trip = days(30..<33, at: paris, prefix: "paris") + days(33..<36, at: rome, prefix: "rome")
        let result = TripSegmenter().segment(daily + trip)

        XCTAssertEqual(result.trips, [trip.map(\.id)])
    }

    func testTripsWithNoPhotosAtTheUsualPlaceBetweenThemStaySeparate() {
        let daily = usualDays(0..<80, skipping: 30..<60)
        let first = days(30..<34, at: paris, prefix: "paris")
        let second = days(36..<40, at: tokyo, prefix: "tokyo")
        let again = days(45..<48, at: paris, prefix: "paris-again")
        let result = TripSegmenter().segment(daily + first + second + again)

        XCTAssertEqual(result.trips, [first.map(\.id), second.map(\.id), again.map(\.id)])
    }

    func testWithoutAUsualPlaceEveryPhotoIsAway() {
        let trip = days(0..<4, at: paris, prefix: "paris") + days(10..<12, at: rome, prefix: "rome")
        let result = TripSegmenter().segment(trip)

        XCTAssertEqual(result.trips.count, 2)
        XCTAssertTrue(result.atUsualPlaceIDs.isEmpty)
    }

    func testWithoutAUsualPlaceAFewPhotosAreStillATrip() {
        let photos = days(0..<1, at: paris, prefix: "paris", perDay: 2)
        let result = TripSegmenter().segment(photos)

        XCTAssertEqual(result.trips, [photos.map(\.id)])
    }

    func testALongStayAwayIsNeverAUsualPlace() {
        let stay = days(0..<14, at: tokyo, prefix: "tokyo")
        let result = TripSegmenter().segment(stay)

        XCTAssertEqual(result.trips, [stay.map(\.id)])
    }

    func testAFolderWithoutLocationsIsATripEvenWhenTheUsualPlaceIsKnown() {
        let library = usualDays(0..<60, skipping: 40..<43)
        let camera = (40..<43).flatMap { day in
            (0..<6).map { PhotoStop(id: "camera-\(day)-\($0)", date: date(day: day, hour: 9 + Double($0))) }
        }
        var segmenter = TripSegmenter()
        segmenter.locationlessDefaultsToAway = true

        XCTAssertEqual(segmenter.segment(camera, context: library).trips, [camera.map(\.id)])
        XCTAssertTrue(TripSegmenter().segment(camera, context: library).trips.isEmpty, "screenshots in a phone library")
    }

    func testAFewNewPhotosNextToATripInTheLibraryStayATrip() {
        let library = usualDays(0..<60, skipping: 30..<34) + days(30..<33, at: paris, prefix: "paris")
        let fresh = [
            PhotoStop(id: "fresh-1", date: date(day: 33, hour: 10), coordinate: paris),
            PhotoStop(id: "fresh-2", date: date(day: 33, hour: 11), coordinate: paris)
        ]
        let result = TripSegmenter().segment(fresh, context: library)

        XCTAssertEqual(result.trips, [["fresh-1", "fresh-2"]])
    }

    func testTheUsualPlaceFollowsAMove() {
        let munich = GeoPoint(latitude: 48.14, longitude: 11.58)
        let before = usualDays(0..<200)
        let after = days(200..<400, at: munich, prefix: "munich", perDay: 2)
        let result = TripSegmenter().segment(before + after)

        XCTAssertFalse(result.atUsualPlaceIDs.isEmpty)
        XCTAssertTrue(result.trips.isEmpty, "\(result.trips.map(\.count))")
    }

    func testLibraryPhotosTellASmallImportTheUsualPlace() {
        let library = usualDays(0..<60, skipping: 40..<43)
        let imported = days(40..<43, at: leipzig, prefix: "leipzig") + usualDays(43..<44)
        let result = TripSegmenter().segment(imported, context: library)

        XCTAssertEqual(result.trips, [imported.filter { $0.id.hasPrefix("leipzig") }.map(\.id)])
    }

    func testASetPlaceWins() {
        var segmenter = TripSegmenter()
        segmenter.fixedUsualPlace = paris
        let trip = days(0..<4, at: paris, prefix: "paris")
        let result = segmenter.segment(trip)

        XCTAssertTrue(result.trips.isEmpty)
    }

    // MARK: - Helpers

    private func usualDays(_ range: Range<Int>, skipping skipped: Range<Int> = 0..<0) -> [PhotoStop] {
        range.filter { !skipped.contains($0) && $0 % 3 != 1 }.flatMap { day in
            (0..<2).map { index in
                PhotoStop(
                    id: String(format: "usual-%03d-%d", day, index),
                    date: date(day: day, hour: 9 + Double(index) * 9),
                    coordinate: GeoPoint(latitude: usual.latitude + Double(index) * 0.01, longitude: usual.longitude)
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
