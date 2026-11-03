import Foundation
import XCTest
@testable import MomentsCore

/// The context of a regrouping: `TripRegrouping` passes only the photos of
/// suggested trips as `stops` and every other photo, home days included, as
/// `context`. The day maps behind long stays and frequent places must see the
/// whole library, or the first regrouping damages a real library.
final class TripSegmenterContextTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)
    private let berlin = GeoPoint(latitude: 52.52, longitude: 13.40)
    private let tokyo = GeoPoint(latitude: 35.68, longitude: 139.70)
    private let dresden = GeoPoint(latitude: 51.05, longitude: 13.74)
    private let munich = GeoPoint(latitude: 48.14, longitude: 11.58)
    private let hamburg = GeoPoint(latitude: 53.55, longitude: 9.99)

    /// Tokyo on days 1-5 and 21-25 are the stops; home days in between and
    /// 200 days of home on either side are the context. The context home days
    /// must keep the two Tokyo stays from looking like one 25-day stay.
    func testRegroupSeesHomeDaysInContext() {
        let context: [PhotoStop] = homeDays(-200..<1) + homeDays(6..<21) + homeDays(26..<226)
        let firstVisit: [PhotoStop] = days(1..<6, at: tokyo, prefix: "tokyo-1")
        let secondVisit: [PhotoStop] = days(21..<26, at: tokyo, prefix: "tokyo-2")
        let stops: [PhotoStop] = firstVisit + secondVisit
        let result: TripSegmenter.Result = TripSegmenter().segment(stops, context: context)

        XCTAssertEqual(result.trips, [firstVisit.map(\.id), secondVisit.map(\.id)])
        XCTAssertTrue(result.atUsualPlaceIDs.isEmpty, "no new photo is daily life")
    }

    /// A year in A, then a year in B, both dense: a year in one place is where
    /// someone lived, so no part of it is one long trip, whichever year is
    /// regrouped and whichever year is context.
    func testAMoveIsNotATrip() {
        let yearA: [PhotoStop] = days(0..<365, at: munich, prefix: "a", perDay: 10, skipping: [60..<90, 200..<230])
        let yearB: [PhotoStop] = days(365..<730, at: hamburg, prefix: "b", perDay: 10)
        let first: TripSegmenter.Result = TripSegmenter().segment(yearA, context: yearB)
        let second: TripSegmenter.Result = TripSegmenter().segment(yearB, context: yearA)

        XCTAssertTrue(first.trips.isEmpty, "year in A seen with B as context")
        XCTAssertTrue(second.trips.isEmpty, "year in B seen with A as context")
    }

    /// Three Dresden visits of three days each, with no home photos between
    /// them: the quiet gaps alone separate the visits, so the place stays a
    /// frequent place even when the library holds no photo at home in between.
    func testVisitsWithoutGeotaggedHomeDaysStillCount() {
        let library: [PhotoStop] = homeDays(-90..<1)
            + days(10..<13, at: dresden, prefix: "jan")
            + days(100..<103, at: dresden, prefix: "apr")
            + days(220..<223, at: dresden, prefix: "aug")
            + homeDays(250..<340)
        let result: TripSegmenter.Result = TripSegmenter().segment(library)

        XCTAssertEqual(result.trips.count, 3)
        XCTAssertEqual(result.frequentPlaces.count, 1, "one frequent place")
    }

    /// A 90-day stay 600 km away, sparse (1-2 photos on about 30% of its days,
    /// mostly weekends), is daily life, so its photos in the context are no
    /// away photos. Two screenshots without GPS on one of its days copy that
    /// daily life and must not become a trip.
    func testScreenshotsNextToADailyLifeStayInContextStayDaily() {
        let away = GeoPoint(latitude: 47.12, longitude: 13.40)
        let stayDays: [Int] = (0..<90).filter { (day: Int) -> Bool in
            day % 7 == 5 || day % 7 == 6 || day % 10 == 2
        }
        var context: [PhotoStop] = homeDays(-200..<0)
        for (count, day) in stayDays.enumerated() {
            let photos: Int = 1 + count % 2
            for index in 0..<photos {
                context.append(
                    PhotoStop(
                        id: String(format: "stay-%03d-%d", day, index),
                        date: date(day: day, hour: 9 + Double(index) * 9),
                        coordinate: GeoPoint(
                            latitude: away.latitude + Double(index) * 0.01,
                            longitude: away.longitude
                        )
                    )
                )
            }
        }
        context += homeDays(90..<290)
        guard let stayDay = stayDays.first(where: { (day: Int) -> Bool in day % 7 == 6 }) else {
            return XCTFail("the stay holds weekend days")
        }
        let stops: [PhotoStop] = (0..<2).map { (index: Int) -> PhotoStop in
            PhotoStop(
                id: String(format: "screen-%03d-%d", stayDay, index),
                date: date(day: stayDay, hour: 10 + Double(index))
            )
        }
        let result: TripSegmenter.Result = TripSegmenter().segment(stops, context: context)

        XCTAssertTrue(result.trips.isEmpty, "the screenshots copy daily life from the stay")
        XCTAssertEqual(result.atUsualPlaceIDs, Set(stops.map { (stop: PhotoStop) -> String in stop.id }))
    }

    // MARK: - Helpers

    private func homeDays(_ range: Range<Int>) -> [PhotoStop] {
        range.flatMap { (day: Int) -> [PhotoStop] in
            (0..<2).map { (index: Int) -> PhotoStop in
                PhotoStop(
                    id: String(format: "home-%04d-%d", day, index),
                    date: date(day: day, hour: 9 + Double(index) * 9),
                    coordinate: GeoPoint(
                        latitude: berlin.latitude + Double(index) * 0.01,
                        longitude: berlin.longitude
                    )
                )
            }
        }
    }

    private func days(
        _ range: Range<Int>,
        at place: GeoPoint,
        prefix: String,
        perDay: Int = 8,
        skipping skipped: [Range<Int>] = []
    ) -> [PhotoStop] {
        range
            .filter { (day: Int) -> Bool in !skipped.contains(where: { (block: Range<Int>) -> Bool in block.contains(day) }) }
            .flatMap { (day: Int) -> [PhotoStop] in
                (0..<perDay).map { (index: Int) -> PhotoStop in
                    PhotoStop(
                        id: String(format: "%@-%03d-%02d", prefix, day, index),
                        date: date(day: day, hour: 8 + Double(index) * 14 / Double(perDay)),
                        coordinate: GeoPoint(
                            latitude: place.latitude + Double(index) * 0.002,
                            longitude: place.longitude
                        )
                    )
                }
            }
    }

    private func date(day: Int, hour: Double) -> Date {
        origin.addingTimeInterval(Double(day) * 86_400 + hour * 3_600)
    }
}
