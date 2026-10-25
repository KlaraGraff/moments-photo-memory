import Foundation
import MapKit
import MomentsCore

/// Pure data preparation for the Places screen. Keeping clustering and selection
/// decisions here makes them deterministic and testable without rendering a map.
struct PlacesViewModel {
    struct SpanThresholds: Equatable, Sendable {
        var city: Double = 2.0
        var area: Double = 0.35

        init(city: Double = 2.0, area: Double = 0.35) {
            self.city = max(area, city)
            self.area = max(0, area)
        }
    }

    struct Snapshot {
        let level: PlaceLevel
        let stops: [PhotoStop]
        let clusters: [PlaceCluster]
        let routeSegments: [RouteSegment]
        let coordinateByID: [String: GeoPoint]

        var isEmpty: Bool { clusters.isEmpty }

        func cluster(containing itemID: String) -> PlaceCluster? {
            clusters.first { $0.stopIDs.contains(itemID) }
        }
    }

    var clusterer: PlaceClusterer
    var thresholds: SpanThresholds

    init(clusterer: PlaceClusterer = PlaceClusterer(), thresholds: SpanThresholds = SpanThresholds()) {
        self.clusterer = clusterer
        self.thresholds = thresholds
    }

    /// MapKit reports a latitude span in degrees. A wide viewport uses city
    /// clusters and overview routes; a close viewport uses spots and local
    /// routes, with an area level between them for a smooth transition.
    func level(for latitudeDelta: Double) -> PlaceLevel {
        guard latitudeDelta.isFinite else { return .spot }
        if latitudeDelta >= thresholds.city { return .city }
        if latitudeDelta >= thresholds.area { return .area }
        return .spot
    }

    /// Library owns the filter result. Places only applies that result and
    /// never reconstructs trip, date, or favorite predicates independently.
    func filteredItems(_ items: [MediaItem], visibleItemIDs: Set<String>?) -> [MediaItem] {
        let filtered = items.filter { item in
            visibleItemIDs?.contains(item.id) ?? true
        }
        return filtered.sorted { lhs, rhs in
            let leftDate = lhs.captureDate ?? .distantPast
            let rightDate = rhs.captureDate ?? .distantPast
            if leftDate != rightDate { return leftDate < rightDate }
            return lhs.id < rhs.id
        }
    }

    func photoStops(from items: [MediaItem], visibleItemIDs: Set<String>?) -> [PhotoStop] {
        filteredItems(items, visibleItemIDs: visibleItemIDs).map { item in
            PhotoStop(
                id: item.id,
                date: item.captureDate ?? .distantPast,
                coordinate: coordinate(for: item)
            )
        }
    }

    func snapshot(
        items: [MediaItem],
        visibleItemIDs: Set<String>?,
        latitudeDelta: Double
    ) -> Snapshot {
        let stops = photoStops(from: items, visibleItemIDs: visibleItemIDs)
        let level = level(for: latitudeDelta)
        let clusters = clusterer.clusters(for: stops, level: level)
        let routeSegments: [RouteSegment]
        switch level {
        case .city:
            routeSegments = RouteBuilder(stops: stops, clusterer: clusterer).overview(level: .city)
        case .area:
            routeSegments = RouteBuilder(stops: stops, clusterer: clusterer).local(level: .area)
        case .spot:
            routeSegments = RouteBuilder(stops: stops, clusterer: clusterer).local(level: .spot)
        }
        let coordinateByID: [String: GeoPoint] = Dictionary(
            uniqueKeysWithValues: stops.compactMap { stop in
                guard let coordinate = stop.coordinate else { return nil }
                return (stop.id, coordinate)
            }
        )
        return Snapshot(
            level: level,
            stops: stops,
            clusters: clusters,
            routeSegments: routeSegments,
            coordinateByID: coordinateByID
        )
    }

    func selectedCluster(in snapshot: Snapshot, selectedItemIDs: Set<String>, focusedItemID: String?) -> PlaceCluster? {
        if let focusedItemID, let cluster = snapshot.cluster(containing: focusedItemID) {
            return cluster
        }
        return snapshot.clusters.first { cluster in
            !selectedItemIDs.isDisjoint(with: cluster.stopIDs)
        }
    }

    func selectionIDs(for cluster: PlaceCluster) -> Set<String> {
        Set(cluster.stopIDs)
    }

    func coordinate(for item: MediaItem) -> GeoPoint? {
        guard let latitude = item.latitude, let longitude = item.longitude else { return nil }
        return GeoPoint(latitude: latitude, longitude: longitude)
    }

    func initialRegion(for stops: [PhotoStop]) -> MKCoordinateRegion {
        let points = stops.compactMap(\.coordinate)
        guard let centre = GeoPoint.centre(of: points) else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                span: MKCoordinateSpan(latitudeDelta: 30, longitudeDelta: 30)
            )
        }
        let latitudes = points.map(\.latitude)
        let longitudes = points.map(\.longitude)
        let latitudeSpan = boundedSpan((latitudes.max() ?? centre.latitude) - (latitudes.min() ?? centre.latitude))
        let longitudeSpan = boundedSpan((longitudes.max() ?? centre.longitude) - (longitudes.min() ?? centre.longitude))
        return MKCoordinateRegion(
            center: centre.coordinate,
            span: MKCoordinateSpan(latitudeDelta: latitudeSpan, longitudeDelta: longitudeSpan)
        )
    }

    func focusRegion(for coordinate: GeoPoint, latitudeDelta: Double? = nil) -> MKCoordinateRegion {
        let span = max(0.03, min(30, latitudeDelta ?? thresholds.area / 2))
        return MKCoordinateRegion(
            center: coordinate.coordinate,
            span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)
        )
    }

    private func boundedSpan(_ rawSpan: Double) -> Double {
        max(0.03, min(170, rawSpan * 1.45))
    }
}
