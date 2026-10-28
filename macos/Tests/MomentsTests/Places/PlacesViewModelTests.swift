import Foundation
import XCTest
@testable import Moments
import MomentsCore

@MainActor
final class PlacesViewModelTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    func testLevelSwitchesFromCityToAreaToSpotByLatitudeSpan() {
        let viewModel = PlacesViewModel()

        XCTAssertEqual(viewModel.level(for: 10), .city)
        XCTAssertEqual(viewModel.level(for: 2), .city)
        XCTAssertEqual(viewModel.level(for: 1.0), .area)
        XCTAssertEqual(viewModel.level(for: 0.35), .area)
        XCTAssertEqual(viewModel.level(for: 0.1), .spot)
        XCTAssertEqual(viewModel.level(for: .nan), .spot)
    }

    func testLibraryVisibilityFilterIsAppliedBeforeMappingStops() {
        let kept = item("kept", hours: 0, latitude: 0.001, longitude: 0.001)
        let removed = item("removed", hours: 1, latitude: 0.002, longitude: 0.002)
        let viewModel = PlacesViewModel()

        XCTAssertEqual(viewModel.photoStops(from: [removed, kept], visibleItemIDs: ["kept"]).map(\.id), ["kept"])
        XCTAssertEqual(viewModel.photoStops(from: [removed, kept], visibleItemIDs: nil).map(\.id), ["kept", "removed"])
        XCTAssertTrue(viewModel.photoStops(from: [removed, kept], visibleItemIDs: []).isEmpty)
    }

    func testSnapshotUsesCityOverviewAndSpotLocalRoutes() {
        let items = [
            item("a", hours: 0, latitude: 0, longitude: 0),
            item("b", hours: 1, latitude: 0, longitude: 0.005),
            item("c", hours: 30, latitude: 0.3, longitude: 0.3)
        ]
        let viewModel = PlacesViewModel()

        let overview = viewModel.snapshot(items: items, visibleItemIDs: nil, latitudeDelta: 4)
        let local = viewModel.snapshot(items: items, visibleItemIDs: nil, latitudeDelta: 0.1)

        XCTAssertEqual(overview.level, .city)
        XCTAssertEqual(local.level, .spot)
        XCTAssertFalse(overview.routeSegments.isEmpty)
        XCTAssertFalse(local.routeSegments.isEmpty)
    }

    func testSnapshotFromDetachedStopsKeepsTheSameMapModel() {
        let items = [
            item("a", hours: 0, latitude: 0, longitude: 0),
            item("b", hours: 1, latitude: 0, longitude: 0.005),
            item("c", hours: 30, latitude: 0.3, longitude: 0.3)
        ]
        let viewModel = PlacesViewModel()
        let fromItems = viewModel.snapshot(items: items, visibleItemIDs: nil, latitudeDelta: 4)
        let fromStops = viewModel.snapshot(stops: viewModel.photoStops(from: items, visibleItemIDs: nil), latitudeDelta: 4)

        XCTAssertEqual(fromStops.level, fromItems.level)
        XCTAssertEqual(fromStops.stops, fromItems.stops)
        XCTAssertEqual(fromStops.clusters, fromItems.clusters)
        XCTAssertEqual(fromStops.routeSegments, fromItems.routeSegments)
        XCTAssertEqual(fromStops.coordinateByID, fromItems.coordinateByID)
    }

    func testClusterSelectionMapsToSharedItemSelectionAndBack() {
        let items = [
            item("first", hours: 0, latitude: 0, longitude: 0),
            item("second", hours: 1, latitude: 0, longitude: 0.001)
        ]
        let viewModel = PlacesViewModel()
        let snapshot = viewModel.snapshot(items: items, visibleItemIDs: nil, latitudeDelta: 0.1)
        let cluster = try! XCTUnwrap(snapshot.clusters.first)

        XCTAssertEqual(viewModel.selectionIDs(for: cluster), Set(["first", "second"]))
        XCTAssertEqual(viewModel.selectedCluster(in: snapshot, selectedItemIDs: ["second"], focusedItemID: nil)?.id, cluster.id)
        XCTAssertEqual(viewModel.selectedCluster(in: snapshot, selectedItemIDs: [], focusedItemID: "first")?.id, cluster.id)
        XCTAssertNil(viewModel.selectedCluster(in: snapshot, selectedItemIDs: ["outside"], focusedItemID: nil))
    }

    func testMissingCoordinatesRemainOutOfMapButDoNotBreakFilter() {
        let located = item("located", hours: 0, latitude: 1, longitude: 1)
        let missing = MediaItem(id: "missing", captureDate: origin, title: "Missing")
        let viewModel = PlacesViewModel()

        let stops = viewModel.photoStops(from: [missing, located], visibleItemIDs: nil)
        XCTAssertEqual(stops.map(\.id), ["located", "missing"])
        XCTAssertNil(stops.last?.coordinate)
        XCTAssertEqual(viewModel.snapshot(items: [missing, located], visibleItemIDs: nil, latitudeDelta: 0.1).clusters.count, 1)
    }

    func testUndatedPhotosAreClusteredButLeftOutOfRoutes() {
        let undated = MediaItem(id: "undated", captureDate: nil, latitude: 10, longitude: 10, title: "undated")
        let items = [
            undated,
            item("a", hours: 0, latitude: 0, longitude: 0),
            item("b", hours: 1, latitude: 0, longitude: 3)
        ]
        let snapshot = PlacesViewModel().snapshot(items: items, visibleItemIDs: nil, latitudeDelta: 10)

        XCTAssertTrue(snapshot.clusters.contains { $0.stopIDs == ["undated"] })
        XCTAssertFalse(snapshot.routeSegments.contains { $0.fromStopID == "undated" || $0.toStopID == "undated" })
        XCTAssertEqual(snapshot.routeSegments.count, 1)
    }

    private func item(_ id: String, hours: TimeInterval, latitude: Double, longitude: Double) -> MediaItem {
        MediaItem(
            id: id,
            captureDate: origin.addingTimeInterval(hours * 3_600),
            latitude: latitude,
            longitude: longitude,
            title: id
        )
    }
}
