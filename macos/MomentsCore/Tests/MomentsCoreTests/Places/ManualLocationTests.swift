import Foundation
import XCTest
@testable import MomentsCore

/// "Set Location…": the winning hand-set coordinate, same-day suggestions,
/// batch scope and placement in the place tree. All points are synthetic and
/// sit near 0,0.
final class ManualLocationTests: XCTestCase {
    private let noon = Date(timeIntervalSince1970: 1_700_000_000)

    private func point(_ latitude: Double, _ longitude: Double) -> GeoPoint {
        GeoPoint(latitude: latitude, longitude: longitude)
    }

    // MARK: Which coordinate wins

    func testNewestOverrideWinsWhoeverSetIt() {
        let mine = ManualLocation.OverrideCoordinate(accountID: "local-me", point: point(0.01, 0.01), updatedAt: noon)
        let theirs = ManualLocation.OverrideCoordinate(accountID: "partner", point: point(0.02, 0.02), updatedAt: noon.addingTimeInterval(60))
        XCTAssertEqual(ManualLocation.resolved([mine, theirs]), theirs)
        XCTAssertEqual(ManualLocation.resolved([theirs, mine]), theirs)
        XCTAssertNil(ManualLocation.resolved([]))
    }

    func testTieGoesToSmallerAccountIDInAnyOrder() {
        let a = ManualLocation.OverrideCoordinate(accountID: "a", point: point(0.01, 0), updatedAt: noon)
        let b = ManualLocation.OverrideCoordinate(accountID: "b", point: point(0.02, 0), updatedAt: noon)
        XCTAssertEqual(ManualLocation.resolved([a, b]), a)
        XCTAssertEqual(ManualLocation.resolved([b, a]), a)
    }

    func testIndexKeepsNewestPerPhoto() {
        let rows = [
            ManualLocation.OverrideRow(mediaID: "p1", coordinate: .init(accountID: "a", point: point(0.01, 0), updatedAt: noon)),
            ManualLocation.OverrideRow(mediaID: "p1", coordinate: .init(accountID: "b", point: point(0.03, 0), updatedAt: noon.addingTimeInterval(5))),
            ManualLocation.OverrideRow(mediaID: "p2", coordinate: .init(accountID: "a", point: point(0, 0.02), updatedAt: noon)),
        ]
        let index = ManualLocation.index(rows)
        XCTAssertEqual(index.count, 2)
        XCTAssertEqual(index["p1"], point(0.03, 0))
        XCTAssertEqual(index["p2"], point(0, 0.02))
    }

    // MARK: Same-day suggestions

    private func photo(_ id: String, minutes: Double, day: String = "2024-05-01", at location: GeoPoint? = nil) -> ManualLocation.DayPhoto {
        ManualLocation.DayPhoto(id: id, date: noon.addingTimeInterval(minutes * 60), dayKey: day, cameraPoint: location)
    }

    func testSuggestsNearestInTimeWithCameraLocationOnly() {
        let selected = [photo("s", minutes: 0)]
        let candidates = [
            photo("far", minutes: 300, at: point(0.05, 0)),
            photo("near-before", minutes: -12, at: point(0.01, 0)),
            photo("no-gps", minutes: 1),
            photo("near-after", minutes: 40, at: point(0.02, 0)),
            photo("other-day", minutes: 2, day: "2024-05-02", at: point(0.03, 0)),
            photo("s", minutes: 0, at: point(0.04, 0)),
        ]
        let suggestions = ManualLocation.sameDaySuggestions(for: selected, among: candidates)
        XCTAssertEqual(suggestions.map(\.photoID), ["near-before", "near-after", "far"])
        XCTAssertEqual(suggestions[0].interval, -12 * 60)
        XCTAssertEqual(suggestions[1].interval, 40 * 60)
    }

    func testSuggestionsSkipTheSamePlaceTwice() {
        let selected = [photo("s", minutes: 0)]
        let candidates = [
            photo("a", minutes: 5, at: point(0.01, 0)),
            photo("a-again", minutes: 6, at: point(0.01, 0.0001)),
            photo("b", minutes: 30, at: point(0.02, 0)),
        ]
        let ids = ManualLocation.sameDaySuggestions(for: selected, among: candidates).map(\.photoID)
        XCTAssertEqual(ids, ["a", "b"])
    }

