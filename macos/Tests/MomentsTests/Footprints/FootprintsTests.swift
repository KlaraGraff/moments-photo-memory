import Foundation
import MomentsCore
import XCTest
@testable import Moments

@MainActor
final class FootprintsTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    func testGlobeDistanceMovesBackForNarrowMaps() {
        let square = FootprintsCameraTarget.globeDistance(fitting: CGSize(width: 600, height: 600))
        let narrow = FootprintsCameraTarget.globeDistance(fitting: CGSize(width: 300, height: 600))
        let wide = FootprintsCameraTarget.globeDistance(fitting: CGSize(width: 1_200, height: 600))
        XCTAssertGreaterThan(narrow, square, "A narrow map needs the camera further back to fit the globe sideways")
        XCTAssertEqual(wide, square, accuracy: 1, "Width beyond the height does not change the fit")
        XCTAssertGreaterThanOrEqual(square, FootprintsCameraTarget.globeDistanceMetres)
        XCTAssertEqual(FootprintsCameraTarget.globeDistance(fitting: .zero), FootprintsCameraTarget.globeDistanceMetres)
    }

    func testStatisticsCountCountriesCitiesAndOverviewKilometres() {
        let paris = cluster(id: "city-paris", stopIDs: ["a", "b"], latitude: 48.8566, longitude: 2.3522)
        let london = cluster(id: "city-london", stopIDs: ["c"], latitude: 51.5074, longitude: -0.1278)
        let snapshot = FootprintsSnapshot(
            cityClusters: [paris, london],
            overviewSegments: [
                RouteSegment(from: paris, to: london, distanceMeters: 343_000)
            ],
            cameraTarget: FootprintsCalculator.cameraTarget(for: [paris, london])
        )
        let statistics = FootprintsCalculator.statistics(
            for: snapshot,
            geocoding: [
                paris.id: FootprintsGeocodeResult(countryCode: "FR", countryName: "France"),
                london.id: FootprintsGeocodeResult(countryCode: "GB", countryName: "United Kingdom")
            ]
        )

        XCTAssertEqual(statistics.countryCount, 2)
        XCTAssertEqual(statistics.cityCount, 2)
        XCTAssertEqual(statistics.kilometres, 343, accuracy: 0.001)
    }

    func testCameraUsesVisitedCentreAndAvoidsPole() {
        let clusters = [
            cluster(id: "north", stopIDs: ["north"], latitude: 82, longitude: 10),
            cluster(id: "south", stopIDs: ["south"], latitude: 78, longitude: 20)
        ]

        let target = FootprintsCalculator.cameraTarget(for: clusters)

        XCTAssertEqual(target.center.longitude, 16, accuracy: 0.5)
        XCTAssertEqual(target.center.latitude, 65, accuracy: 0.001)
        XCTAssertEqual(target.distanceMetres, FootprintsCameraTarget.globeDistanceMetres)
    }

    func testGeocodingCacheAvoidsSecondRequest() async {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("footprints-geocoding-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let fake = CountingGeocoder(result: FootprintsGeocodeResult(countryCode: "MA", countryName: "Morocco"))
        let city = cluster(id: "city", stopIDs: ["photo"], latitude: 35.78, longitude: -5.81)
        let first = FootprintsGeocodeResolver(
            geocoder: fake,
            cache: FootprintsGeocodeCache(fileURL: cacheURL),
            minimumRequestInterval: 0
        )
        _ = await first.resolve(clusters: [city])
        XCTAssertEqual(fake.requestCount, 1)

        let second = FootprintsGeocodeResolver(
            geocoder: fake,
            cache: FootprintsGeocodeCache(fileURL: cacheURL),
            minimumRequestInterval: 0
        )
        let batch = await second.resolve(clusters: [city])
        XCTAssertEqual(fake.requestCount, 1)
        XCTAssertEqual(batch.results[city.id]?.countryCode, "MA")
    }

    func testUnresolvedAndOceanClustersHaveClearPanelLabels() {
        let city = cluster(id: "city", stopIDs: ["photo"], latitude: 0, longitude: 0)

        let unresolved = FootprintsCountrySummary.build(clusters: [city], geocoding: [:])
        XCTAssertEqual(unresolved.first?.name, "Unknown location")
        XCTAssertEqual(unresolved.first?.flag, "🌐")

        let ocean = FootprintsCountrySummary.build(
            clusters: [city],
            geocoding: [city.id: .ocean]
        )
        XCTAssertEqual(ocean.first?.name, "Open ocean")
        XCTAssertEqual(ocean.first?.flag, "🌊")
    }

    private func cluster(id: String, stopIDs: [String], latitude: Double, longitude: Double) -> PlaceCluster {
        PlaceCluster(
            id: id,
            level: .city,
            stopIDs: stopIDs,
            center: GeoPoint(latitude: latitude, longitude: longitude),
            firstDate: origin
        )
    }
}

private final class CountingGeocoder: FootprintsGeocoder {
    private(set) var requestCount = 0
    let result: FootprintsGeocodeResult

    init(result: FootprintsGeocodeResult) {
        self.result = result
    }

    func reverseGeocode(coordinate: GeoPoint) async throws -> FootprintsGeocodeResult {
        requestCount += 1
        return result
    }
}
