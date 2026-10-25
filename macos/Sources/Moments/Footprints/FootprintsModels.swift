import CoreLocation
import Foundation
import MomentsCore

struct FootprintsGeocodeResult: Codable, Equatable, Hashable, Sendable {
    let countryCode: String?
    let countryName: String?

    static let ocean = FootprintsGeocodeResult(countryCode: nil, countryName: nil)

    var isOcean: Bool {
        countryCode == nil && countryName == nil
    }

    var displayName: String {
        countryName ?? String(localized: "Open ocean")
    }

    var flagEmoji: String {
        guard let countryCode else { return "🌊" }
        return FootprintsCountrySummary.flagEmoji(for: countryCode)
    }
}

struct FootprintsStatistics: Equatable {
    let countryCount: Int
    let cityCount: Int
    let kilometres: Double

    var formattedKilometres: String {
        kilometres.formatted(.number.precision(.fractionLength(kilometres < 100 ? 1 : 0)))
    }
}

struct FootprintsCameraTarget: Equatable {
    let center: GeoPoint
    let distanceMetres: Double

    static let globeDistanceMetres = 20_000_000.0

    var coordinate: CLLocationCoordinate2D { center.coordinate }
}

struct FootprintsCountrySummary: Identifiable, Equatable {
    let id: String
    let name: String
    let flag: String
    let photoCount: Int
    let clusterIDs: [String]
    let centers: [GeoPoint]

    var firstCenter: GeoPoint? { centers.first }

    static func build(
        clusters: [PlaceCluster],
        geocoding: [String: FootprintsGeocodeResult]
    ) -> [FootprintsCountrySummary] {
        struct Accumulator {
            var name: String
            var flag: String
            var photoCount = 0
            var clusterIDs: [String] = []
            var centers: [GeoPoint] = []
        }

        var grouped: [String: Accumulator] = [:]
        for cluster in clusters {
            let (id, name, flag): (String, String, String) = if let result = geocoding[cluster.id] {
                (
                    result.countryCode?.uppercased() ?? "ocean",
                    result.displayName,
                    result.flagEmoji
                )
            } else {
                ("unknown", String(localized: "Unknown location"), "🌐")
            }
            var accumulator = grouped[id] ?? Accumulator(
                name: name,
                flag: flag
            )
            accumulator.photoCount += cluster.stopIDs.count
            accumulator.clusterIDs.append(cluster.id)
            if let center = cluster.center {
                accumulator.centers.append(center)
            }
            grouped[id] = accumulator
        }

        return grouped.map { id, accumulator in
            FootprintsCountrySummary(
                id: id,
                name: accumulator.name,
                flag: accumulator.flag,
                photoCount: accumulator.photoCount,
                clusterIDs: accumulator.clusterIDs.sorted(),
                centers: accumulator.centers
            )
        }
        .sorted {
            if $0.id == "ocean" { return false }
            if $1.id == "ocean" { return true }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func flagEmoji(for countryCode: String) -> String {
        let scalars = countryCode.uppercased().unicodeScalars
        guard scalars.count == 2,
              scalars.allSatisfy({ $0.value >= 65 && $0.value <= 90 }) else {
            return "🌐"
        }
        return scalars
            .map { String(UnicodeScalar(127397 + $0.value)!) }
            .joined()
    }
}

struct FootprintsInput: Equatable, Sendable {
    let stops: [PhotoStop]

    var signature: String {
        stops.map { stop in
            let coordinate = stop.coordinate.map { "\($0.latitude),\($0.longitude)" } ?? "-"
            return "\(stop.id)|\(stop.date.timeIntervalSince1970)|\(coordinate)"
        }.joined(separator: ";")
    }
}

struct FootprintsSnapshot: Equatable {
    let cityClusters: [PlaceCluster]
    let overviewSegments: [RouteSegment]
    let cameraTarget: FootprintsCameraTarget

    static let empty = FootprintsSnapshot(
        cityClusters: [],
        overviewSegments: [],
        cameraTarget: FootprintsCameraTarget(
            center: GeoPoint(latitude: 20, longitude: 0),
            distanceMetres: FootprintsCameraTarget.globeDistanceMetres
        )
    )

    var photoCount: Int {
        cityClusters.reduce(0) { $0 + $1.stopIDs.count }
    }
}

enum FootprintsCalculator {
    static func input(from items: [MediaItem], visibleItemIDs: Set<String>?) -> FootprintsInput {
        let stops = items.compactMap { item -> PhotoStop? in
            guard visibleItemIDs?.contains(item.id) ?? true,
                  let latitude = item.latitude,
                  let longitude = item.longitude,
                  latitude.isFinite,
                  longitude.isFinite else {
                return nil
            }
            return PhotoStop(
                id: item.id,
                date: item.captureDate ?? .distantPast,
                coordinate: GeoPoint(latitude: latitude, longitude: longitude)
            )
        }
        .sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.id < $1.id
        }
        return FootprintsInput(stops: stops)
    }

    static func snapshot(for input: FootprintsInput) -> FootprintsSnapshot {
        let clusterer = PlaceClusterer()
        let clusters = clusterer.clusters(for: input.stops, level: .city)
        let routes = RouteBuilder(stops: input.stops, clusterer: clusterer).overview(level: .city)
        return FootprintsSnapshot(
            cityClusters: clusters,
            overviewSegments: routes,
            cameraTarget: cameraTarget(for: clusters)
        )
    }

    static func cameraTarget(for clusters: [PlaceCluster]) -> FootprintsCameraTarget {
        let points = clusters.compactMap(\.center)
        let centre = GeoPoint.centre(of: points) ?? GeoPoint(latitude: 20, longitude: 0)
        // A very high latitude makes a globe camera look at the pole. Keep the
        // useful regional centre while ensuring the initial view is mid-latitude.
        let boundedLatitude = min(65, max(-65, centre.latitude))
        return FootprintsCameraTarget(
            center: GeoPoint(latitude: boundedLatitude, longitude: centre.longitude),
            distanceMetres: FootprintsCameraTarget.globeDistanceMetres
        )
    }

    static func statistics(
        for snapshot: FootprintsSnapshot,
        geocoding: [String: FootprintsGeocodeResult]
    ) -> FootprintsStatistics {
        let countryCodes = Set(
            snapshot.cityClusters.compactMap { geocoding[$0.id]?.countryCode?.uppercased() }
        )
        return FootprintsStatistics(
            countryCount: countryCodes.count,
            cityCount: snapshot.cityClusters.count,
            kilometres: snapshot.overviewSegments.reduce(0) { $0 + $1.distanceKilometers }
        )
    }
}
