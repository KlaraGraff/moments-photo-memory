import Foundation
import XCTest
@testable import MomentsCore

/// One line per scenario, in a fixed format, so the experiments that each
/// change one point of trip grouping can be compared: pairwise F1 of the trip
/// groups and the share of photos placed on the right side of "trip or daily
/// life", plus the pairwise F1 of the frequent-place photo groups.
final class RouteScoreboardTests: XCTestCase {
    private struct Line {
        let suite: String
        let name: String
        let pairF1: Double
        let agreement: Double
    }

    func testScoreboard() {
        var lines: [Line] = []
        lines += score(basicScenarios(), suite: "basic")
        lines += score(hardScenarios(), suite: "hard")
        let places: [SyntheticPlaceScenario] = SyntheticLibrary.placeScenarios()
        lines += score(places.map { (entry: SyntheticPlaceScenario) -> SyntheticScenario in entry.scenario }, suite: "place")
        lines += score(SyntheticLibrary.longStayScenarios(), suite: "longstay")

        var frequentScores: [Double] = []
        for entry in places {
            let scenario: SyntheticScenario = entry.scenario
            let ids: [String] = scenario.photos.map { (photo: SyntheticPhoto) -> String in photo.id }
            let stops: [PhotoStop] = scenario.photos.map { (photo: SyntheticPhoto) -> PhotoStop in photo.stop }
            let result: TripSegmenter.Result = TripSegmenter().segment(stops)
            let ordered: [PhotoStop] = stops.sorted { (left: PhotoStop, right: PhotoStop) -> Bool in
                left.date == right.date ? left.id < right.id : left.date < right.date
            }
            let predicted: [[String]] = result.frequentPlaces.map { (group: [Int]) -> [String] in
                group.compactMap { (index: Int) -> String? in
                    ordered.indices.contains(index) ? ordered[index].id : nil
                }
            }
            let truth: [[String]] = entry.truthFrequentPhotoGroups()
            let score: PairwiseScore = AccuracyScoring.pairwise(predicted: predicted, truth: truth, universe: ids)
            frequentScores.append(score.f1)
            print(String(format: "SCORE frequent %@ f1=%.4f", scenario.name, score.f1))
        }

        let tripMean: Double = lines.isEmpty ? 0 : lines.map { (line: Line) -> Double in line.pairF1 }.reduce(0, +) / Double(lines.count)
        let agreementMean: Double = lines.isEmpty ? 0 : lines.map { (line: Line) -> Double in line.agreement }.reduce(0, +) / Double(lines.count)
        let frequentMean: Double = frequentScores.isEmpty ? 0 : frequentScores.reduce(0, +) / Double(frequentScores.count)
        print(String(format: "SCORE total trips=%.4f agreement=%.4f frequent=%.4f", tripMean, agreementMean, frequentMean))
    }


    // MARK: - Focused checks of the frequent-place rule

    private let home = GeoPoint(latitude: 52.52, longitude: 13.40)
    private let away = GeoPoint(latitude: 41.90, longitude: 12.50)
    private let other = GeoPoint(latitude: 35.68, longitude: 139.70)
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    /// Three separate short visits to one far place are one frequent place and
    /// stay three trips.
    func testThreeSeparateVisitsFormOneFrequentPlace() {
        let daily: [PhotoStop] = homeDays(0..<200, skipping: [20..<24, 80..<84, 150..<154])
        let visits: [[PhotoStop]] = [
            visitDays(20..<24, at: away, prefix: "v1"),
            visitDays(80..<84, at: away, prefix: "v2"),
            visitDays(150..<154, at: away, prefix: "v3")
        ]
        let result: TripSegmenter.Result = TripSegmenter().segment(daily + visits.flatMap { $0 })

        XCTAssertEqual(result.trips.count, 3)
        XCTAssertEqual(result.frequentPlaces.count, 1, "one frequent place")
        XCTAssertEqual(result.frequentPlaces.first?.count, 3 * 4 * 8, "every visit photo is in the group")
    }

    /// Two visits are not enough: no frequent place, and the trips stay trips.
    func testTwoVisitsAreNoFrequentPlace() {
        let daily: [PhotoStop] = homeDays(0..<200, skipping: [20..<24, 80..<84])
        let visits: [[PhotoStop]] = [
            visitDays(20..<24, at: away, prefix: "v1"),
            visitDays(80..<84, at: away, prefix: "v2")
        ]
        let result: TripSegmenter.Result = TripSegmenter().segment(daily + visits.flatMap { $0 })

        XCTAssertEqual(result.trips.count, 2)
        XCTAssertTrue(result.frequentPlaces.isEmpty)
        XCTAssertTrue(result.frequentPlaces.isEmpty)
    }

    /// A road trip that spends one night in the place and the rest elsewhere
    /// does not visit it: the night is a pass-through.
    func testARoadTripPassingThroughIsNoVisit() {
        let daily: [PhotoStop] = homeDays(0..<200, skipping: [40..<44, 120..<124, 180..<184])
        let firstTwo: [[PhotoStop]] = [
            visitDays(40..<44, at: away, prefix: "v1"),
            visitDays(120..<124, at: away, prefix: "v2")
        ]
        let road: [PhotoStop] = visitDays(180..<181, at: away, prefix: "road")
            + visitDays(181..<184, at: other, prefix: "road")
        let result: TripSegmenter.Result = TripSegmenter().segment(daily + firstTwo.flatMap { $0 } + road)

        XCTAssertEqual(result.trips.count, 3)
        XCTAssertTrue(result.frequentPlaces.isEmpty)
        XCTAssertTrue(result.frequentPlaces.isEmpty)
    }

