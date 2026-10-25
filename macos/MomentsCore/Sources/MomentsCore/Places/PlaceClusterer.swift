import Foundation

public enum PlaceLevel: String, CaseIterable, Codable, Hashable, Sendable {
    case spot
    case area
    case city
}

/// A user-assigned place takes precedence over distance-based clustering.
public struct PlaceOverride: Equatable, Hashable, Sendable {
    public let stopID: String
    public let level: PlaceLevel
    public let clusterID: String
    public let name: String?

    public init(
        stopID: String,
        level: PlaceLevel = .spot,
        clusterID: String,
        name: String? = nil
    ) {
        self.stopID = stopID
        self.level = level
        self.clusterID = clusterID
        self.name = name
    }
}

public struct PlaceCluster: Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let level: PlaceLevel
    public let stopIDs: [String]
    public let center: GeoPoint?
    public let firstDate: Date
    public let name: String?

    public init(
        id: String,
        level: PlaceLevel,
        stopIDs: [String],
        center: GeoPoint?,
        firstDate: Date,
        name: String? = nil
    ) {
        self.id = id
        self.level = level
        self.stopIDs = stopIDs
        self.center = center
        self.firstDate = firstDate
        self.name = name
    }
}

/// Groups photo stops into stable spot, area, and city clusters.
public struct PlaceClusterer: Sendable {
    public let spotRadiusMeters: Double
    public let areaRadiusMeters: Double
    public let cityRadiusMeters: Double
    public let maximumTimeGap: TimeInterval

    private let overrides: [PlaceOverride]

    public init(
        spotRadiusMeters: Double = 1_500,
        areaRadiusMeters: Double = 8_000,
        cityRadiusMeters: Double = 25_000,
        maximumTimeGap: TimeInterval = 24 * 60 * 60,
        overrides: [PlaceOverride] = []
    ) {
        self.spotRadiusMeters = max(0, spotRadiusMeters)
        self.areaRadiusMeters = max(0, areaRadiusMeters)
        self.cityRadiusMeters = max(0, cityRadiusMeters)
        self.maximumTimeGap = max(0, maximumTimeGap)
        self.overrides = overrides
    }

    /// A shorthand map for callers that only need to force a stop into a
    /// named cluster. The mapping applies at all three levels.
    public init(
        spotRadiusMeters: Double = 1_500,
        areaRadiusMeters: Double = 8_000,
        cityRadiusMeters: Double = 25_000,
        maximumTimeGap: TimeInterval = 24 * 60 * 60,
        overrides: [String: String]
    ) {
        self.init(
            spotRadiusMeters: spotRadiusMeters,
            areaRadiusMeters: areaRadiusMeters,
            cityRadiusMeters: cityRadiusMeters,
            maximumTimeGap: maximumTimeGap,
            overrides: overrides.flatMap { stopID, clusterID in
                PlaceLevel.allCases.map {
                    PlaceOverride(stopID: stopID, level: $0, clusterID: clusterID)
                }
            }
        )
    }

    public func clusters(for stops: [PhotoStop], level: PlaceLevel = .spot) -> [PlaceCluster] {
        let orderedStops = stops.sorted(by: Self.photoOrder)
        // The last override for a stop wins; duplicates must not trap.
        let applicableOverrides = Dictionary(
            overrides.filter { $0.level == level }.map { ($0.stopID, $0) },
            uniquingKeysWith: { _, latest in latest }
        )

        var groups: [String: [PhotoStop]] = [:]
        var groupOverride: [String: PlaceOverride] = [:]
        var automaticStops: [PhotoStop] = []

        for stop in orderedStops {
            if let override = applicableOverrides[stop.id] {
                let key = "override:\(override.clusterID)"
                groups[key, default: []].append(stop)
                groupOverride[key] = groupOverride[key] ?? override
            } else if stop.coordinate != nil {
                automaticStops.append(stop)
            }
        }

        let components = boundedClusters(automaticStops, level: level)
        for component in components {
            guard let anchor = component.first else { continue }
            let id = "\(level.rawValue)-\(Self.stableComponentKey(anchor.id))"
            groups["automatic:\(id)"] = component
        }

        return groups.compactMap { key, members in
            let orderedMembers = members.sorted(by: Self.photoOrder)
            guard let firstDate = orderedMembers.map(\.date).min() else { return nil }
            let points = orderedMembers.compactMap(\.coordinate)
            let override = groupOverride[key]
            return PlaceCluster(
                id: override?.clusterID ?? key.replacingOccurrences(of: "automatic:", with: ""),
                level: level,
                stopIDs: orderedMembers.map(\.id),
                center: GeoPoint.centre(of: points),
                firstDate: firstDate,
                name: override?.name
            )
        }
        .sorted {
            if $0.firstDate != $1.firstDate { return $0.firstDate < $1.firstDate }
            return $0.id < $1.id
        }
    }

