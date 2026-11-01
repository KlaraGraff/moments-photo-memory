import Foundation

/// The nearest named place to a point, from a grid of 1° cells instead of a
/// scan of every place for every photo. Gives the same answer as the scan.
public struct NearestPlaceIndex: Sendable {
    /// One named place in the index.
    public struct Entry: Equatable, Sendable {
        public let point: GeoPoint
        public let name: String

        public init(point: GeoPoint, name: String) {
            self.point = point
            self.name = name
        }
    }

    private struct Cell: Hashable {
        let lat: Int
        let lon: Int
    }

    private static let allLongitudes = Array(-180...179)

    private let entries: [Entry]
    private let cells: [Cell: [Int]]

    /// Builds an index over the supplied entries. Entries keep their order, so
    /// the earliest one wins when two entries are equally near.
    public init(entries: [Entry]) {
        self.entries = entries

        var cells: [Cell: [Int]] = [:]
        cells.reserveCapacity(entries.count)
        for (index, entry) in entries.enumerated() {
            cells[Self.cell(for: entry.point), default: []].append(index)
        }
        self.cells = cells
    }

    /// True when the index holds no entries.
    public var isEmpty: Bool { entries.isEmpty }

    /// The name of the entry nearest to `point` (by `GeoPoint.distance`), if
    /// that entry is at most `maxMeters` away. When several entries are
    /// equally near, the one that came first in `entries` wins.
    public func nearestName(to point: GeoPoint, within maxMeters: Double) -> String? {
        guard !entries.isEmpty, maxMeters >= 0, maxMeters.isFinite else { return nil }

        let delta = maxMeters / 6_371_000
        let degreesLat = delta * 180 / .pi * 1.01 + 0.001

        // Clamp before converting, so a very large radius cannot overflow Int.
        let latLow = Int(floor(max(-90, point.latitude - degreesLat)))
        let latHigh = Int(floor(min(89, point.latitude + degreesLat)))
        guard latLow <= latHigh else { return nil }

        let columns = longitudeColumns(for: point, delta: delta, degreesLat: degreesLat)

        var bestIndex: Int?
        var bestDistance = Double.infinity

        for lat in latLow...latHigh {
            for lon in columns {
                guard let indexes = cells[Cell(lat: lat, lon: lon)] else { continue }
                for index in indexes {
                    let distance = point.distance(to: entries[index].point)
                    if distance < bestDistance
                        || (distance == bestDistance && index < (bestIndex ?? Int.max)) {
                        bestDistance = distance
                        bestIndex = index
                    }
                }
            }
        }

        guard let bestIndex, bestDistance <= maxMeters else { return nil }
        return entries[bestIndex].name
    }

    /// The grid cell that holds a point. Latitude 90 shares cell 89, and
    /// longitude 180 shares cell -180, so every cell stays in range.
    private static func cell(for point: GeoPoint) -> Cell {
        let lat = min(89, Int(floor(point.latitude)))
        var lon = Int(floor(point.longitude))
        lon = ((lon + 180) % 360 + 360) % 360 - 180
        return Cell(lat: lat, lon: lon)
    }

    /// The longitude cells to look at. Near a pole, or when the reach crosses a
    /// pole, every column is searched. Otherwise the columns around the point
    /// are wrapped into -180...179, which covers the antimeridian.
    private func longitudeColumns(
        for point: GeoPoint,
        delta: Double,
        degreesLat: Double
    ) -> [Int] {
        if abs(point.latitude) + degreesLat >= 89.9 {
            return Self.allLongitudes
        }

        let s = sin(delta) / cos(point.latitude * .pi / 180)
        if s >= 1 {
            return Self.allLongitudes
        }

        let degreesLon = asin(s) * 180 / .pi * 1.01 + 0.001
        let lonLow = Int(floor(point.longitude - degreesLon))
        let lonHigh = Int(floor(point.longitude + degreesLon))
        if lonHigh - lonLow >= 359 {
            return Self.allLongitudes
        }

        var columns: [Int] = []
        var seen = Set<Int>()
        for longitude in lonLow...lonHigh {
            let wrapped = ((longitude + 180) % 360 + 360) % 360 - 180
            if seen.insert(wrapped).inserted {
                columns.append(wrapped)
            }
        }
        return columns
    }
}
