#if DEBUG
import AppKit
import QuartzCore
import SwiftUI

/// UI-test-only, enabled by `-MomentsUITestResizeProbe <folder>`: measures how
/// smoothly the photos follow the sidebar. Pressing "r" makes the app hide the
/// sidebar, show it again (both with the system animation), then drag the
/// sidebar divider wider and back at a steady speed, all driven by the display
/// link so the UI test does not touch the app while it is measured. Every frame
/// callback is recorded (a late one is a dropped frame), along with the photo
/// grid's width and column count, so a column jump shows up too. One report
/// per phase; the folder gets a `resizing` file while the phases run, for the
/// CI workflow's call-stack sampler.
@MainActor
enum ResizeProbe {
    private enum Phase: String, CaseIterable {
        /// Nothing changes: the frame rate this Mac manages anyway.
        case idle = "idle"
        case hideSidebar = "hide sidebar"
        case showSidebar = "show sidebar"
        case dragWider = "drag divider wider"
        case dragBack = "drag divider back"
    }

    private static var folder: URL?
    private static var displayLink: CADisplayLink?
    private static var target: Target?
    private static var window: NSWindow?
    private static var phases: [Phase] = []
    private static var phaseStart: TimeInterval = 0
    private static var lastFrame: TimeInterval = 0
    private static var intervals: [TimeInterval] = []
    private static var grid: [(columns: Int, width: CGFloat)] = []
    private static var dragFrom: CGFloat = 0
    private static var report = ""
    /// Main-thread time spent handling events, layout and drawing in this
    /// phase. Busy close to elapsed: the app's own work is the bottleneck;
    /// far below: the frames wait on rendering outside the main thread.
    private static var busy: TimeInterval = 0
    private static var wokeAt: TimeInterval = 0
    private static var observer: CFRunLoopObserver?

    static func startIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-MomentsUITestResizeProbe"), index + 1 < arguments.count else { return }
        let url = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        folder = url
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            guard event.charactersIgnoringModifiers == "r", event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else { return event }
            MainActor.assumeIsolated { start(in: event.window) }
            return nil
        }
    }

    /// The Library grid reports every width it is laid out at.
    static func noteGrid(columns: Int, width: CGFloat) {
        guard displayLink != nil, grid.last?.columns != columns || grid.last?.width != width else { return }
        grid.append((columns, width))
    }

    private static func start(in window: NSWindow?) {
        guard displayLink == nil, let window, let content = window.contentView else { return }
        self.window = window
        phases = Phase.allCases
        report = ""
        if let folder { FileManager.default.createFile(atPath: folder.appending(path: "resizing").path, contents: nil) }
        let target = Target()
        let link = content.displayLink(target: target, selector: #selector(Target.tick(_:)))
        link.add(to: .main, forMode: .common)
        self.target = target
        displayLink = link
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { _, activity in
            let now = CACurrentMediaTime()
            MainActor.assumeIsolated {
                if activity == .afterWaiting {
                    ResizeProbe.wokeAt = now
                } else if ResizeProbe.wokeAt > 0 {
                    ResizeProbe.busy += now - ResizeProbe.wokeAt
                    ResizeProbe.wokeAt = 0
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
        begin()
    }

    private static var splitView: NSSplitView? {
        func find(_ view: NSView) -> NSSplitView? {
            if let split = view as? NSSplitView { return split }
            for subview in view.subviews { if let found = find(subview) { return found } }
            return nil
        }
        return window?.contentView.flatMap(find)
    }

    private static func begin() {
        guard let phase = phases.first else { return }
        intervals = []
        grid = []
        lastFrame = 0
        busy = 0
        phaseStart = CACurrentMediaTime()
        switch phase {
        case .idle:
            break
        default:
            // Where the main thread spends a sidebar change.
            MainThreadSampler.start()
        }
        switch phase {
        case .idle:
            break
        case .hideSidebar, .showSidebar:
            // What the toolbar's sidebar button sends.
            NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
        case .dragWider, .dragBack:
            dragFrom = splitView?.arrangedSubviews.first?.frame.width ?? 0
        }
    }

    fileprivate static func tick() {
        let now = CACurrentMediaTime()
        if lastFrame > 0 { intervals.append(now - lastFrame) }
        lastFrame = now
        guard let phase = phases.first else { return }
        let elapsed = now - phaseStart
        switch phase {
        case .idle:
            guard elapsed > 0.8 else { return }
        case .hideSidebar, .showSidebar:
            // The system animation takes about a quarter of a second.
            guard elapsed > 0.8 else { return }
        case .dragWider, .dragBack:
            // A steady 0.6 s drag of 60 pt, like a hand on the divider.
            let distance: CGFloat = phase == .dragWider ? 60 : -60
            let progress = min(1, elapsed / 0.6)
            splitView?.setPosition(dragFrom + distance * progress, ofDividerAt: 0)
            guard elapsed > 0.8 else { return }
        }
        writeReport(phase)
        phases.removeFirst()
        if phases.isEmpty {
            finish()
        } else {
            begin()
        }
    }

    private static func finish() {
        displayLink?.invalidate()
        displayLink = nil
        target = nil
        window = nil
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
        guard let folder else { return }
        try? FileManager.default.removeItem(at: folder.appending(path: "resizing"))
        try? report.write(to: folder.appending(path: "resize-report.txt"), atomically: true, encoding: .utf8)
    }

    private static func writeReport(_ phase: Phase) {
        let frame = 1.0 / 60.0
        let sorted = intervals.sorted()
        let late = intervals.filter { $0 > frame * 1.5 }
        let worst = (sorted.last ?? 0) * 1000
        let elapsed = CACurrentMediaTime() - phaseStart
        report += String(format: "%@: %d frames, late %d, worst %.1f ms, stalls>50ms %d, main thread busy %.0f of %.0f ms\n",
                         phase.rawValue, intervals.count, late.count, worst, intervals.filter { $0 > 0.05 }.count,
                         busy * 1000, elapsed * 1000)
        // Frame by frame, so a long one can be lined up with the grid change.
        report += "  frames ms: " + intervals.map { String(format: "%.0f", $0 * 1000) }.joined(separator: " ") + "\n"
        let columns = grid.map(\.columns)
        let changes = zip(columns, columns.dropFirst()).filter { $0 != $1 }.count
        report += "  grid: \(grid.count) widths, column changes \(changes): "
            + grid.map { String(format: "%d@%.0f", $0.columns, $0.width) }.joined(separator: " ") + "\n"
        if phase != .idle { report += MainThreadSampler.stopAndReport(top: 30) }
    }

    static let isEnabled = ProcessInfo.processInfo.arguments.contains("-MomentsUITestResizeProbe")

    private final class Target: NSObject {
        @objc func tick(_ link: CADisplayLink) {
            MainActor.assumeIsolated { ResizeProbe.tick() }
        }
    }
}
/// Reports a Library grid's width to the probe while it measures.
struct ResizeProbeGridWidth: ViewModifier {
    let columns: Int

    func body(content: Content) -> some View {
        if ResizeProbe.isEnabled {
            content.onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
                ResizeProbe.noteGrid(columns: columns, width: width)
            }
        } else {
            content
        }
    }
}
#endif
