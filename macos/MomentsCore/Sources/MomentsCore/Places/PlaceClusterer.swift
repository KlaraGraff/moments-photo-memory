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

        let components = connectedComponents(automaticStops, level: level)
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

    private func connectedComponents(_ stops: [PhotoStop], level: PlaceLevel) -> [[PhotoStop]] {
        guard !stops.isEmpty else { return [] }
        var unionFind = UnionFind(count: stops.count)
        let radius = radiusMeters(for: level)

        for left in stops.indices {
            guard let leftCoordinate = stops[left].coordinate else { continue }
            for right in stops.index(after: left)..<stops.endIndex {
                guard let rightCoordinate = stops[right].coordinate else { continue }
                guard leftCoordinate.distance(to: rightCoordinate) <= radius else { continue }
                if level == .spot {
                    let gap = abs(stops[left].date.timeIntervalSince(stops[right].date))
                    guard gap <= maximumTimeGap else { continue }
                }
                unionFind.union(left, right)
            }
        }

        var components: [Int: [PhotoStop]] = [:]
        for index in stops.indices {
            components[unionFind.find(index), default: []].append(stops[index])
        }
        return components.values
            .map { $0.sorted(by: Self.photoOrder) }
            .sorted {
                guard let lhs = $0.first, let rhs = $1.first else { return $0.count < $1.count }
                return Self.photoOrder(lhs, rhs)
            }
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

private struct UnionFind {
    private var parents: [Int]
    private var ranks: [Int]

    init(count: Int) {
        parents = Array(0..<count)
        ranks = Array(repeating: 0, count: count)
    }

    mutating func find(_ value: Int) -> Int {
        if parents[value] != value {
            parents[value] = find(parents[value])
        }
        return parents[value]
    }

    mutating func union(_ lhs: Int, _ rhs: Int) {
        let left = find(lhs)
        let right = find(rhs)
        guard left != right else { return }

        if ranks[left] < ranks[right] {
            parents[left] = right
        } else if ranks[left] > ranks[right] {
            parents[right] = left
        } else {
            parents[right] = left
            ranks[left] += 1
        }
    }
}