    func testSuggestionsMeasureFromTheNearestSelectedPhoto() {
        let selected = [photo("s1", minutes: 0), photo("s2", minutes: 120)]
        let candidates = [
            photo("x", minutes: 110, at: point(0.01, 0)),
            photo("y", minutes: 50, at: point(0.02, 0)),
        ]
        let suggestions = ManualLocation.sameDaySuggestions(for: selected, among: candidates)
        XCTAssertEqual(suggestions.map(\.photoID), ["x", "y"])
        XCTAssertEqual(suggestions[0].interval, -10 * 60)
        XCTAssertEqual(suggestions[1].interval, 50 * 60)
    }

    func testNoSuggestionsWithoutDayOrDateOrLimit() {
        let undated = ManualLocation.DayPhoto(id: "s", date: nil, dayKey: nil, cameraPoint: nil)
        let candidates = [photo("a", minutes: 5, at: point(0.01, 0))]
        XCTAssertTrue(ManualLocation.sameDaySuggestions(for: [undated], among: candidates).isEmpty)
        XCTAssertTrue(ManualLocation.sameDaySuggestions(for: [photo("s", minutes: 0)], among: candidates, limit: 0).isEmpty)
        XCTAssertTrue(ManualLocation.sameDaySuggestions(for: [], among: candidates).isEmpty)
    }

    func testLimitCapsSuggestions() {
        let selected = [photo("s", minutes: 0)]
        let candidates = (1...6).map { photo("c\($0)", minutes: Double($0), at: point(Double($0) * 0.01, 0)) }
        XCTAssertEqual(ManualLocation.sameDaySuggestions(for: selected, among: candidates).count, 3)
    }

    // MARK: Batch scope

    func testBatchSkipsCameraLocatedUnlessAskedForAll() {
        let selected = [
            ManualLocation.Target(id: "a", hasCameraLocation: false),
            ManualLocation.Target(id: "b", hasCameraLocation: true),
            ManualLocation.Target(id: "c", hasCameraLocation: false),
        ]
        XCTAssertEqual(ManualLocation.targets(selected, includingCameraLocated: false), ["a", "c"])
        XCTAssertEqual(ManualLocation.targets(selected, includingCameraLocated: true), ["a", "b", "c"])
    }

    // MARK: Placement

    func testReusesNearestSpotWithinOneKilometre() {
        let places = [
            ManualLocation.ExistingPlace(id: "spot-far", level: .spot, point: point(0.008, 0)),
            ManualLocation.ExistingPlace(id: "spot-near", level: .spot, point: point(0.003, 0)),
            ManualLocation.ExistingPlace(id: "area", level: .area, point: point(0, 0)),
        ]
        XCTAssertEqual(ManualLocation.placement(for: point(0, 0), among: places), .spot(id: "spot-near"))
    }

    func testFallsBackToAreaThenCityThenNew() {
        let target = point(0, 0)
        // About 2 km to the spot, 5 km to the area, 20 km to the city.
        let spot = ManualLocation.ExistingPlace(id: "spot", level: .spot, point: point(0.018, 0))
        let area = ManualLocation.ExistingPlace(id: "area", level: .area, point: point(0.045, 0))
        let city = ManualLocation.ExistingPlace(id: "city", level: .city, point: point(0.18, 0))
        XCTAssertEqual(ManualLocation.placement(for: target, among: [spot, area, city]), .newSpot(areaID: "area"))
        XCTAssertEqual(ManualLocation.placement(for: target, among: [spot, city]), .newArea(cityID: "city"))
        XCTAssertEqual(ManualLocation.placement(for: target, among: [spot]), .newCity)
        XCTAssertEqual(ManualLocation.placement(for: target, among: []), .newCity)
    }

    func testPlacementTieBreaksOnID() {
        let places = [
            ManualLocation.ExistingPlace(id: "b", level: .spot, point: point(0.001, 0)),
            ManualLocation.ExistingPlace(id: "a", level: .spot, point: point(-0.001, 0)),
        ]
        XCTAssertEqual(ManualLocation.placement(for: point(0, 0), among: places), .spot(id: "a"))
    }
}
