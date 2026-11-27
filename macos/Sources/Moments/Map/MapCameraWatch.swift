import AppKit
import MapKit
import QuartzCore
import SwiftUI
import MomentsCore

/// What the map screen remembers about its camera between redraws: the last
/// camera MapKit reported, and the flight under way. A plain object, so
/// updating it on every frame of a move never redraws the screen.
@MainActor
final class MapCameraWatch {
    var latest: MapFlightCamera?
    var latestRegion: MKCoordinateRegion?
    /// Where the flight under way ends; nil when the camera is not flying.
    private(set) var flightTarget: MapFlightCamera?
    private var flightTask: Task<Void, Never>?
    private var eventMonitor: Any?

    /// Plays `flight`, handing `apply` the camera for each frame until the
    /// last, which is exactly the flight's end. A click, scroll, pinch or
    /// rotation anywhere in the app on the way stops it where it is, so the
    /// person's own move wins, and calls `interrupted`; a newer flight
    /// replaces this one.
    func fly(
        _ flight: MapFlight,
        interrupted: @escaping @MainActor () -> Void,
        apply: @escaping @MainActor (MapFlightCamera) -> Void
    ) {
        cancelFlight()
        flightTarget = flight.end
        let events: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .magnify, .rotate, .swipe]
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.flightTarget != nil else { return }
                self.cancelFlight()
                interrupted()
            }
            return event
        }
        let startedAt: CFTimeInterval = CACurrentMediaTime()
        flightTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // By the clock, not by frame count: a slow frame never
                // stretches the flight.
                let elapsed: Double = CACurrentMediaTime() - startedAt
                apply(flight.camera(at: elapsed))
                if elapsed >= flight.duration { break }
                // About two updates per frame at 60 Hz, one at 120 Hz.
                try? await Task.sleep(for: .milliseconds(8))
            }
            guard !Task.isCancelled else { return }
            self?.finishFlight()
        }
    }

    func cancelFlight() {
        flightTask?.cancel()
        finishFlight()
    }

    private func finishFlight() {
        flightTask = nil
        flightTarget = nil
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
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
