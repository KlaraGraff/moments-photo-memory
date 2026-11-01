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
    /// the reported view reaching half the globe or more, or a span that is
    /// not finite. The padding never widens the result past the antimeridian.
    private func longitudeHalfSpan(padding: Double) -> Double? {
        guard centerLongitude.isFinite else { return nil }
        let reportedHalfSpan = longitudeDelta / 2
        guard reportedHalfSpan.isFinite, reportedHalfSpan < 180 else { return nil }
        let rawHalfSpan = longitudeDelta * (0.5 + padding)
        guard rawHalfSpan.isFinite else { return nil }
        // Padding that would reach past the antimeridian is dropped: the
        // reported view stays what the camera shows, and only then is the
        // result held just short of half the globe.
        let halfSpan = rawHalfSpan < 180 ? rawHalfSpan : reportedHalfSpan
        return min(max(0, halfSpan), 179.999)
    }

    /// True when the box around the two ends (the shorter way round in
    /// longitude) overlaps the padded region, or — for a long route — when the
    /// great circle drawn between the ends crosses it.
    private func box(_ from: GeoPoint, _ to: GeoPoint, overlaps padding: Double) -> Bool {
        // Fast path: the box around the two ends meets the padded region.
        if endpointBox(from, to, padding: padding) { return true }

        // The map draws a route as a great circle, which bends poleward between
        // its ends, so a route can cross the region while both ends are outside
        // the box. Only long routes bend far enough to be worth sampling.
        let latitudeGap: Double = abs(to.latitude - from.latitude)
        let longitudeGap: Double = abs(Self.wrapped(to.longitude - from.longitude))
        guard latitudeGap > 10 || longitudeGap > 10 else { return false }

        // Each piece between two neighbouring samples is short enough that its
        // own endpoint box covers the drawn line, so test the pieces and never
        // sample them again.
        let samples: [GeoPoint] = Self.greatCirclePoints(from, to, count: 16)
        for index in 0..<(samples.count - 1) {
            if endpointBox(samples[index], samples[index + 1], padding: padding) {
                return true
            }
        }
        return false
    }

    /// True when the box around the two points (the shorter way round in
    /// longitude) overlaps the padded region.
    private func endpointBox(_ from: GeoPoint, _ to: GeoPoint, padding: Double) -> Bool {
        if let range = latitudeRange(padding: padding) {
            let lower: Double = min(from.latitude, to.latitude)
            let upper: Double = max(from.latitude, to.latitude)
            guard lower <= range.upperBound, upper >= range.lowerBound else { return false }
        }
        guard let halfSpan = longitudeHalfSpan(padding: padding) else { return true }

        let delta: Double = Self.wrapped(to.longitude - from.longitude)
        let boxLower: Double = min(from.longitude, from.longitude + delta)
        let boxUpper: Double = max(from.longitude, from.longitude + delta)
        let regionLower: Double = centerLongitude - halfSpan
        let regionUpper: Double = centerLongitude + halfSpan
        // Both the box and the region lie within about -360…360, so shifting
        // the box by whole turns one either way is enough to find a meeting
        // point on the circle.
        for turn in -2...2 {
            let shift: Double = Double(turn) * 360
            if boxUpper + shift >= regionLower, boxLower + shift <= regionUpper {
                return true
            }
        }
        return false
    }

    /// Points along the great circle from `from` to `to`, both ends included,
    /// by spherical linear interpolation of the two unit vectors.
    private static func greatCirclePoints(_ from: GeoPoint, _ to: GeoPoint, count: Int) -> [GeoPoint] {
        guard count > 1 else { return count == 1 ? [from] : [] }

        var points: [GeoPoint] = []
        points.reserveCapacity(count)
        let radians: Double = Double.pi / 180
        let fromLatitude: Double = from.latitude * radians
        let fromLongitude: Double = from.longitude * radians
        let toLatitude: Double = to.latitude * radians
        let toLongitude: Double = to.longitude * radians
        let fromX: Double = cos(fromLatitude) * cos(fromLongitude)
        let fromY: Double = cos(fromLatitude) * sin(fromLongitude)
        let fromZ: Double = sin(fromLatitude)
        let toX: Double = cos(toLatitude) * cos(toLongitude)
        let toY: Double = cos(toLatitude) * sin(toLongitude)
        let toZ: Double = sin(toLatitude)
        let dot: Double = min(1, max(-1, fromX * toX + fromY * toY + fromZ * toZ))
        let angle: Double = acos(dot)
        let sinAngle: Double = sin(angle)

        if sinAngle < 1e-9 {
            // The ends coincide (or are antipodal, where the great circle is
            // not unique): fall back to a straight interpolation.
            let deltaLongitude: Double = wrapped(to.longitude - from.longitude)
            for index in 0..<count {
                let fraction: Double = Double(index) / Double(count - 1)
                let latitude: Double = from.latitude + (to.latitude - from.latitude) * fraction
                let longitude: Double = from.longitude + deltaLongitude * fraction
                points.append(GeoPoint(latitude: latitude, longitude: longitude))
            }
            return points
        }

        for index in 0..<count {
            let fraction: Double = Double(index) / Double(count - 1)
            let fromWeight: Double = sin((1 - fraction) * angle) / sinAngle
            let toWeight: Double = sin(fraction * angle) / sinAngle
            let x: Double = fromWeight * fromX + toWeight * toX
            let y: Double = fromWeight * fromY + toWeight * toY
            let z: Double = fromWeight * fromZ + toWeight * toZ
            let length: Double = sqrt(x * x + y * y + z * z)
            guard length > 0 else {
                points.append(GeoPoint(latitude: from.latitude, longitude: from.longitude))
                continue
            }
            let latitude: Double = asin(min(1, max(-1, z / length))) / radians
            let longitude: Double = atan2(y, x) / radians
            points.append(GeoPoint(latitude: latitude, longitude: longitude))
        }
        // Both ends exactly as given, without rounding through the vectors.
        points[0] = from
        points[count - 1] = to
        return points
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
