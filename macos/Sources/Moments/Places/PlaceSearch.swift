import CoreLocation
import Foundation
import MapKit
import MomentsCore

/// One place a search found, for the Set Location sheet.
struct PlaceSearchResult: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let detail: String
    let point: GeoPoint
}

/// Looks places up by name. The app uses Apple Maps' local search (the words
/// typed and the map's area go to Apple, as in Maps); UI tests use a
/// synthetic list and never reach the network.
protocol PlaceSearching: Sendable {
    func search(_ query: String, near region: MKCoordinateRegion?) async throws -> [PlaceSearchResult]
    /// A short name for a point dropped by hand, or nil.
    func name(of point: GeoPoint) async -> String?
}

enum PlaceSearch {
    static var current: any PlaceSearching {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-MomentsUITesting") { return SyntheticPlaceSearch() }
        #endif
        return MapKitPlaceSearch()
    }
}

struct MapKitPlaceSearch: PlaceSearching {
    func search(_ query: String, near region: MKCoordinateRegion?) async throws -> [PlaceSearchResult] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.pointOfInterest, .address]
        if let region { request.region = region }
        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems.prefix(8).enumerated().map { index, mapItem in
            let placemark = mapItem.placemark
            let name = mapItem.name ?? placemark.name ?? query
            let detail = [placemark.locality, placemark.administrativeArea, placemark.country]
                .compactMap { $0 }
                .filter { $0 != name }
                .joined(separator: ", ")
            return PlaceSearchResult(
                id: "\(index)",
                name: name,
                detail: detail,
                point: GeoPoint(placemark.coordinate)
            )
        }
    }

    func name(of point: GeoPoint) async -> String? {
        let location = CLLocation(latitude: point.latitude, longitude: point.longitude)
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
        return placemark.name ?? placemark.locality
    }
}

#if DEBUG
/// UI tests: two made-up places near 0,0 for any words, none for
/// "nothing", and a failure for "offline".
struct SyntheticPlaceSearch: PlaceSearching {
    static let harbour = GeoPoint(latitude: 0.3, longitude: 0.3)

    func search(_ query: String, near region: MKCoordinateRegion?) async throws -> [PlaceSearchResult] {
        try await Task.sleep(for: .milliseconds(150))
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if words == "offline" { throw URLError(.notConnectedToInternet) }
        if words == "nothing" { return [] }
        return [
            PlaceSearchResult(id: "0", name: "Synthetic Harbour", detail: "Synthetic Bay", point: Self.harbour),
            PlaceSearchResult(id: "1", name: "Synthetic Market", detail: "Synthetic Bay", point: GeoPoint(latitude: 0.31, longitude: 0.29)),
        ]
    }

    func name(of point: GeoPoint) async -> String? { nil }
}
#endif
