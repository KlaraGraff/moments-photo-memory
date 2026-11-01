import Foundation

/// The map region on screen, in terms that can be tested without MapKit.
///
/// A point is inside when it lies in the region grown by `padding` times the
/// region's span on every side. Longitudes wrap at the antimeridian, and a
/// segment's bounding box takes the shorter way round between its two ends.
public struct MapViewport: Equatable, Sendable {
    public let centerLatitude: Double
    public let centerLongitude: Double
    public let latitudeDelta: Double
    public let longitudeDelta: Double

    public init(
        centerLatitude: Double,
        centerLongitude: Double,
        latitudeDelta: Double,
        longitudeDelta: Double
    ) {
        self.centerLatitude = centerLatitude
        self.centerLongitude = centerLongitude
        self.latitudeDelta = latitudeDelta
        self.longitudeDelta = longitudeDelta
    }

    /// True when the point lies inside the region grown by `padding` times
    /// its span on every side (0.5 = half a screen around it).
    public func contains(_ point: GeoPoint, padding: Double = 0.5) -> Bool {
        if let range = latitudeRange(padding: padding), !range.contains(point.latitude) {
            return false
        }
        if let halfSpan = longitudeHalfSpan(padding: padding) {
            let difference = Self.wrapped(point.longitude - centerLongitude)
            guard abs(difference) <= halfSpan else { return false }
        }
        return true
    }

    /// The clusters with a centre inside the padded region, in input order.
    public func clusters(_ clusters: [PlaceCluster], padding: Double = 0.5) -> [PlaceCluster] {
        clusters.filter { cluster in
            guard let center = cluster.center else { return false }
            return contains(center, padding: padding)
        }
    }

    /// The segments with either end inside the padded region, or whose
    /// bounding box overlaps it, in input order.
    public func segments(_ segments: [RouteSegment], padding: Double = 0.5) -> [RouteSegment] {
        segments.filter { segment in
            guard let from = segment.from.center, let to = segment.to.center else { return false }
            return box(from, to, overlaps: padding)
        }
    }

    // MARK: - Region maths

    /// The padded latitude range, or nil when every latitude matches: a span
    /// covering the whole ±90° range, or one that is not finite.
    private func latitudeRange(padding: Double) -> ClosedRange<Double>? {
        guard centerLatitude.isFinite else { return nil }
        let rawHalfSpan = latitudeDelta * (0.5 + padding)
        guard rawHalfSpan.isFinite else { return nil }
        let halfSpan = max(0, rawHalfSpan)
        guard halfSpan < 90 else { return nil }
        let centre = min(90, max(-90, centerLatitude))
        return (centre - halfSpan)...(centre + halfSpan)
    }

    /// Half the padded longitude span, or nil when every longitude matches:
    /// half the globe or more, or a span that is not finite.
    private func longitudeHalfSpan(padding: Double) -> Double? {
        guard centerLongitude.isFinite else { return nil }
        let rawHalfSpan = longitudeDelta * (0.5 + padding)
        guard rawHalfSpan.isFinite else { return nil }
        guard rawHalfSpan < 180 else { return nil }
        return max(0, rawHalfSpan)
    }

    /// True when the box around the two ends (the shorter way round in
    /// longitude) overlaps the padded region.
    private func box(_ from: GeoPoint, _ to: GeoPoint, overlaps padding: Double) -> Bool {
        if let range = latitudeRange(padding: padding) {
            let lower = min(from.latitude, to.latitude)
            let upper = max(from.latitude, to.latitude)
            guard lower <= range.upperBound, upper >= range.lowerBound else { return false }
        }
        guard let halfSpan = longitudeHalfSpan(padding: padding) else { return true }

        let delta = Self.wrapped(to.longitude - from.longitude)
        let boxLower = min(from.longitude, from.longitude + delta)
        let boxUpper = max(from.longitude, from.longitude + delta)
        let regionLower = centerLongitude - halfSpan
        let regionUpper = centerLongitude + halfSpan
        // Both the box and the region lie within about -360…360, so shifting
        // the box by whole turns one either way is enough to find a meeting
        // point on the circle.
        for turn in -2...2 {
            let shift = Double(turn) * 360
            if boxUpper + shift >= regionLower, boxLower + shift <= regionUpper {
                return true
            }
        }
        return false
    }

    /// A difference of longitudes folded into -180…180.
    private static func wrapped(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        var wrapped = value.truncatingRemainder(dividingBy: 360)
        if wrapped > 180 { wrapped -= 360 }
        if wrapped < -180 { wrapped += 360 }
        return wrapped
    }
}
