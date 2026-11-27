import Foundation

/// Where the map camera looks from, in terms that can be tested without MapKit.
public struct MapFlightCamera: Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    /// Metres from the camera to the point in the middle of the map.
    public var distance: Double
    public var heading: Double
    public var pitch: Double

    public init(latitude: Double, longitude: Double, distance: Double, heading: Double = 0, pitch: Double = 0) {
        self.latitude = latitude
        self.longitude = longitude
        self.distance = distance
        self.heading = heading
        self.pitch = pitch
    }
}

/// The camera's way from one view of the map to another.
///
/// Zoom is felt as a ratio, not as metres: going from 20,000 km to 10 km
/// with the distance changing at an even rate in metres spends almost all of
/// the time on the first halving and squeezes the last ten zoom levels into
/// the final frames, which looks like a jump and leaves no time for the map
/// to draw. So the flight follows van Wijk and Nuij's path ("Smooth and
/// efficient zooming and panning", 2003): every zoom level and every screen
/// of panning gets the same share of time, and a long way between two close
/// views rises out far enough to see both ends before coming back down.
/// On top of that the time runs on an ease-in-out curve: the camera starts
/// slowly, is fastest halfway and settles slowly. The duration grows with
/// the length of the path, so a short hop stays quick.
public struct MapFlight: Sendable {
    public let start: MapFlightCamera
    public let end: MapFlightCamera
    /// Seconds from start to end.
    public let duration: Double
    /// The path's length in van Wijk's units (about one screen of zooming or
    /// panning each); zero when start and end are the same view.
    public let pathLength: Double

    /// How far out the camera may go on the way; never below either end.
    private let distanceCeiling: Double
    private let shape: Shape

    /// MapKit's camera sees 30° vertically, so it sees a strip of ground
    /// `2 × tan(15°)` times its distance high.
    public static let visibleHeightPerMetre: Double = 2 * tan(15 * Double.pi / 180)
    /// How much a flight trades zooming out for panning (van Wijk's ρ). √2 is
    /// the usual choice: far hops rise out to see both ends, near ones barely.
    public static let zoomOutBalance: Double = 2.0.squareRoot()
    public static let shortestDuration: Double = 0.6
    public static let longestDuration: Double = 1.6

    private static let metresPerDegree: Double = 111_320

    private enum Shape: Sendable {
        /// Start and end share a centre: only the distance changes.
        case zoom(logRatio: Double)
        /// van Wijk's path between two centres `groundDistance` metres apart.
        case path(groundDistance: Double, r0: Double, coshR0: Double, sinhR0: Double, endFraction: Double)
    }

    /// - Parameter distanceCeiling: the farthest the camera may rise on the
    ///   way, for example the whole-globe view. The ends are never clipped.
    public init(from start: MapFlightCamera, to end: MapFlightCamera, distanceCeiling: Double = .infinity) {
        let start = Self.normalised(start)
        let end = Self.normalised(end)
        self.start = start
        self.end = end
        self.distanceCeiling = max(distanceCeiling, start.distance, end.distance)

        let rho: Double = Self.zoomOutBalance
        let w0: Double = start.distance * Self.visibleHeightPerMetre
        let w1: Double = end.distance * Self.visibleHeightPerMetre
        let ground: Double = Self.groundDistance(from: start, to: end)

        var length: Double = abs(log(w1 / w0)) / rho
        var shape: Shape = .zoom(logRatio: log(w1 / w0))
        // Closer than a metre counts as the same centre: only the zoom changes.
        if ground >= 1 {
            let rho2: Double = rho * rho
            let rho4: Double = rho2 * rho2
            let b0: Double = (w1 * w1 - w0 * w0 + rho4 * ground * ground) / (2 * w0 * rho2 * ground)
            let b1: Double = (w1 * w1 - w0 * w0 - rho4 * ground * ground) / (2 * w1 * rho2 * ground)
            // log(√(b² + 1) − b) in the paper; −asinh(b) is the same value
            // without losing every digit when b is large, as it is when the
            // camera rises from a close view to a centre a few metres away.
            let r0: Double = -asinh(b0)
            let r1: Double = -asinh(b1)
            let pathLength: Double = (r1 - r0) / rho
            let coshR0: Double = cosh(r0)
            let sinhR0: Double = sinh(r0)
            // In exact arithmetic the path ends at 1; dividing by the computed
            // end keeps rounding from leaving the camera a little short.
            let endScale: Double = w0 / (rho2 * ground)
            let rawEnd: Double = endScale * (coshR0 * tanh(rho * pathLength + r0) - sinhR0)
            let values: [Double] = [r0, pathLength, coshR0, sinhR0, rawEnd]
            if values.allSatisfy(\.isFinite), rawEnd > 0, pathLength >= 0 {
                length = pathLength
                shape = .path(groundDistance: ground, r0: r0, coshR0: coshR0, sinhR0: sinhR0, endFraction: rawEnd)
            }
            // Otherwise the plain zoom below, with the centre gliding along:
            // never a frame of NaN for MapKit.
        }
        self.shape = shape
        pathLength = length.isFinite ? max(0, length) : 0
        duration = Self.duration(forPathLength: pathLength)
    }

