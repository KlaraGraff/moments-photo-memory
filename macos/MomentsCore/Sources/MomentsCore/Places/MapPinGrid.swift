import Foundation

/// Pins on a zoomed-out map: clusters whose centres share a grid cell become
/// one pin, so the globe shows a few dozen pins instead of hundreds.
public enum MapPinGrid {
    public static func merge(_ clusters: [PlaceCluster], cellDegrees: Double) -> [PlaceCluster] {
        guard cellDegrees.isFinite, cellDegrees > 0 else { return clusters }

        var slots: [Slot] = []
        var membersByCell: [Cell: [PlaceCluster]] = [:]

        for cluster in clusters {
            guard let center = cluster.center else {
                slots.append(.single(cluster))
                continue
            }

            let cell = Cell(
                latitude: cellIndex(center.latitude, cellDegrees: cellDegrees),
                longitude: cellIndex(center.longitude, cellDegrees: cellDegrees)
            )
            if membersByCell[cell] == nil {
                slots.append(.merged(cell))
            }
            membersByCell[cell, default: []].append(cluster)
        }

        var result: [PlaceCluster] = []
        result.reserveCapacity(slots.count)

        for slot in slots {
            switch slot {
            case let .single(cluster):
                result.append(cluster)
            case let .merged(cell):
                let members = membersByCell[cell] ?? []
                if members.count == 1, let cluster = members.first {
                    result.append(cluster)
                } else if let merged = mergedCluster(cell: cell, members: members) {
                    result.append(merged)
                }
            }
        }
        return result
    }

    private static func cellIndex(_ value: Double, cellDegrees: Double) -> Int {
        let raw = floor(value / cellDegrees)
        guard raw.isFinite else { return raw < 0 ? Int.min : Int.max }
        if raw <= Double(Int.min) { return Int.min }
        if raw >= Double(Int.max) { return Int.max }
        return Int(raw)
    }

    private static func mergedCluster(cell: Cell, members: [PlaceCluster]) -> PlaceCluster? {
        guard let first = members.first else { return nil }

        let name: String? = {
            guard let candidate = first.name else { return nil }
            return members.allSatisfy { $0.name == candidate } ? candidate : nil
        }()

        return PlaceCluster(
            id: "grid-\(cell.latitude)_\(cell.longitude)-" + first.id,
            level: first.level,
            stopIDs: members.flatMap(\.stopIDs),
            center: GeoPoint.centre(of: members.compactMap(\.center)),
            firstDate: members.map(\.firstDate).min() ?? first.firstDate,
            name: name
        )
    }

    private struct Cell: Hashable {
        let latitude: Int
        let longitude: Int
    }

    private enum Slot {
        case single(PlaceCluster)
        case merged(Cell)
    }
}
