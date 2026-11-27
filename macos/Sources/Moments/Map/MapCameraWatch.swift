import MapKit
import MomentsCore

/// What the map screen remembers about its camera between redraws: the last
/// camera MapKit reported and the flight under way. A plain object, so
/// updating it on every frame of a move never redraws the screen.
@MainActor
final class MapCameraWatch {
    var latest: MapFlightCamera?
    private(set) var flightTarget: MapFlightCamera?
    private var flightToken = 0

    /// Starts a flight and returns its token; a newer flight replaces it.
    func beginFlight(to target: MapFlightCamera) -> Int {
        flightToken &+= 1
        flightTarget = target
        return flightToken
    }

    func isCurrentFlight(_ token: Int) -> Bool {
        flightTarget != nil && token == flightToken
    }

    func endFlight() {
        flightTarget = nil
    }
}

extension MapFlightCamera {
    init(_ camera: MapCamera) {
        self.init(
            latitude: camera.centerCoordinate.latitude,
            longitude: camera.centerCoordinate.longitude,
            distance: camera.distance,
            heading: camera.heading,
            pitch: camera.pitch
        )
    }

    /// The same view for all practical purposes: within 2 % in distance and
    /// a hundredth of the visible height off centre.
    func isClose(to other: MapFlightCamera) -> Bool {
        let ratio: Double = distance / max(1, other.distance)
        guard ratio > 0.98, ratio < 1.02 else { return false }
        let visibleHeight: Double = other.distance * MapFlight.visibleHeightPerMetre
        let north: Double = (latitude - other.latitude) * 111_320
        let east: Double = (longitude - other.longitude) * 111_320 * cos(other.latitude * Double.pi / 180)
        return (north * north + east * east).squareRoot() < visibleHeight * 0.01
    }
}

extension MapCamera {
    init(_ camera: MapFlightCamera) {
        self.init(
            centerCoordinate: CLLocationCoordinate2D(latitude: camera.latitude, longitude: camera.longitude),
            distance: camera.distance,
            heading: camera.heading,
            pitch: camera.pitch
        )
    }
}
