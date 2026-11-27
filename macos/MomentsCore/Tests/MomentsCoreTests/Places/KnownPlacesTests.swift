import Foundation
import XCTest
@testable import MomentsCore

/// The places a person names (`KnownPlaceBook`) and the places the photos
/// call home (`TripSegmenter.homeCandidates`). All places are synthetic.
final class KnownPlacesTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let home = GeoPoint(latitude: 31.23, longitude: 121.47)
    private let away = GeoPoint(latitude: 31.63, longitude: -8.01)

    /// A photo at `place` at noon on `day`, plus a few more that afternoon.
    private func photos(_ place: GeoPoint, days: Range<Int>, perDay: Int, tag: String) -> [PhotoStop] {
        days.flatMap { day in
            (0..<perDay).map { index in
                PhotoStop(
                    id: "\(tag)-\(day)-\(index)",
                    date: start.addingTimeInterval(Double(day) * 86_400 + 43_200 + Double(index) * 900),
                    coordinate: GeoPoint(latitude: place.latitude + Double(index) * 0.001, longitude: place.longitude)
                )
            }
        }
    }

    /// A year at home, photographed every other day, with one stretch away.
    private func library(awayDays: Range<Int>, awayPerDay: Int) -> [PhotoStop] {
        let homeDays = (0..<365).filter { $0 % 2 == 0 && !awayDays.contains($0) && !awayDays.contains($0 - 1) }
        let atHome = homeDays.flatMap { photos(home, days: $0..<($0 + 1), perDay: 2, tag: "home") }
        return atHome + photos(away, days: awayDays, perDay: awayPerDay, tag: "away")
    }

    // MARK: Known places in the trip finder

    func testShortVisitToKnownPlaceIsNoTrip() {
        let stops = library(awayDays: 200..<204, awayPerDay: 8)
        XCTAssertEqual(TripSegmenter().segment(stops).trips.count, 1)

        var segmenter = TripSegmenter()
        segmenter.knownPlaces = [away]
        let result = segmenter.segment(stops)
        XCTAssertTrue(result.trips.isEmpty)
        XCTAssertTrue(stops.allSatisfy { result.atUsualPlaceIDs.contains($0.id) })
    }

    func testLongBusyStayAtKnownPlaceIsNoTrip() {
        // Three busy weeks away read as one long trip, unless the person
        // named the place.
        let stops = library(awayDays: 150..<172, awayPerDay: 10)
        XCTAssertEqual(TripSegmenter().segment(stops).trips.count, 1)

        var segmenter = TripSegmenter()
        segmenter.knownPlaces = [away]
        XCTAssertTrue(segmenter.segment(stops).trips.isEmpty)
    }

    func testKnownPlaceFarAwayChangesNothing() {
        let stops = library(awayDays: 200..<204, awayPerDay: 8)
        var segmenter = TripSegmenter()
        segmenter.knownPlaces = [GeoPoint(latitude: 48.85, longitude: 2.35)]
        XCTAssertEqual(segmenter.segment(stops).trips, TripSegmenter().segment(stops).trips)
    }

    func testBookAppliesPlacesAndStayLength() {
        var book = KnownPlaceBook()
        book.add(KnownPlace(name: "Away", role: .notTrip, centre: away, addedAt: start))
        book.setLivedThereDays(45)
        var segmenter = TripSegmenter()
        book.apply(to: &segmenter)
        XCTAssertEqual(segmenter.knownPlaces, [away])
        XCTAssertEqual(segmenter.livedThereDays, 45)
    }

    // MARK: Candidates

    func testCandidatesOfWorkSitesLibrary() {
        let scenario = SyntheticLibrary.workAbroadScenarios(seed: 1)[1]
        let candidates = TripSegmenter().homeCandidates(scenario.photos.map(\.stop))
        let laayoune = GeoPoint(latitude: 27.15, longitude: -13.20)
        let seville = GeoPoint(latitude: 37.39, longitude: -5.98)
        // The current site is home; the holiday is no candidate.
        let current = candidates.first { $0.centre.distance(to: laayoune) < 25_000 }
        XCTAssertEqual(current?.suggestedRole, .home)
        XCTAssertEqual(current?.isCurrent, true)
        XCTAssertFalse(candidates.contains { $0.centre.distance(to: seville) < 50_000 })
        // Each earlier site the person lived at is offered too.
        let earlier = [
            GeoPoint(latitude: 34.26, longitude: -6.58),
            GeoPoint(latitude: 33.11, longitude: -8.63),
            GeoPoint(latitude: 35.76, longitude: -5.83),
        ]
        for site in earlier {
            let candidate = candidates.first { $0.centre.distance(to: site) < 25_000 }
            XCTAssertNotNil(candidate, "\(site)")
            XCTAssertEqual(candidate?.isCurrent, false)
        }
    }

    func testCandidatesFindHomeTown() {
        let scenario = SyntheticLibrary.workAbroadScenarios(seed: 1)[0]
        let candidates = TripSegmenter().homeCandidates(scenario.photos.map(\.stop))
        let shanghai = GeoPoint(latitude: 31.23, longitude: 121.47)
        let kenitra = GeoPoint(latitude: 34.26, longitude: -6.58)
        let town = candidates.first { $0.centre.distance(to: shanghai) < 25_000 }
        XCTAssertEqual(town?.suggestedRole, .homeTown)
        XCTAssertEqual(town?.visits, 2)
        XCTAssertEqual(candidates.first { $0.centre.distance(to: kenitra) < 25_000 }?.suggestedRole, .home)
        // No layover and no holiday is a candidate.
        XCTAssertEqual(candidates.count, 2)
    }

    func testCandidatesIgnoreKnownPlacesInTheSearch() {
        let stops = library(awayDays: 200..<204, awayPerDay: 8)
        var segmenter = TripSegmenter()
        segmenter.knownPlaces = [away]
        // A place named only by the person is not offered back as found.
        XCTAssertFalse(segmenter.homeCandidates(stops).contains { $0.centre.distance(to: away) < 25_000 })
        XCTAssertTrue(segmenter.homeCandidates(stops).contains { $0.centre.distance(to: home) < 25_000 })
    }

    func testNoCandidatesWithoutLocations() {
        let stops = (0..<30).map { PhotoStop(id: "\($0)", date: start.addingTimeInterval(Double($0) * 86_400)) }
        XCTAssertTrue(TripSegmenter().homeCandidates(stops).isEmpty)
        XCTAssertTrue(TripSegmenter().homeCandidates([]).isEmpty)
    }

    // MARK: The book

    private func candidate(at point: GeoPoint, current: Bool = true) -> HomeCandidate {
        HomeCandidate(
            centre: point,
            firstDate: start,
            lastDate: start.addingTimeInterval(86_400 * 100),
            photoDays: 50,
            recentPhotoDays: 50,
            visits: 1,
            isCurrent: current,
            suggestedRole: .home,
            photoIDs: []
        )
    }

    func testConfirmingAndDecliningCandidates() {
        var book = KnownPlaceBook()
        let first = candidate(at: home)
        let second = candidate(at: away, current: false)
        XCTAssertEqual(book.open([first, second]).count, 2)

        let place = book.confirm(first, name: "Home", role: .work, now: start)
        XCTAssertEqual(place.role, .work)
        XCTAssertNil(place.until)
        XCTAssertEqual(place.since, start)
        book.decline(second.centre)
        XCTAssertTrue(book.open([first, second]).isEmpty)

        // Confirming a place a few km off renames the same place.
        let near = candidate(at: GeoPoint(latitude: home.latitude + 0.05, longitude: home.longitude))
        book.confirm(near, name: "Home again", role: .home, now: start)
        XCTAssertEqual(book.places.count, 1)
        XCTAssertEqual(book.places[0].name, "Home again")
        XCTAssertEqual(book.places[0].role, .home)

        // Naming a declined place takes it off the declined list.
        book.add(KnownPlace(name: "Away", role: .formerWork, centre: away, addedAt: start))
        XCTAssertFalse(book.isDeclined(away))
        let confirmed = book.confirm(candidate(at: away, current: false), name: "Away", role: .formerWork, now: start)
        XCTAssertEqual(confirmed.role, .formerWork)
    }

    func testAskedCandidatesAreNotAskedAgain() {
        var book = KnownPlaceBook()
        let first = candidate(at: home)
        book.markAsked([first.centre])
        book.markAsked([first.centre])
        XCTAssertEqual(book.asked.count, 1)
        XCTAssertTrue(book.unasked([first]).isEmpty)
        // Still open in Settings until answered.
        XCTAssertEqual(book.open([first]).count, 1)
    }

    func testRememberNotTripKeepsANamedPlace() {
        var book = KnownPlaceBook()
        book.add(KnownPlace(name: "Town", role: .homeTown, centre: home, addedAt: start))
        let kept = book.rememberNotTrip(name: "Somewhere", centre: home, now: start)
        XCTAssertEqual(kept.role, .homeTown)
        XCTAssertEqual(book.places.count, 1)
        let added = book.rememberNotTrip(name: "Marrakech", centre: away, now: start)
        XCTAssertEqual(added.role, .notTrip)
        XCTAssertEqual(book.places.count, 2)
        book.remove(added.id)
        XCTAssertEqual(book.places.map(\.name), ["Town"])
        book.setRole(.formerWork, of: book.places[0].id)
        XCTAssertEqual(book.places[0].role, .formerWork)
    }

    func testStayLengthIsClampedAndDefaultIsNotStored() {
        var book = KnownPlaceBook()
        XCTAssertEqual(book.effectiveLivedThereDays, 30)
        book.setLivedThereDays(3)
        XCTAssertEqual(book.livedThereDays, 7)
        book.setLivedThereDays(1_000)
        XCTAssertEqual(book.livedThereDays, 365)
        book.setLivedThereDays(30)
        XCTAssertNil(book.livedThereDays)
    }

    func testStorageRoundTrip() {
        var book = KnownPlaceBook()
        book.add(KnownPlace(id: "a", name: "成都", role: .homeTown, centre: home, since: start, addedAt: start))
        book.decline(away)
        book.markAsked([home])
        book.setLivedThereDays(40)
        XCTAssertEqual(KnownPlaceBook.decode(book.encoded()), book)
        XCTAssertEqual(KnownPlaceBook.decode(nil), KnownPlaceBook())
        XCTAssertEqual(KnownPlaceBook.decode("not json"), KnownPlaceBook())
    }
}
