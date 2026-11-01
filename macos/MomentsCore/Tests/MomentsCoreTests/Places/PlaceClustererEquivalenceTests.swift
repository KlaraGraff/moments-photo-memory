import Foundation
import XCTest
@testable import MomentsCore

final class PlaceClustererEquivalenceTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    func testOptimizedClustererMatchesReferenceOnSeededCases() {
        for caseIndex in 0..<300 {
            var random = SplitMix64(seed: 0x5EED_0000 &+ UInt64(caseIndex))
            let scenario = RandomScenario(index: caseIndex, origin: origin, random: &random)

            let reference = ReferencePlaceClusterer(
                spotRadiusMeters: scenario.spotRadius,
                areaRadiusMeters: scenario.areaRadius,
                cityRadiusMeters: scenario.cityRadius,
                maximumTimeGap: scenario.maximumTimeGap,
                overrides: scenario.overrides
            )
            let candidate = PlaceClusterer(
                spotRadiusMeters: scenario.spotRadius,
                areaRadiusMeters: scenario.areaRadius,
                cityRadiusMeters: scenario.cityRadius,
                maximumTimeGap: scenario.maximumTimeGap,
                overrides: scenario.overrides
            )
            let referenceFromMap = ReferencePlaceClusterer(
                spotRadiusMeters: scenario.spotRadius,
                areaRadiusMeters: scenario.areaRadius,
                cityRadiusMeters: scenario.cityRadius,
                maximumTimeGap: scenario.maximumTimeGap,
                overrides: scenario.overrideMap
            )
            let candidateFromMap = PlaceClusterer(
                spotRadiusMeters: scenario.spotRadius,
                areaRadiusMeters: scenario.areaRadius,
                cityRadiusMeters: scenario.cityRadius,
                maximumTimeGap: scenario.maximumTimeGap,
                overrides: scenario.overrideMap
            )

            for level in PlaceLevel.allCases {
                let expected = reference.clusters(for: scenario.stops, level: level)
                let actual = candidate.clusters(for: scenario.stops, level: level)
                XCTAssertEqual(actual, expected, "case \(caseIndex) (\(scenario.summary)) level \(level)")

                let expectedFromMap = referenceFromMap.clusters(for: scenario.stops, level: level)
                let actualFromMap = candidateFromMap.clusters(for: scenario.stops, level: level)
                XCTAssertEqual(
                    actualFromMap,
                    expectedFromMap,
                    "case \(caseIndex) (\(scenario.summary)) map overrides level \(level)"
                )
            }
        }
    }

    func testNearlyOppositePointsWithAHalfEarthRadiusMatchTheReference() {
        // Near opposite points the haversine distance comes out a few
        // centimetres below the latitude difference, so the cheap latitude
        // check must leave enough slack.
        let stops = [
            PhotoStop(id: "a", date: origin, coordinate: GeoPoint(latitude: 89.99985441989008, longitude: 0)),
            PhotoStop(id: "b", date: origin.addingTimeInterval(1), coordinate: GeoPoint(latitude: -90, longitude: 0)),
            PhotoStop(id: "c", date: origin.addingTimeInterval(2), coordinate: GeoPoint(latitude: 0, longitude: 180))
        ]
        for radius in [20_015_070.607951533, 20_015_086.796, 25_000_000, .infinity] {
            assertSameAsReference(stops, radius: radius, gap: 86_400, "radius \(radius)")
        }
    }

    func testDatesThatAreNotFiniteMatchTheReference() {
        let place = GeoPoint(latitude: 48.85, longitude: 2.35)
        for date in [Date(timeIntervalSinceReferenceDate: .infinity), Date(timeIntervalSinceReferenceDate: -.infinity), Date(timeIntervalSinceReferenceDate: .nan)] {
            let stops = [
                PhotoStop(id: "a", date: date, coordinate: place),
                PhotoStop(id: "b", date: date, coordinate: place)
            ]
            // A NaN date is never equal to itself and gives the final sort no
            // order (in the old code too), so compare what the clusters hold.
            let reference = ReferencePlaceClusterer(maximumTimeGap: 86_400)
            for level in PlaceLevel.allCases {
                XCTAssertEqual(
                    PlaceClusterer(maximumTimeGap: 86_400).clusters(for: stops, level: level).map { [$0.id] + $0.stopIDs }.sorted { $0[0] < $1[0] },
                    reference.clusters(for: stops, level: level).map { [$0.id] + $0.stopIDs }.sorted { $0[0] < $1[0] },
                    "date \(date.timeIntervalSinceReferenceDate) level \(level)"
                )
            }
        }
    }

    func testAGapOfExactlyTheMaximumStillJoins() {
        let place = GeoPoint(latitude: 48.85, longitude: 2.35)
        for gap in [0.0, 1, 3_600, 86_400] {
            let stops = [
                PhotoStop(id: "a", date: origin, coordinate: place),
                PhotoStop(id: "b", date: origin.addingTimeInterval(gap), coordinate: place),
                PhotoStop(id: "c", date: origin.addingTimeInterval(gap * 2 + 1), coordinate: place)
            ]
            assertSameAsReference(stops, radius: 1_500, gap: gap, "gap \(gap)")
            XCTAssertEqual(PlaceClusterer(maximumTimeGap: gap).clusters(for: stops, level: .spot).map(\.stopIDs), [["a", "b"], ["c"]])
        }
    }

    private func assertSameAsReference(_ stops: [PhotoStop], radius: Double, gap: TimeInterval, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let reference = ReferencePlaceClusterer(spotRadiusMeters: radius, areaRadiusMeters: radius, cityRadiusMeters: radius, maximumTimeGap: gap)
        let candidate = PlaceClusterer(spotRadiusMeters: radius, areaRadiusMeters: radius, cityRadiusMeters: radius, maximumTimeGap: gap)
        for level in PlaceLevel.allCases {
            XCTAssertEqual(candidate.clusters(for: stops, level: level), reference.clusters(for: stops, level: level), "\(label) level \(level)", file: file, line: line)
        }
    }
}

