import Foundation
import XCTest
@testable import MomentsCore

final class TripSegmenterEdgeCaseTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)
    private let berlin = GeoPoint(latitude: 52.52, longitude: 13.40)
    private let dresden = GeoPoint(latitude: 51.05, longitude: 13.74)
    private let paris = GeoPoint(latitude: 48.85, longitude: 2.35)
    private let london = GeoPoint(latitude: 51.51, longitude: -0.13)
    private let munich = GeoPoint(latitude: 48.14, longitude: 11.58)
    private let hamburg = GeoPoint(latitude: 53.55, longitude: 9.99)
    private let vienna = GeoPoint(latitude: 48.21, longitude: 16.37)

    func testEmptyInputGivesNoTripsAndNoUsualPlaceIDs() {
        let result = TripSegmenter().segment([])

        XCTAssertTrue(result.trips.isEmpty)
        XCTAssertTrue(result.atUsualPlaceIDs.isEmpty)
    }

    func testAFolderHoldingASingleTripKeepsAllFortyPhotosInDateOrder() {
        let photos = (0..<40).map { index in
            PhotoStop(
                id: String(format: "paris-%02d", index),
                date: date(day: 0, hour: 9 + Double(index) * 1.5),
                coordinate: paris
            )
        }
        let result = TripSegmenter().segment(photos)

        XCTAssertEqual(result.trips, [photos.map(\.id)])
        XCTAssertTrue(result.atUsualPlaceIDs.isEmpty)
    }

    func testWithoutAUsualPlaceTwoParisGroupsTwoDaysApartAreTwoTrips() {
        let first = days(0..<2, at: paris, prefix: "paris-first")
        let second = days(3..<5, at: paris, prefix: "paris-second")
        let result = TripSegmenter().segment(first + second)

        XCTAssertEqual(result.trips, [first.map(\.id), second.map(\.id)])
        XCTAssertTrue(result.atUsualPlaceIDs.isEmpty)
    }

    func testAQuietGapOfMoreThanFourDaysStartsANewTripInTheSameCity() {
        let daily = usualDays(0..<60, skipping: 20..<31)
        let first = days(20..<23, at: paris, prefix: "paris-first")
        let second = days(28..<31, at: paris, prefix: "paris-second")
        let result = TripSegmenter().segment(daily + first + second)

        XCTAssertEqual(result.trips, [first.map(\.id), second.map(\.id)])
    }

    func testAFortyHourQuietGapInTheSameFarCityKeepsOneTrip() {
        let daily = usualDays(0..<60, skipping: 20..<26)
        let first = photos("paris-first", startDay: 20, hour: 9, count: 5, stepHours: 2, at: paris)
        let second = photos("paris-second", startDay: 22, hour: 9, count: 5, stepHours: 2, at: paris)
        let result = TripSegmenter().segment(daily + first + second)

        XCTAssertEqual(result.trips, [(first + second).map(\.id)])
    }

    func testAFortyHourQuietGapBetweenFarCitiesStartsANewTrip() {
        let daily = usualDays(0..<60, skipping: 20..<26)
        let first = photos("paris", startDay: 20, hour: 9, count: 5, stepHours: 2, at: paris)
        let second = photos("vienna", startDay: 22, hour: 9, count: 5, stepHours: 2, at: vienna)
        let result = TripSegmenter().segment(daily + first + second)

        XCTAssertEqual(result.trips, [first.map(\.id), second.map(\.id)])
    }

    func testAFixedUsualPlaceTurnsItsOwnCityIntoDailyLifeAndOtherCitiesIntoAway() {
        var segmenter = TripSegmenter()
        segmenter.fixedUsualPlace = paris
        let home = days(0..<3, at: paris, prefix: "paris")
        let away = days(10..<13, at: berlin, prefix: "berlin")
        let result = segmenter.segment(home + away)

        XCTAssertEqual(result.trips, [away.map(\.id)])
        XCTAssertEqual(result.atUsualPlaceIDs, Set(home.map(\.id)))
    }

    func testAwayStretchesNeedFivePhotosOrTwentyHoursToBeATrip() {
        let daily = usualDays(0..<25) + usualDays(26..<35) + usualDays(36..<45) + usualDays(47..<60)
        let four = photos("four", startDay: 25, hour: 14, count: 4, stepHours: 1, at: dresden)
        let five = photos("five", startDay: 35, hour: 14, count: 5, stepHours: 1, at: dresden)
        let overnight = photos("overnight", startDay: 45, hour: 14, count: 2, stepHours: 21, at: dresden)
        let result = TripSegmenter().segment(daily + four + five + overnight)

        XCTAssertEqual(result.trips, [five.map(\.id), overnight.map(\.id)])
        XCTAssertEqual(result.atUsualPlaceIDs, Set(daily.map(\.id) + four.map(\.id)))
    }

    func testAPhotoWithoutALocationFollowsATripPhotoButADistantOneIsDailyLife() {
        let daily = usualDays(0..<60, skipping: 20..<23)
        let trip = days(20..<23, at: paris, prefix: "paris")
        let boardingPass = PhotoStop(id: "boarding-pass", date: date(day: 23, hour: 1.5))
        let nearTrip = TripSegmenter().segment(daily + trip + [boardingPass])
        XCTAssertEqual(nearTrip.trips, [trip.map(\.id) + ["boarding-pass"]])

        let quiet = usualDays(0..<60, skipping: 25..<28)
        let strays = (0..<5).map { index in
            PhotoStop(id: "stray-\(index)", date: date(day: 25, hour: 12 + Double(index) * 6))
        }
        let defaultResult = TripSegmenter().segment(quiet + strays)
        XCTAssertTrue(defaultResult.trips.isEmpty)
        XCTAssertTrue(defaultResult.atUsualPlaceIDs.isSuperset(of: Set(strays.map(\.id))))

        var alwaysAway = TripSegmenter()
        alwaysAway.locationlessDefaultsToAway = true
        let awayResult = alwaysAway.segment(quiet + strays)
        XCTAssertEqual(awayResult.trips, [strays.map(\.id)])
        XCTAssertEqual(awayResult.atUsualPlaceIDs, Set(quiet.map(\.id)))
    }

    func testContextTellsTheUsualPlaceWithoutLeakingContextIDs() {
        let context = usualDays(0..<60, skipping: 30..<33)
        let trip = days(30..<33, at: paris, prefix: "paris")
        let result = TripSegmenter().segment(trip, context: context)

        XCTAssertEqual(result.trips, [trip.map(\.id)])
        XCTAssertTrue(result.atUsualPlaceIDs.isEmpty)
        let contextIDs = Set(context.map(\.id))
        XCTAssertTrue(result.atUsualPlaceIDs.isDisjoint(with: contextIDs))
        XCTAssertTrue(Set(result.trips.flatMap { $0 }).isDisjoint(with: contextIDs))
    }

    func testAFewNewPhotosNextToATripInContextStayATrip() {
        let context = usualDays(0..<60, skipping: 30..<34) + days(30..<33, at: paris, prefix: "paris")
        let fresh = [
            PhotoStop(id: "fresh-1", date: date(day: 33, hour: 5.5), coordinate: paris),
            PhotoStop(id: "fresh-2", date: date(day: 33, hour: 6.5), coordinate: paris),
        ]
        let result = TripSegmenter().segment(fresh, context: context)

        XCTAssertEqual(result.trips, [["fresh-1", "fresh-2"]])
        XCTAssertTrue(result.atUsualPlaceIDs.isEmpty)
    }

    func testTheUsualPlaceFollowsAMoveFromBerlinToMunich() {
        let before = usualDays(0..<200)
        let after = days(200..<400, at: munich, prefix: "munich", perDay: 2)
        let result = TripSegmenter().segment(before + after)

        XCTAssertTrue(result.atUsualPlaceIDs.contains("munich-350-00"))
    }

    func testAlternatingWeeksBetweenTwoUsualPlacesProduceNoTrip() {
        let photos = (0..<200).flatMap { day -> [PhotoStop] in
            let place = (day / 7) % 2 == 0 ? berlin : hamburg
            return (0..<2).map { index in
                PhotoStop(
                    id: String(format: "alternating-%03d-%d", day, index),
                    date: date(day: day, hour: 9 + Double(index) * 9),
                    coordinate: place
                )
            }
        }
        let result = TripSegmenter().segment(photos)

        XCTAssertTrue(result.trips.isEmpty)
        XCTAssertEqual(result.atUsualPlaceIDs, Set(photos.map(\.id)))
    }

    func testShufflingTheInputOrderGivesTheSameResult() {
        let library = usualDays(0..<90, skipping: 30..<36)
            + days(30..<33, at: paris, prefix: "paris")
            + days(33..<36, at: vienna, prefix: "vienna")
            + days(60..<63, at: london, prefix: "london")
        var generator = SplitMix64(seed: 42)

        let original = TripSegmenter().segment(library)
        let shuffled = TripSegmenter().segment(generator.shuffle(library))

        XCTAssertEqual(shuffled, original)
    }

    func testEveryIDAppearsExactlyOnceAcrossTripsAndUsualPlaceIDs() {
        for seed in 1...10 {
            var generator = SplitMix64(seed: UInt64(seed) * 1_000)
            let library = randomLibrary(using: &generator)
            let result = TripSegmenter().segment(library)

            let ids = library.map(\.id)
            XCTAssertEqual(Set(ids).count, ids.count, "seed \(seed): duplicate ids in the generated library")
            let tripIDs = result.trips.flatMap { $0 }
            XCTAssertEqual(Set(tripIDs).count, tripIDs.count, "seed \(seed): an id appears in two trips")
            XCTAssertEqual(Set(tripIDs).union(result.atUsualPlaceIDs), Set(ids), "seed \(seed): ids not partitioned")
        }
    }

    // MARK: - Helpers

    private func randomLibrary(using generator: inout SplitMix64) -> [PhotoStop] {
        let cities = [berlin, dresden, paris, london, munich, hamburg, vienna]
        let count = 20 + Int(generator.next() % 100)
        return (0..<count).map { index in
            let city = cities[Int(generator.next() % UInt64(cities.count))]
            let day = Int(generator.next() % 120)
            let hour = Double(generator.next() % 24)
            let coordinate = generator.next() % 10 == 0
                ? nil
                : GeoPoint(latitude: city.latitude + Double(generator.next() % 20) * 0.002, longitude: city.longitude)
            return PhotoStop(id: "random-\(index)", date: date(day: day, hour: hour), coordinate: coordinate)
        }
    }

    private struct SplitMix64 {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }

        mutating func shuffle<T>(_ items: [T]) -> [T] {
            var result = items
            for index in stride(from: result.count - 1, through: 1, by: -1) {
                let other = Int(next() % UInt64(index + 1))
                result.swapAt(index, other)
            }
            return result
        }
    }

    private func photos(
        _ prefix: String,
        startDay: Int,
        hour: Double,
        count: Int,
        stepHours: Double,
        at place: GeoPoint
    ) -> [PhotoStop] {
        (0..<count).map { index in
            PhotoStop(
                id: String(format: "%@-%02d", prefix, index),
                date: date(day: startDay, hour: hour + Double(index) * stepHours),
                coordinate: place
            )
        }
    }

    private func usualDays(_ range: Range<Int>, skipping skipped: Range<Int> = 0..<0) -> [PhotoStop] {
        range.filter { !skipped.contains($0) && $0 % 3 != 1 }.flatMap { day in
            (0..<2).map { index in
                PhotoStop(
                    id: String(format: "usual-%03d-%d", day, index),
                    date: date(day: day, hour: 9 + Double(index) * 9),
                    coordinate: GeoPoint(latitude: berlin.latitude + Double(index) * 0.01, longitude: berlin.longitude)
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
