import Foundation
import MomentsCore
import XCTest
@testable import Moments

/// The Timeline looks up place hints once per coordinate and in parallel
/// chunks. The hints must be exactly the ones the one-by-one lookup gives,
/// photo for photo and in the same order: repeats, misses, and photos
/// without a coordinate included. `TimelineScreen.placeHint(for:index:)` is
/// private, so the expected value is rebuilt here with the same rule
/// (`nearestName(to:within: 100_000)`, nil without a coordinate).
final class TimelinePlaceHintsTests: XCTestCase {
    func testParallelHintsMatchOneByOne() async {
        let index: NearestPlaceIndex = Self.makeIndex()
        let snapshots: [TimelineItemSnapshot] = Self.makeSnapshots()
        XCTAssertEqual(snapshots.count, 2_500)
        XCTAssertGreaterThan(Set(snapshots.map { (snapshot: TimelineItemSnapshot) -> String in snapshot.id }).count, 2_000)

        let parallel: [String?] = await TimelineScreen.placeHints(for: snapshots, index: index)
        XCTAssertEqual(parallel.count, snapshots.count)

        for position in 0..<snapshots.count {
            let snapshot: TimelineItemSnapshot = snapshots[position]
            let expected: String? = Self.oneByOneHint(for: snapshot, index: index)
            XCTAssertEqual(parallel[position], expected, "photo \(snapshot.id)")
        }
    }

    func testEmptyAndSmallInputs() async {
        let index: NearestPlaceIndex = Self.makeIndex()

        let empty: [TimelineItemSnapshot] = []
        let emptyHints: [String?] = await TimelineScreen.placeHints(for: empty, index: index)
        let noHints: [String?] = []
        XCTAssertEqual(emptyHints, noHints)

        let small: [TimelineItemSnapshot] = Self.smallSnapshots()
        XCTAssertEqual(small.count, 3)
        let smallHints: [String?] = await TimelineScreen.placeHints(for: small, index: index)
        XCTAssertEqual(smallHints.count, small.count)

        let expected: [String?] = small.map { (snapshot: TimelineItemSnapshot) -> String? in
            Self.oneByOneHint(for: snapshot, index: index)
        }
        for position in 0..<small.count {
            let snapshot: TimelineItemSnapshot = small[position]
            XCTAssertEqual(smallHints[position], expected[position], "photo \(snapshot.id)")
        }
        XCTAssertEqual(smallHints, expected)
    }

    /// The rule `placeHint(for:index:)` applies, rebuilt in the test because
    /// that method is private: no coordinate means no hint.
    private static func oneByOneHint(
        for snapshot: TimelineItemSnapshot,
        index: NearestPlaceIndex
    ) -> String? {
        guard let latitude = snapshot.latitude, let longitude = snapshot.longitude else { return nil }
        let point = GeoPoint(latitude: latitude, longitude: longitude)
        return index.nearestName(to: point, within: 100_000)
    }

    /// Thirty synthetic places in three regions, about 2 km apart.
    private static func makeIndex() -> NearestPlaceIndex {
        let regionCentres: [(latitude: Double, longitude: Double)] = [
            (10.0, 20.0),
            (-30.0, 140.0),
            (45.0, -75.0)
        ]
        var entries: [NearestPlaceIndex.Entry] = []
        entries.reserveCapacity(30)
        for (region, centre) in regionCentres.enumerated() {
            for step in 0..<10 {
                let latitude: Double = centre.latitude + Double(step) * 0.02
                let longitude: Double = centre.longitude + Double(step) * 0.02
                let name: String = "Synthetic Region \(region + 1) Place \(step + 1)"
                let point = GeoPoint(latitude: latitude, longitude: longitude)
                entries.append(NearestPlaceIndex.Entry(point: point, name: name))
            }
        }
        return NearestPlaceIndex(entries: entries)
    }

    /// 2,500 synthetic photos: 900 sharing nine coordinates, 600 unique ones
    /// near a place, 700 unique ones more than 100 km from every place, and
    /// 300 without a full coordinate. Several chunks are forced by the count.
    private static func makeSnapshots() -> [TimelineItemSnapshot] {
        var snapshots: [TimelineItemSnapshot] = []
        snapshots.reserveCapacity(2_500)

        let sharedCoordinates: [(latitude: Double, longitude: Double)] = [
            (10.0, 20.0),
            (10.04, 20.04),
            (10.08, 20.08),
            (-30.0, 140.0),
            (-30.04, 140.04),
            (-30.08, 140.08),
            (45.0, -75.0),
            (45.04, -75.04),
            (45.08, -75.08)
        ]
        for (coordinateIndex, coordinate) in sharedCoordinates.enumerated() {
            for copy in 0..<100 {
                let identifier: String = "shared-\(coordinateIndex)-\(copy)"
                let snapshot = TimelineItemSnapshot(
                    id: identifier,
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude
                )
                snapshots.append(snapshot)
            }
        }

        for step in 0..<600 {
            let identifier: String = "unique-near-\(step)"
            let latitude: Double = 10.0 + Double(step) * 0.00005
            let longitude: Double = 20.0 + Double(step) * 0.00007
            let snapshot = TimelineItemSnapshot(id: identifier, latitude: latitude, longitude: longitude)
            snapshots.append(snapshot)
        }

        for step in 0..<700 {
            let identifier: String = "far-\(step)"
            let latitude: Double = 0.0 + Double(step) * 0.0001
            let longitude: Double = 0.0 - Double(step) * 0.0001
            let snapshot = TimelineItemSnapshot(id: identifier, latitude: latitude, longitude: longitude)
            snapshots.append(snapshot)
        }

        for step in 0..<300 {
            let identifier: String = "no-coordinate-\(step)"
            let snapshot: TimelineItemSnapshot
            if step % 2 == 0 {
                snapshot = TimelineItemSnapshot(id: identifier, longitude: 20.0)
            } else {
                snapshot = TimelineItemSnapshot(id: identifier, latitude: 10.0)
            }
            snapshots.append(snapshot)
        }

        return snapshots
    }

    /// Three photos for the small input: one with a shared coordinate, one far
    /// from every place, one missing a coordinate.
    private static func smallSnapshots() -> [TimelineItemSnapshot] {
        let shared = TimelineItemSnapshot(id: "small-shared", latitude: 10.0, longitude: 20.0)
        let far = TimelineItemSnapshot(id: "small-far", latitude: 0.0, longitude: 0.0)
        let missing = TimelineItemSnapshot(id: "small-missing", longitude: 20.0)
        return [shared, far, missing]
    }
}