/// A deterministic, seeded description of one random clustering input.
private struct RandomScenario {
    let stops: [PhotoStop]
    let overrides: [PlaceOverride]
    let overrideMap: [String: String]
    let spotRadius: Double
    let areaRadius: Double
    let cityRadius: Double
    let maximumTimeGap: TimeInterval
    let summary: String

    init(index: Int, origin: Date, random: inout SplitMix64) {
        let style = GenerationStyle(rawValue: index % GenerationStyle.allCases.count) ?? .denseClumps
        let count: Int
        switch index {
        case 0: count = 0
        case 1: count = 1
        case 2: count = 2
        default: count = random.int(in: 0...400)
        }

        var points: [GeoPoint?] = Self.makePoints(style: style, count: count, random: &random)

        // About one photo in ten has no coordinate at all.
        for pointIndex in points.indices where random.double(in: 0...1) < 0.1 {
            points[pointIndex] = nil
        }

        var dates: [Date] = []
        var date = origin
        for stopIndex in 0..<count {
            let roll = random.int(in: 0...99)
            if stopIndex > 0, roll < 12 {
                // Duplicate the previous date exactly.
                dates.append(dates[stopIndex - 1])
                continue
            } else if roll < 70 {
                date = date.addingTimeInterval(random.double(in: 0...6 * 3_600))
            } else if roll < 93 {
                date = date.addingTimeInterval(random.double(in: 6 * 3_600...3 * 86_400))
            } else {
                date = date.addingTimeInterval(random.double(in: 3 * 86_400...40 * 86_400))
            }
            dates.append(date)
        }

        self.stops = (0..<count).map { stopIndex in
            PhotoStop(id: "case\(index)-photo-\(stopIndex)", date: dates[stopIndex], coordinate: points[stopIndex])
        }

        // A few cases force the interesting radius and gap extremes.
        switch index {
        case 3:
            self.spotRadius = 0
            self.areaRadius = 0
            self.cityRadius = 0
        case 4:
            self.spotRadius = 20_000_000
            self.areaRadius = 20_000_000
            self.cityRadius = 20_000_000
        default:
            self.spotRadius = Self.randomRadius(&random)
            self.areaRadius = Self.randomRadius(&random)
            self.cityRadius = Self.randomRadius(&random)
        }

        switch index {
        case 3, 5:
            self.maximumTimeGap = 0
        case 6:
            self.maximumTimeGap = 0
        default:
            let roll = random.int(in: 0...9)
            if roll == 0 {
                self.maximumTimeGap = 0
            } else if roll < 3 {
                self.maximumTimeGap = random.double(in: 0...3 * 86_400)
            } else {
                let pool: [TimeInterval] = [0, 1, 60, 3_600, 6 * 3_600, 86_400, 7 * 86_400, 365 * 86_400]
                self.maximumTimeGap = pool[random.int(in: 0...(pool.count - 1))]
            }
        }

        var overrides: [PlaceOverride] = []
        if count > 0, index % 3 != 1, random.double(in: 0...1) < 0.6 {
            let overrideCount = random.int(in: 1...min(8, count))
            for _ in 0..<overrideCount {
                let stopIndex = random.int(in: 0...(count - 1))
                let level = PlaceLevel.allCases[random.int(in: 0...(PlaceLevel.allCases.count - 1))]
                let clusterID = ["ov-alpha", "ov-beta", "ov-gamma"][random.int(in: 0...2)]
                let name: String? = random.double(in: 0...1) < 0.5 ? "Override \(clusterID)" : nil
                overrides.append(
                    PlaceOverride(
                        stopID: stops[stopIndex].id,
                        level: level,
                        clusterID: clusterID,
                        name: name
                    )
                )
            }
            // Duplicate stop IDs exercise the "last override wins" rule.
            if random.double(in: 0...1) < 0.4, let last = overrides.last {
                overrides.append(
                    PlaceOverride(
                        stopID: last.stopID,
                        level: last.level,
                        clusterID: "ov-late",
                        name: last.name
                    )
                )
            }
        }
        self.overrides = overrides

        var map: [String: String] = [:]
        if count > 0, index % 4 == 0 {
            let entries = random.int(in: 1...min(4, count))
            for _ in 0..<entries {
                let stopIndex = random.int(in: 0...(count - 1))
                map[stops[stopIndex].id] = ["map-one", "map-two"][random.int(in: 0...1)]
            }
        }
        // A stop ID that does not exist must be ignored without trapping.
        if index % 7 == 0 {
            map["missing-\(index)"] = "map-missing"
        }
        self.overrideMap = map

        self.summary = "style=\(style) count=\(count) spot=\(spotRadius) area=\(areaRadius) city=\(cityRadius) gap=\(maximumTimeGap) overrides=\(overrides.count) map=\(map.count)"
    }

