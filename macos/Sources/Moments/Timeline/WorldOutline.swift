import CoreGraphics
import Foundation

/// Country outlines for the little route maps on trip cards: Natural Earth's
/// 1:50m admin-0 boundaries (public domain, via the world-atlas package),
/// simplified to about 0.03° and stored as rings of 1/90° steps. Loaded
/// once from the app bundle; nothing is fetched from the network.
///
/// File: "MWL1", ring count (UInt32), then per ring a point count (UInt32)
/// and that many (longitude, latitude) Int16 pairs, little-endian.
struct WorldOutline: Sendable {
    struct Ring: Sendable {
        /// Longitude, latitude in degrees.
        let points: [SIMD2<Double>]
        let minLongitude: Double
        let maxLongitude: Double
        let minLatitude: Double
        let maxLatitude: Double
    }

    let rings: [Ring]

    static let shared: WorldOutline = {
        guard let url = Bundle.main.url(forResource: "WorldOutline", withExtension: "bin"),
              let data = try? Data(contentsOf: url) else { return WorldOutline(rings: []) }
        return WorldOutline(data: data) ?? WorldOutline(rings: [])
    }()

    init(rings: [Ring]) {
        self.rings = rings
    }

    init?(data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, bytes[0..<4].elementsEqual("MWL1".utf8) else { return nil }
        func uint32(_ at: Int) -> Int {
            Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
        }
        func int16(_ at: Int) -> Double {
            Double(Int16(bitPattern: UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8)) / 90
        }
        let count = uint32(4)
        var offset = 8
        var rings: [Ring] = []
        rings.reserveCapacity(count)
        for _ in 0..<count {
            guard offset + 4 <= bytes.count else { return nil }
            let pointCount = uint32(offset)
            offset += 4
            guard offset + pointCount * 4 <= bytes.count else { return nil }
            var points: [SIMD2<Double>] = []
            points.reserveCapacity(pointCount)
            for index in 0..<pointCount {
                points.append(SIMD2(int16(offset + index * 4), int16(offset + index * 4 + 2)))
            }
            offset += pointCount * 4
            // Rings that cross the 180° meridian (Russia's far east, Fiji)
            // jump from +180 to -180; unwrap them so they stay one shape,
            // and add a copy a world away so both sides of the line see it.
            for index in points.indices.dropFirst() {
                let step = points[index].x - points[index - 1].x
                if step > 180 { points[index].x -= 360 } else if step < -180 { points[index].x += 360 }
            }
            let ring = Self.ring(points)
            rings.append(ring)
            if ring.maxLongitude > 180 {
                rings.append(Self.ring(points.map { SIMD2($0.x - 360, $0.y) }))
            } else if ring.minLongitude < -180 {
                rings.append(Self.ring(points.map { SIMD2($0.x + 360, $0.y) }))
            }
        }
        self.rings = rings
    }

    private static func ring(_ points: [SIMD2<Double>]) -> Ring {
        let longitudes = points.map(\.x), latitudes = points.map(\.y)
        return Ring(
            points: points,
            minLongitude: longitudes.min() ?? 0,
            maxLongitude: longitudes.max() ?? 0,
            minLatitude: latitudes.min() ?? 0,
            maxLatitude: latitudes.max() ?? 0
        )
    }

    /// Rings that reach into the given box of longitudes and latitudes.
    func rings(longitudes: ClosedRange<Double>, latitudes: ClosedRange<Double>) -> [Ring] {
        rings.filter {
            $0.maxLongitude >= longitudes.lowerBound && $0.minLongitude <= longitudes.upperBound
                && $0.maxLatitude >= latitudes.lowerBound && $0.minLatitude <= latitudes.upperBound
        }
    }
}
