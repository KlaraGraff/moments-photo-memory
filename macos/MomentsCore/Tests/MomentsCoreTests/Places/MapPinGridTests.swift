import Foundation
import XCTest
@testable import MomentsCore

final class MapPinGridTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    func testOneClusterPerCellIsUnchanged() {
        let input = [
            cluster("a", stops: ["a-1"], latitude: 5, longitude: 5),
            cluster("b", stops: ["b-1"], latitude: 25, longitude: 25),
            cluster("c", stops: ["c-1"], latitude: 45, longitude: 45)
        ]

        let merged = MapPinGrid.merge(input, cellDegrees: 10)

        XCTAssertEqual(merged, input)
    }

    func testClustersInOneCellMerge() {
        let first = cluster(
            "first",
            stops: ["a-1", "a-2"],
            latitude: 1,
            longitude: 1,
            date: origin.addingTimeInterval(300),
            name: "Harbour"
        )
        let second = cluster(
            "second",
            stops: ["b-1"],
            latitude: 2,
            longitude: 2,
            date: origin.addingTimeInterval(100),
            name: "Harbour"
        )
        let third = cluster(
            "third",
            stops: ["c-1", "c-2"],
            latitude: 3,
            longitude: 3,
            date: origin.addingTimeInterval(200),
            name: "Harbour"
        )

        let merged = MapPinGrid.merge([first, second, third], cellDegrees: 10)

        XCTAssertEqual(merged.count, 1)
        let pin = merged[0]
        XCTAssertTrue(pin.id.hasPrefix("grid-"))
        XCTAssertTrue(pin.id.hasSuffix(first.id))
        XCTAssertEqual(pin.level, first.level)
        XCTAssertEqual(pin.stopIDs, ["a-1", "a-2", "b-1", "c-1", "c-2"])
        XCTAssertEqual(pin.firstDate, origin.addingTimeInterval(100))
        XCTAssertEqual(pin.name, "Harbour")
        XCTAssertEqual(
            pin.center,
            GeoPoint.centre(of: [first, second, third].compactMap(\.center))
        )
    }

    func testClusterWithoutCentrePassesThrough() {
        let pin = cluster("pin", stops: ["p-1"], latitude: 1, longitude: 1)
        let other = cluster("other", stops: ["o-1"], latitude: 2, longitude: 2)
        let withoutCentre = PlaceCluster(
            id: "nowhere",
            level: .city,
            stopIDs: ["n-1"],
            center: nil,
            firstDate: origin
        )

        let merged = MapPinGrid.merge([withoutCentre, pin, other], cellDegrees: 10)

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0], withoutCentre)
        XCTAssertEqual(merged[1].id, "grid-0_0-\(pin.id)")
        XCTAssertEqual(merged[1].stopIDs, ["p-1", "o-1"])
    }

    func testBadCellSizeReturnsInput() {
        let input = [
            cluster("a", stops: ["a-1"], latitude: 1, longitude: 1),
            cluster("b", stops: ["b-1"], latitude: 2, longitude: 2)
        ]

        XCTAssertEqual(MapPinGrid.merge(input, cellDegrees: 0), input)
        XCTAssertEqual(MapPinGrid.merge(input, cellDegrees: -1), input)
        XCTAssertEqual(MapPinGrid.merge(input, cellDegrees: .nan), input)
        XCTAssertEqual(MapPinGrid.merge(input, cellDegrees: .infinity), input)
    }

    func testOutputOrderFollowsFirstMember() {
        let x1 = cluster("x-1", stops: ["x-1"], latitude: 1, longitude: 1)
        let y = cluster("y", stops: ["y-1"], latitude: 15, longitude: 15)
        let x2 = cluster("x-2", stops: ["x-2"], latitude: 2, longitude: 2)
        let z = cluster("z", stops: ["z-1"], latitude: 25, longitude: 25)

        let merged = MapPinGrid.merge([x1, y, x2, z], cellDegrees: 10)

        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged[0].id, "grid-0_0-x-1")
        XCTAssertEqual(merged[0].stopIDs, ["x-1", "x-2"])
        XCTAssertEqual(merged[1], y)
        XCTAssertEqual(merged[2], z)
    }

    private func cluster(
        _ id: String,
        stops: [String],
        latitude: Double,
        longitude: Double,
        date: Date? = nil,
        name: String? = nil
    ) -> PlaceCluster {
        PlaceCluster(
            id: id,
            level: .city,
            stopIDs: stops,
            center: GeoPoint(latitude: latitude, longitude: longitude),
            firstDate: date ?? origin,
            name: name
        )
    }
}
