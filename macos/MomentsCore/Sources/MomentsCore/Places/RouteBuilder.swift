import Foundation

public struct RouteSegment: Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let from: PlaceCluster
    public let to: PlaceCluster
    public let fromStopID: String?
    public let toStopID: String?
    public let distanceMeters: Double

    public init(
        from: PlaceCluster,
        to: PlaceCluster,
        fromStopID: String? = nil,
        toStopID: String? = nil,
        distanceMeters: Double
    ) {
        self.from = from
        self.to = to
        self.fromStopID = fromStopID
        self.toStopID = toStopID
        self.distanceMeters = max(0, distanceMeters)
        self.id = "\(from.id)->\(to.id)"
    }

    public var distanceKilometers: Double { distanceMeters / 1_000 }
}

/// Builds chronological moves between the clusters visited by a trip.
public struct RouteBuilder: Sendable {
    public let stops: [PhotoStop]
    public let clusterer: PlaceClusterer

    public init(stops: [PhotoStop] = [], clusterer: PlaceClusterer = PlaceClusterer()) {
        self.stops = stops
        self.clusterer = clusterer
    }

    public func overview(level: PlaceLevel = .city) -> [RouteSegment] {
        segments(for: stops, level: level)
    }

    public func local(level: PlaceLevel = .spot) -> [RouteSegment] {
        segments(for: stops, level: level)
    }

    private func segments(for sourceStops: [PhotoStop], level: PlaceLevel) -> [RouteSegment] {
        let orderedStops = sourceStops.sorted(by: Self.photoOrder)
        guard !orderedStops.isEmpty else { return [] }
        let clusters = clusterer.clusters(for: orderedStops, level: level)
        guard !clusters.isEmpty else { return [] }

        var clusterByStopID: [String: PlaceCluster] = [:]
        for cluster in clusters {
            for stopID in cluster.stopIDs {
                clusterByStopID[stopID] = cluster
            }
        }

        var visits: [Visit] = []
        for stop in orderedStops {
            guard let cluster = clusterByStopID[stop.id] else { continue }
            if let index = visits.indices.last, visits[index].cluster.id == cluster.id {
                visits[index].lastStop = stop
            } else {
                visits.append(Visit(cluster: cluster, firstStop: stop, lastStop: stop))
            }
        }

        guard visits.count > 1 else { return [] }
        var result: [RouteSegment] = []
        result.reserveCapacity(visits.count - 1)
        for index in 0..<(visits.count - 1) {
            let fromVisit = visits[index]
            let toVisit = visits[index + 1]
            guard fromVisit.cluster.id != toVisit.cluster.id else { continue }
            guard let fromPoint = fromVisit.lastStop.coordinate ?? fromVisit.cluster.center,
                  let toPoint = toVisit.firstStop.coordinate ?? toVisit.cluster.center else {
                continue
            }
            result.append(
                RouteSegment(
                    from: fromVisit.cluster,
                    to: toVisit.cluster,
                    fromStopID: fromVisit.lastStop.id,
                    toStopID: toVisit.firstStop.id,
                    distanceMeters: fromPoint.distance(to: toPoint)
                )
            )
        }
        return result
    }

    private static func photoOrder(_ lhs: PhotoStop, _ rhs: PhotoStop) -> Bool {
        if lhs.date != rhs.date { return lhs.date < rhs.date }
        return lhs.id < rhs.id
    }
}

private struct Visit {
    let cluster: PlaceCluster
    let firstStop: PhotoStop
    var lastStop: PhotoStop
}