    /// A stay of three weeks or more is no visit, even when it is far away and
    /// spends all its days there.
    func testALongStayIsNoVisit() {
        let daily: [PhotoStop] = homeDays(0..<200, skipping: [20..<24, 90..<94, 140..<162])
        let visits: [[PhotoStop]] = [
            visitDays(20..<24, at: away, prefix: "v1"),
            visitDays(90..<94, at: away, prefix: "v2")
        ]
        let stay: [PhotoStop] = visitDays(140..<162, at: away, prefix: "stay")
        let result: TripSegmenter.Result = TripSegmenter().segment(daily + visits.flatMap { $0 } + stay)

        XCTAssertTrue(result.frequentPlaces.isEmpty)
        XCTAssertTrue(result.frequentPlaces.isEmpty)
    }

    /// Three visits spread over more than twelve months are no frequent place:
    /// no three of them fit in one 365-day window.
    func testThreeVisitsOverMoreThanAYearAreNoFrequentPlace() {
        let daily: [PhotoStop] = homeDays(0..<430, skipping: [20..<24, 220..<224, 420..<424])
        let visits: [[PhotoStop]] = [
            visitDays(20..<24, at: away, prefix: "v1"),
            visitDays(220..<224, at: away, prefix: "v2"),
            visitDays(420..<424, at: away, prefix: "v3")
        ]
        let result: TripSegmenter.Result = TripSegmenter().segment(daily + visits.flatMap { $0 })

        XCTAssertTrue(result.frequentPlaces.isEmpty)
        XCTAssertTrue(result.frequentPlaces.isEmpty)
    }

    /// Turning the detection off keeps today's result: the trips alone.
    func testDetectionCanBeTurnedOff() {
        var segmenter = TripSegmenter()
        segmenter.detectsFrequentPlaces = false
        let daily: [PhotoStop] = homeDays(0..<200, skipping: [20..<24, 80..<84, 150..<154])
        let visits: [[PhotoStop]] = [
            visitDays(20..<24, at: away, prefix: "v1"),
            visitDays(80..<84, at: away, prefix: "v2"),
            visitDays(150..<154, at: away, prefix: "v3")
        ]
        let result: TripSegmenter.Result = segmenter.segment(daily + visits.flatMap { $0 })

        XCTAssertEqual(result.trips.count, 3)
        XCTAssertTrue(result.frequentPlaces.isEmpty)
        XCTAssertTrue(result.frequentPlaces.isEmpty)
    }

    private func homeDays(_ range: Range<Int>, skipping skipped: [Range<Int>]) -> [PhotoStop] {
        var stops: [PhotoStop] = []
        for day in range {
            if skipped.contains(where: { (block: Range<Int>) -> Bool in block.contains(day) }) { continue }
            for index in 0..<2 {
                stops.append(PhotoStop(
                    id: String(format: "home-%03d-%d", day, index),
                    date: time(day: day, hour: 9 + Double(index) * 9),
                    coordinate: GeoPoint(latitude: home.latitude + Double(index) * 0.01, longitude: home.longitude)
                ))
            }
        }
        return stops
    }

    private func visitDays(_ range: Range<Int>, at place: GeoPoint, prefix: String) -> [PhotoStop] {
        var stops: [PhotoStop] = []
        for day in range {
            for index in 0..<8 {
                stops.append(PhotoStop(
                    id: String(format: "%@-%03d-%02d", prefix, day, index),
                    date: time(day: day, hour: 9 + Double(index) * 1.5),
                    coordinate: GeoPoint(latitude: place.latitude + Double(index) * 0.002, longitude: place.longitude)
                ))
            }
        }
        return stops
    }

    private func time(day: Int, hour: Double) -> Date {
        origin.addingTimeInterval(Double(day) * 86_400 + hour * 3_600)
    }

    private func basicScenarios() -> [SyntheticScenario] {
        SyntheticLibrary.scenarios()
    }

    private func hardScenarios() -> [SyntheticScenario] {
        SyntheticLibrary.hardScenarios()
    }

    private func score(_ scenarios: [SyntheticScenario], suite: String) -> [Line] {
        var lines: [Line] = []
        for scenario in scenarios {
            let ids: [String] = scenario.photos.map { (photo: SyntheticPhoto) -> String in photo.id }
            let stops: [PhotoStop] = scenario.photos.map { (photo: SyntheticPhoto) -> PhotoStop in photo.stop }
            let trips: [[String]] = TripSegmenter().segment(stops).trips
            let truth: [[String]] = scenario.truthTrips
            let pairF1: Double = AccuracyScoring.pairwise(predicted: trips, truth: truth, universe: ids).f1
            let agreement: Double = AccuracyScoring.membershipAgreement(predicted: trips, truth: truth, universe: ids)
            print(String(format: "SCORE %@ %@ pairF1=%.4f agreement=%.4f", suite, scenario.name, pairF1, agreement))
            lines.append(Line(suite: suite, name: scenario.name, pairF1: pairF1, agreement: agreement))
        }
        return lines
    }
}