    private func boundedClusters(_ stops: [PhotoStop], level: PlaceLevel) -> [[PhotoStop]] {
        guard !stops.isEmpty else { return [] }
        let radius = radiusMeters(for: level)
        var clusters: [RunningPlaceCluster] = []
        clusters.reserveCapacity(stops.count)

        for stop in stops {
            guard let coordinate = stop.coordinate else { continue }

            var nearestIndex: Int?
            var nearestDistance = Double.greatestFiniteMagnitude
            for index in clusters.indices {
                let cluster = clusters[index]
                if level == .spot {
                    let gap = abs(stop.date.timeIntervalSince(cluster.lastDate))
                    guard gap <= maximumTimeGap else { continue }
                }

                let distance = coordinate.distance(to: cluster.center)
                guard distance <= radius else { continue }
                if distance < nearestDistance {
                    nearestDistance = distance
                    nearestIndex = index
                }
            }

            if let nearestIndex {
                clusters[nearestIndex].append(stop, coordinate: coordinate)
            } else {
                clusters.append(RunningPlaceCluster(firstStop: stop, coordinate: coordinate))
            }
        }

        return clusters
            .sorted { Self.photoOrder($0.firstStop, $1.firstStop) }
            .map(\.stops)
    }

    private func radiusMeters(for level: PlaceLevel) -> Double {
        switch level {
        case .spot: return spotRadiusMeters
        case .area: return areaRadiusMeters
        case .city: return cityRadiusMeters
        }
    }

    private static func photoOrder(_ lhs: PhotoStop, _ rhs: PhotoStop) -> Bool {
        if lhs.date != rhs.date { return lhs.date < rhs.date }
        return lhs.id < rhs.id
    }

    private static func stableComponentKey(_ id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unnamed" : trimmed
    }
}

private struct RunningPlaceCluster {
    var stops: [PhotoStop]
    let firstStop: PhotoStop
    var center: GeoPoint
    var lastDate: Date

    private var vectorX: Double
    private var vectorY: Double
    private var vectorZ: Double

    init(firstStop: PhotoStop, coordinate: GeoPoint) {
        self.stops = [firstStop]
        self.firstStop = firstStop
        self.center = coordinate
        self.lastDate = firstStop.date

        let vector = Self.vector(for: coordinate)
        self.vectorX = vector.x
        self.vectorY = vector.y
        self.vectorZ = vector.z
    }

    mutating func append(_ stop: PhotoStop, coordinate: GeoPoint) {
        let vector = Self.vector(for: coordinate)
        vectorX += vector.x
        vectorY += vector.y
        vectorZ += vector.z
        center = Self.center(vectorX: vectorX, vectorY: vectorY, vectorZ: vectorZ)
        lastDate = stop.date
        stops.append(stop)
    }

    private static func vector(for point: GeoPoint) -> (x: Double, y: Double, z: Double) {
        let radians = Double.pi / 180
        let latitude = point.latitude * radians
        let longitude = point.longitude * radians
        let cosLatitude = cos(latitude)
        return (
            x: cosLatitude * cos(longitude),
            y: cosLatitude * sin(longitude),
            z: sin(latitude)
        )
    }

    private static func center(vectorX: Double, vectorY: Double, vectorZ: Double) -> GeoPoint {
        let radians = Double.pi / 180
        let longitude = atan2(vectorY, vectorX) / radians
        let horizontal = sqrt(vectorX * vectorX + vectorY * vectorY)
        let latitude = atan2(vectorZ, horizontal) / radians
        return GeoPoint(latitude: latitude, longitude: longitude)
    }
}
