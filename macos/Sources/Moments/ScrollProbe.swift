#if DEBUG
import AppKit
import QuartzCore

/// UI-test-only, enabled by `-MomentsUITestScrollProbe <folder>`: measures how
/// smoothly Moments scrolls. Pressing "s" scrolls the largest scroll view of
/// the key window down and back up at a steady speed, driven by the display
/// link, so the UI test does not touch the app (its accessibility queries run
/// on the app's main thread and would show up as stalls). Every frame callback
/// is recorded; a late callback means the main thread was busy and the frame
/// was dropped. One report is written per direction.
@MainActor
enum ScrollProbe {
    private static var folder: URL?
    private static var displayLink: CADisplayLink?
    private static var target: Target?
    private static var scrollView: NSScrollView?
    /// Points per frame; positive scrolls down.
    private static var speed: CGFloat = 0
    private static var passes = 0
    private static var lastFrame: TimeInterval = 0
    private static var intervals: [TimeInterval] = []
    private static var counters: [String: Int] = [:]
    private static var reports = 0

    static func startIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-MomentsUITestScrollProbe"), index + 1 < arguments.count else { return }
        let url = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        folder = url
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            guard event.charactersIgnoringModifiers == "s" else { return event }
            MainActor.assumeIsolated { start(in: event.window) }
            return nil
        }
    }

    /// Counts work done during the measured scroll, such as body evaluations.
    static func count(_ name: String, by amount: Int = 1) {
        guard folder != nil, speed != 0 else { return }
        counters[name, default: 0] += amount
    }

    private static func start(in window: NSWindow?) {
        guard displayLink == nil, let content = window?.contentView,
              let scroll = scrollViews(in: content).max(by: { height(of: $0) < height(of: $1) }) else { return }
        scrollView = scroll
        speed = 30
        passes = 0
        intervals = []
        counters = [:]
        lastFrame = 0
        MainThreadSampler.start()
        let target = Target()
        let link = content.displayLink(target: target, selector: #selector(Target.tick(_:)))
        link.add(to: .main, forMode: .common)
        self.target = target
        displayLink = link
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        if let scroll = view as? NSScrollView { found.append(scroll) }
        for subview in view.subviews { found += scrollViews(in: subview) }
        return found
    }

    private static func height(of scroll: NSScrollView) -> CGFloat {
        scroll.documentView?.frame.height ?? 0
    }

    fileprivate static func tick() {
        let now = CACurrentMediaTime()
        if lastFrame > 0 { intervals.append(now - lastFrame) }
        lastFrame = now
        guard let scrollView else { return }
        let clip = scrollView.contentView
        let maxY = max(0, height(of: scrollView) - clip.bounds.height)
        let y = min(max(0, clip.bounds.origin.y + speed), maxY)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clip)
        // Lazy stacks grow while scrolling, so "the end" is checked each frame.
        let atEnd = speed > 0 ? y >= maxY - 1 : y <= 0
        let timedOut = intervals.reduce(0, +) > 12
        guard atEnd || timedOut else { return }
        writeReport(label: speed > 0 ? "down" : "up")
        passes += 1
        if passes == 1 {
            speed = -speed
            lastFrame = 0
            MainThreadSampler.start()
        } else {
            speed = 0
            displayLink?.invalidate()
            displayLink = nil
            target = nil
            self.scrollView = nil
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
            format: "scroll report %d (%@): %d frames over %.2fs, late %d, hitch %.0f ms/s, p50 %.1fms p95 %.1fms worst %.1fms, stalls>100ms %d\n",
            reports, label, intervals.count, total, late.count, total > 0 ? hitch * 1000 / total : 0,
            percentile(0.5), percentile(0.95), (sorted.last ?? 0) * 1000, intervals.filter { $0 > 0.1 }.count
        )
        text += String(format: "  scroll offset %.0f of %.0f pt\n", scrollView?.contentView.bounds.origin.y ?? 0, scrollView.map(height(of:)) ?? 0)
        for (name, value) in counters.sorted(by: { $0.key < $1.key }) {
            text += "  \(name): \(value)\n"
        }
        // Where the main thread spent this pass (sampling adds a little load).
        text += MainThreadSampler.stopAndReport()
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
