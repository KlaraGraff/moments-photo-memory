#if DEBUG
import MapKit
import QuartzCore
import SwiftUI

/// UI tests only (`-MomentsUITestCameraProbe`): records the camera distance
/// MapKit reports while the camera moves after "Whole world" or "Zoom to
/// photos", so a test can check the zoom is spread over the whole move
/// instead of jumping at the end.
@MainActor
enum MapCameraTrace {
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("-MomentsUITestCameraProbe")
    private static var startedAt: CFTimeInterval?
    private static var samples: [(time: CFTimeInterval, distance: Double)] = []
    private static var generation = 0

    /// A button moved the camera: start a fresh trace from `distance`, the
    /// camera's distance when it was pressed.
    static func begin(distance: Double) {
        guard isEnabled else { return }
        startedAt = CACurrentMediaTime()
        samples = [(0, distance)]
        generation += 1
    }

    static func record(distance: Double) {
        guard isEnabled, let startedAt, samples.count < 600 else { return }
        samples.append((CACurrentMediaTime() - startedAt, distance))
    }

    /// "trace#<n>=<ms>:<metres>,…", one entry per report since the last press.
    static var summary: String {
        let entries: [String] = samples.map { sample in
            "\(Int((sample.time * 1000).rounded())):\(Int(sample.distance.rounded()))"
        }
        return "trace#\(generation)=" + entries.joined(separator: ",")
    }
}

struct MapCameraTraceProbe: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel(MapCameraTrace.summary)
                .accessibilityIdentifier("debug.cameraTrace")
        }
    }
}
#endif