    /// Longer paths take longer, between `shortestDuration` and `longestDuration`.
    public static func duration(forPathLength length: Double) -> Double {
        min(longestDuration, max(shortestDuration, 0.5 + 0.2 * length))
    }

    /// Slow start, fastest at the middle, slow finish.
    public static func eased(_ progress: Double) -> Double {
        let clamped: Double = min(1, max(0, progress))
        return (1 - cos(Double.pi * clamped)) / 2
    }

    /// The camera `time` seconds into the flight.
    public func camera(at time: Double) -> MapFlightCamera {
        guard duration > 0, time < duration else { return end }
        guard time > 0 else { return start }
        let progress: Double = Self.eased(time / duration)
        let (fraction, distance) = position(atProgress: progress)
        guard fraction.isFinite, distance.isFinite else { return end }
        return MapFlightCamera(
            latitude: start.latitude + (end.latitude - start.latitude) * fraction,
            longitude: start.longitude + (end.longitude - start.longitude) * fraction,
            distance: min(distance, distanceCeiling),
            heading: start.heading + Self.headingChange(from: start.heading, to: end.heading) * progress,
            pitch: start.pitch + (end.pitch - start.pitch) * progress
        )
    }

    /// How far along the ground the centre has come (0…1), and the distance.
    private func position(atProgress progress: Double) -> (Double, Double) {
        let s: Double = progress * pathLength
        let rho: Double = Self.zoomOutBalance
        let w0: Double = start.distance * Self.visibleHeightPerMetre
        switch shape {
        case .zoom(let logRatio):
            // Even steps in the logarithm of the distance.
            let distance: Double = start.distance * exp(logRatio * progress)
            return (progress, distance)
        case .path(let ground, let r0, let coshR0, let sinhR0, let endFraction):
            let rawFraction: Double = w0 / (rho * rho * ground) * (coshR0 * tanh(rho * s + r0) - sinhR0)
            let fraction: Double = endFraction > 0 ? rawFraction / endFraction : progress
            let width: Double = w0 * coshR0 / cosh(rho * s + r0)
            return (min(1, max(0, fraction)), width / Self.visibleHeightPerMetre)
        }
    }

    /// Metres along the ground between the two centres, on a flat map around
    /// their mean latitude. Longitude never wraps: the flight stays on one
    /// side of the antimeridian so the centre never sweeps the long way
    /// round between two frames.
    private static func groundDistance(from start: MapFlightCamera, to end: MapFlightCamera) -> Double {
        let meanLatitude: Double = (start.latitude + end.latitude) / 2 * Double.pi / 180
        let north: Double = (end.latitude - start.latitude) * metresPerDegree
        let east: Double = (end.longitude - start.longitude) * metresPerDegree * cos(meanLatitude)
        return (north * north + east * east).squareRoot()
    }

    /// The shorter way round, in degrees (-180…180).
    private static func headingChange(from start: Double, to end: Double) -> Double {
        var change: Double = (end - start).truncatingRemainder(dividingBy: 360)
        if change > 180 { change -= 360 }
        if change < -180 { change += 360 }
        return change
    }

    private static func normalised(_ camera: MapFlightCamera) -> MapFlightCamera {
        var camera = camera
        camera.latitude = min(90, max(-90, camera.latitude))
        var longitude: Double = camera.longitude.truncatingRemainder(dividingBy: 360)
        if longitude > 180 { longitude -= 360 }
        if longitude < -180 { longitude += 360 }
        camera.longitude = longitude
        camera.distance = max(1, camera.distance)
        return camera
    }
}

extension MapFlight {
    /// Camera distance that shows a region `latitudeDelta` by `longitudeDelta`
    /// degrees around `latitude` whole on a map `width` by `height` points,
    /// as MapKit fits a region: the tighter of the two directions wins.
    public static func distance(
        fittingLatitudeDelta latitudeDelta: Double,
        longitudeDelta: Double,
        at latitude: Double,
        width: Double,
        height: Double
    ) -> Double {
        let aspect: Double = (width > 0 && height > 0) ? height / width : 1
        let north: Double = latitudeDelta * metresPerDegree
        let east: Double = longitudeDelta * metresPerDegree * cos(min(89, abs(latitude)) * Double.pi / 180)
        let visibleHeight: Double = max(north, east * aspect)
        return max(1, visibleHeight / visibleHeightPerMetre)
    }
}
