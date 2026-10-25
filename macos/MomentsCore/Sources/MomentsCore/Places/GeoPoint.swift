import CoreLocation
import Foundation

/// A small, Sendable value type for a geographic coordinate.
public struct GeoPoint: Equatable, Hashable, Sendable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = Self.clampedLatitude(latitude)
        self.longitude = Self.wrappedLongitude(longitude)
    }

    public init(_ coordinate: CLLocationCoordinate2D) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Great-circle distance in metres. The longitude delta is wrapped, so
    /// points on either side of the antimeridian take the short path.
    public func distance(to other: GeoPoint) -> Double {
        let radians = Double.pi / 180
        let latitude1 = latitude * radians
        let latitude2 = other.latitude * radians
        let deltaLatitude = (other.latitude - latitude) * radians
        let deltaLongitude = atan2(
            sin((other.longitude - longitude) * radians),
            cos((other.longitude - longitude) * radians)
        )

        let haversine = sin(deltaLatitude / 2) * sin(deltaLatitude / 2)
            + cos(latitude1) * cos(latitude2)
            * sin(deltaLongitude / 2) * sin(deltaLongitude / 2)
        let bounded = min(1, max(0, haversine))
        return 6_371_000 * 2 * atan2(sqrt(bounded), sqrt(1 - bounded))
    }

    /// Returns the geographic centre of the supplied points. A vector mean is
    /// used for longitude so a group around ±180° does not average through 0°.
    public static func centre(of points: [GeoPoint]) -> GeoPoint? {
        guard !points.isEmpty else { return nil }

        let radians = Double.pi / 180
        var x = 0.0
        var y = 0.0
        var z = 0.0

        for point in points {
            let latitude = point.latitude * radians
            let longitude = point.longitude * radians
            let cosLatitude = cos(latitude)
            x += cosLatitude * cos(longitude)
            y += cosLatitude * sin(longitude)
            z += sin(latitude)
        }

        let count = Double(points.count)
        let meanX = x / count
        let meanY = y / count
        let meanZ = z / count
        let longitude = atan2(meanY, meanX) / radians
        let horizontal = sqrt(meanX * meanX + meanY * meanY)
        let latitude = atan2(meanZ, horizontal) / radians
        return GeoPoint(latitude: latitude, longitude: longitude)
    }

    private static func clampedLatitude(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(90, max(-90, value))
    }

    private static func wrappedLongitude(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        var wrapped = value.truncatingRemainder(dividingBy: 360)
        if wrapped > 180 { wrapped -= 360 }
        if wrapped < -180 { wrapped += 360 }
        return wrapped
    }
}
