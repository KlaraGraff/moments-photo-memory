import Foundation

/// The route lines a map draws: each pair of places once, however often the
/// photos moved between them.
public struct MapRoutes: Equatable, Sendable {
    /// One segment per pair of places, in the order of `segments` given to init.
    public let segments: [RouteSegment]
    /// Ids of kept segments whose pair was travelled in both directions.
    /// The map draws no direction arrow on those.
    public let twoWayIDs: Set<String>

    public init(segments: [RouteSegment], limit: Int = 400) {
        let maximum = max(0, limit)

        var kept: [RouteSegment] = []
        var indexByKey: [String: Int] = [:]
        var twoWayIDs: Set<String> = []

        for segment in segments {
            let key = Self.pairKey(from: segment.from.id, to: segment.to.id)

            if let index = indexByKey[key] {
                let keptSegment = kept[index]
                if keptSegment.to.id == segment.from.id {
                    twoWayIDs.insert(keptSegment.id)
                }
                continue
            }

            indexByKey[key] = kept.count
            kept.append(segment)
        }

        guard kept.count > maximum else {
            self.segments = kept
            self.twoWayIDs = twoWayIDs
            return
        }

        let chosen = Self.longest(kept, limit: maximum)
        let chosenIDs = Set(chosen.map(\.id))

        var droppedIDs: Set<String> = []
        for segment in kept where !chosenIDs.contains(segment.id) {
            droppedIDs.insert(segment.id)
        }

        self.segments = chosen
        self.twoWayIDs = twoWayIDs.subtracting(droppedIDs)
    }

    /// The longest `limit` segments, in input order; equal lengths keep the
    /// lower index. Used for the segments a map draws at once.
    public static func longest(_ segments: [RouteSegment], limit: Int) -> [RouteSegment] {
        let maximum = max(0, limit)
        guard segments.count > maximum else { return segments }

        let chosenIndices = Set(
            segments.indices.sorted { lhs, rhs in
                if segments[lhs].distanceMeters != segments[rhs].distanceMeters {
                    return segments[lhs].distanceMeters > segments[rhs].distanceMeters
                }
                return lhs < rhs
            }
            .prefix(maximum)
        )

        return segments.indices
            .filter { chosenIndices.contains($0) }
            .map { segments[$0] }
    }

    private static func pairKey(from: String, to: String) -> String {
        [from, to].sorted().joined(separator: "|")
    }
}
