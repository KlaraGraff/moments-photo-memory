import Foundation
import XCTest
@testable import MomentsCore

/// Quiet gaps far from home: a move between two away places ends a trip only
/// when it is also long next to the way home from both ends.
final class TripSegmenterFarGapTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)
    private let berlin = GeoPoint(latitude: 52.52, longitude: 13.40)
    private let barcelona = GeoPoint(latitude: 41.38, longitude: 2.17)
    private let marseille = GeoPoint(latitude: 43.30, longitude: 5.37)
    private let genoa = GeoPoint(latitude: 44.41, longitude: 8.93)
    private let livorno = GeoPoint(latitude: 43.55, longitude: 10.31)
    private let paris = GeoPoint(latitude: 48.85, longitude: 2.35)
    private let tokyo = GeoPoint(latitude: 35.68, longitude: 139.70)
    private let dresden = GeoPoint(latitude: 51.05, longitude: 13.74)
    private let munich = GeoPoint(latitude: 48.14, longitude: 11.58)
    private let kyoto = GeoPoint(latitude: 35.01, longitude: 135.77)

    /// Marseille to Genoa is 311 km, a move of more than 300 km across a gap
    /// of nearly 48 hours. Both ports are 960 km or more from Berlin, so the
    /// move is much shorter than the way home and the cruise stays one trip.
    func testPortsThreeHundredKilometresApartWithATwoDayGapStayOneTrip() {
        let daily = usualDays(0..<60, skipping: 20..<26)
        let trip = days(20..<21, at: barcelona, prefix: "barcelona")
            + days(21..<22, at: marseille, prefix: "marseille")
            + days(23..<24, at: genoa, prefix: "genoa")
            + days(24..<25, at: livorno, prefix: "livorno")
        let result = TripSegmenter().segment(daily + trip)

        XCTAssertEqual(result.trips, [trip.map(\.id)])
        XCTAssertEqual(result.atUsualPlaceIDs, Set(daily.map(\.id)))
    }

    /// Paris to Tokyo is 9,714 km, far more than half the 878 km from Paris
    /// back to Berlin, so the two days without photos end the first trip.
    func testParisThenTwoDaysWithoutPhotosThenTokyoIsTwoTrips() {
        let daily = usualDays(0..<80, skipping: 30..<40)
        let first = days(30..<34, at: paris, prefix: "paris")
        let second = days(36..<40, at: tokyo, prefix: "tokyo")
        let result = TripSegmenter().segment(daily + first + second)

        XCTAssertEqual(result.trips, [first.map(\.id), second.map(\.id)])
        XCTAssertEqual(result.atUsualPlaceIDs, Set(daily.map(\.id)))
    }

    /// Dresden is 165 km from Berlin and Munich 504 km. The 359 km move
    /// between them is more than half the way home, so it is a trip home in
    /// between and the three days without photos split the two stays.
    func testDresdenThenThreeDaysWithoutPhotosThenMunichIsTwoTrips() {
        let daily = usualDays(0..<80, skipping: 20..<30)
        let first = days(20..<22, at: dresden, prefix: "dresden")
        let second = days(25..<27, at: munich, prefix: "munich")
        let result = TripSegmenter().segment(daily + first + second)

        XCTAssertEqual(result.trips, [first.map(\.id), second.map(\.id)])
        XCTAssertEqual(result.atUsualPlaceIDs, Set(daily.map(\.id)))
    }

    /// Tokyo to Kyoto is 364 km, while both are about 8,800 km from Berlin.
    /// The three-day gap is under the four-day quiet gap and the move is much
    /// shorter than the way home, so the Japan stay stays one trip.
    func testTokyoThenAThreeDayGapThenKyotoIsOneTrip() {
        let daily = usualDays(0..<80, skipping: 20..<30)
        let japan = days(20..<23, at: tokyo, prefix: "tokyo")
            + days(25..<28, at: kyoto, prefix: "kyoto")
        let result = TripSegmenter().segment(daily + japan)

        XCTAssertEqual(result.trips, [japan.map(\.id)])
        XCTAssertEqual(result.atUsualPlaceIDs, Set(daily.map(\.id)))
    }

    // MARK: - Helpers

    /// Six photos in the first half hour after ten in the morning, one set per day.
    private func days(_ range: Range<Int>, at place: GeoPoint, prefix: String) -> [PhotoStop] {
        range.flatMap { (day: Int) -> [PhotoStop] in
            (0..<6).map { (index: Int) -> PhotoStop in
                let minutes: Double = Double(index) * 5
                let hour: Double = 10 + minutes / 60
                return PhotoStop(
                    id: String(format: "%@-%03d-%02d", prefix, day, index),
                    date: date(day: day, hour: hour),
                    coordinate: GeoPoint(
                        latitude: place.latitude + Double(index) * 0.002,
                        longitude: place.longitude
                    )
                )
            }
        }
    }

    private func usualDays(_ range: Range<Int>, skipping skipped: Range<Int> = 0..<0) -> [PhotoStop] {
        range
            .filter { (day: Int) -> Bool in !skipped.contains(day) && day % 3 != 1 }
            .flatMap { (day: Int) -> [PhotoStop] in
                (0..<2).map { (index: Int) -> PhotoStop in
                    PhotoStop(
                        id: String(format: "usual-%03d-%d", day, index),
                        date: date(day: day, hour: 9 + Double(index) * 9),
                        coordinate: GeoPoint(
                            latitude: berlin.latitude + Double(index) * 0.01,
                            longitude: berlin.longitude
                        )
                    )
                }
            }
    }

    private func date(day: Int, hour: Double) -> Date {
        origin.addingTimeInterval(Double(day) * 86_400 + hour * 3_600)
    }
}
