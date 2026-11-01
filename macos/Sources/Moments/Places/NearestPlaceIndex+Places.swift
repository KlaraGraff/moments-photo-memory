import Foundation
import MomentsCore

extension NearestPlaceIndex {
    /// The named places with a coordinate, in the order given, so ties go
    /// to the same place a scan of `places` would pick.
    @MainActor
    init(places: [Place]) {
        self.init(entries: places.compactMap { place in
            guard let latitude = place.latitude, let longitude = place.longitude,
                  let name = PlaceDisplayName.resolvedName(of: place) else { return nil }
            return Entry(point: GeoPoint(latitude: latitude, longitude: longitude), name: name)
        })
    }

    /// The photo's nearest named place within 100 km, as the Timeline and
    /// Chapters pages label a day's places.
    @MainActor
    func nearestPlaceName(for item: MediaItem) -> String? {
        guard let latitude = item.latitude, let longitude = item.longitude else { return nil }
        return nearestName(to: GeoPoint(latitude: latitude, longitude: longitude), within: 100_000)
    }
}
