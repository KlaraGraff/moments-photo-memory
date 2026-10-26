#if DEBUG
import AppKit
import QuartzCore

/// UI-test-only, enabled by `-MomentsUITestScrollProbe <folder>`: measures how
/// smoothly Moments scrolls. A display link records every frame callback the
/// main thread delivers while the user scrolls; a late callback means the main
/// thread was busy and the frame was dropped. A key press writes the report.
@MainActor
enum ScrollProbe {
    private static var folder: URL?
    private static var displayLink: CADisplayLink?
    private static var target: Target?
    private static var lastScroll: TimeInterval = 0
    private static var lastFrame: TimeInterval = 0
    private static var intervals: [TimeInterval] = []
    private static var counters: [String: Int] = [:]
    private static var reports = 0

    static var isActive: Bool { folder != nil }

    static func startIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-MomentsUITestScrollProbe"), index + 1 < arguments.count else { return }
        let url = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        folder = url
        NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown]) { event in
            MainActor.assumeIsolated {
                if event.type == .scrollWheel {
                    noteScroll(in: event.window)
                } else {
                    writeReport(label: event.charactersIgnoringModifiers ?? "")
                }
            }
            return event
        }
    }

    /// Counts work done during the measured scroll, such as body evaluations.
    static func count(_ name: String, by amount: Int = 1) {
        guard folder != nil else { return }
        counters[name, default: 0] += amount
    }

    private static func noteScroll(in window: NSWindow?) {
        lastScroll = CACurrentMediaTime()
        guard displayLink == nil, let view = window?.contentView else { return }
        let target = Target()
        let link = view.displayLink(target: target, selector: #selector(Target.tick(_:)))
        link.add(to: .main, forMode: .common)
        self.target = target
        displayLink = link
        lastFrame = 0
    }

    fileprivate static func tick() {
        let now = CACurrentMediaTime()
        // Only frames while scrolling or decelerating count.
        if now - lastScroll < 0.6 {
            if lastFrame > 0 { intervals.append(now - lastFrame) }
            lastFrame = now
        } else {
            lastFrame = 0
        }
    }

    private static func writeReport(label: String) {
        guard let folder else { return }
        reports += 1
        let frame = 1.0 / 60.0
        let sorted = intervals.sorted()
        let total = intervals.reduce(0, +)
        let late = intervals.filter { $0 > frame * 1.5 }
        // Hitch time: how long frames were late beyond one refresh interval.
        let hitch = late.reduce(0) { $0 + ($1 - frame) }
        func percentile(_ p: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] * 1000
        }
        var text = String(
            format: "scroll report %d: %d frames over %.2fs, late %d, hitch %.0f ms/s, p50 %.1fms p95 %.1fms worst %.1fms, stalls>100ms %d\n",
            reports, intervals.count, total, late.count, total > 0 ? hitch * 1000 / total : 0,
            percentile(0.5), percentile(0.95), (sorted.last ?? 0) * 1000, intervals.filter { $0 > 0.1 }.count
        )
        for (name, value) in counters.sorted(by: { $0.key < $1.key }) {
            text += "  \(name): \(value)\n"
        }
        try? text.write(to: folder.appending(path: "scroll-report-\(reports).txt"), atomically: true, encoding: .utf8)
        intervals = []
        counters = [:]
    }

    private final class Target: NSObject {
        @objc func tick(_ link: CADisplayLink) {
            MainActor.assumeIsolated { ScrollProbe.tick() }
        }
    }
}
#endif