    private static func randomRadius(_ random: inout SplitMix64) -> Double {
        switch random.int(in: 0...4) {
        case 0: return 0
        case 1: return 20_000_000
        case 2: return random.double(in: 0...2_000)
        case 3: return random.double(in: 0...100_000)
        default:
            let pool: [Double] = [0, 5, 50, 400, 1_500, 8_000, 25_000, 120_000, 2_000_000, 20_000_000]
            return pool[random.int(in: 0...(pool.count - 1))]
        }
    }

    private static func makePoints(
        style: GenerationStyle,
        count: Int,
        random: inout SplitMix64
    ) -> [GeoPoint?] {
        var points: [GeoPoint?] = []
        points.reserveCapacity(count)
        switch style {
        case .denseClumps:
            let clumpCount = random.int(in: 1...4)
            let centres = (0..<clumpCount).map { _ in
                GeoPoint(
                    latitude: random.double(in: -70...70),
                    longitude: random.double(in: -179...179)
                )
            }
            for _ in 0..<count {
                let centre = centres[random.int(in: 0...(clumpCount - 1))]
                points.append(
                    GeoPoint(
                        latitude: centre.latitude + random.double(in: -0.004...0.004),
                        longitude: centre.longitude + random.double(in: -0.004...0.004)
                    )
                )
            }
        case .spreadOut:
            for _ in 0..<count {
                points.append(
                    GeoPoint(
                        latitude: random.double(in: -80...80),
                        longitude: random.double(in: -180...180)
                    )
                )
            }
        case .antimeridian:
            for _ in 0..<count {
                let side = random.int(in: 0...1) == 0 ? 179.9 : -179.9
                points.append(
                    GeoPoint(
                        latitude: random.double(in: -60...60),
                        longitude: side + random.double(in: -0.35...0.35)
                    )
                )
            }
        case .poles:
            for _ in 0..<count {
                let sign = random.int(in: 0...1) == 0 ? 1.0 : -1.0
                points.append(
                    GeoPoint(
                        latitude: sign * random.double(in: 85...89.9),
                        longitude: random.double(in: -180...180)
                    )
                )
            }
        case .randomWalk:
            var latitude = random.double(in: -60...60)
            var longitude = random.double(in: -170...170)
            for _ in 0..<count {
                latitude += random.double(in: -0.05...0.05)
                longitude += random.double(in: -0.05...0.05)
                points.append(GeoPoint(latitude: latitude, longitude: longitude))
            }
        case .line:
            let startLatitude = random.double(in: -50...50)
            let startLongitude = random.double(in: -150...150)
            let step = random.double(in: 0.001...0.05)
            for pointIndex in 0..<count {
                points.append(
                    GeoPoint(
                        latitude: startLatitude + Double(pointIndex) * step * 0.3,
                        longitude: startLongitude + Double(pointIndex) * step
                    )
                )
            }
        }
        return points
    }
}

private enum GenerationStyle: Int, CaseIterable, CustomStringConvertible {
    case denseClumps
    case spreadOut
    case antimeridian
    case poles
    case randomWalk
    case line

    var description: String {
        switch self {
        case .denseClumps: return "denseClumps"
        case .spreadOut: return "spreadOut"
        case .antimeridian: return "antimeridian"
        case .poles: return "poles"
        case .randomWalk: return "randomWalk"
        case .line: return "line"
        }
    }
}

/// The tiny SplitMix64 generator keeps every case reproducible.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func int(in range: ClosedRange<Int>) -> Int {
        let width = UInt64(range.count)
        return range.lowerBound + Int(next() % width)
    }

    mutating func double(in range: ClosedRange<Double>) -> Double {
        let unit = Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}
