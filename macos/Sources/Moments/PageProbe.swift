#if DEBUG
import AppKit
import Darwin
import QuartzCore
import SwiftData

/// UI-test-only, `-MomentsUITestPageProbe <folder>`: how long the main thread
/// is blocked during a first big import (with `-MomentsUITestStressLibrary`)
/// and when each page opens. The app drives itself, so the UI test does not
/// query it while it measures (accessibility queries run on the main thread).
///
/// Each step reports when the page settled (the end of the last main-thread
/// stretch of 50 ms or more before a quiet second and a half), plus the longest
/// stretch (what feels like a freeze), how many stretches passed 100 ms, the
/// main-thread time, the app's memory, and where the main thread spent it.
/// The report goes to `page-report.txt`; `page-report-done` marks the end.
@MainActor
enum PageProbe {
    private static var folder: URL?
    private static var container: ModelContainer?
    private static weak var selection: SelectionModel?
    private static weak var people: PeopleScanController?
    private static weak var stacks: PhotoStackAnalyzer?
    private static var observer: CFRunLoopObserver?
    private static var wokeAt: CFTimeInterval = 0
    /// Busy stretches of the main run loop: when they ended and how long they took.
    private static var stretches: [(end: CFTimeInterval, length: CFTimeInterval)] = []
    private static var report = ""
    private static var importPhase: Phase?
    private static var activePhaseStart: CFTimeInterval?
    private static var activeMetrics = Metrics()
    private static var started = false

    private struct Phase {
        let name: String
        let start: CFTimeInterval
        let footprint: UInt64
    }

    private struct Metrics {
        var selectionToShell: CFTimeInterval?
        var firstContent: CFTimeInterval?
        var firstThumbnail: CFTimeInterval?
        var cancellationObserved = false
    }

    static var isEnabled: Bool { folder != nil }

    static func startIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-MomentsUITestPageProbe"), index + 1 < arguments.count else { return }
        let url = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        folder = url
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { _, activity in
            let now = CACurrentMediaTime()
            MainActor.assumeIsolated {
                if activity == .afterWaiting {
                    PageProbe.wokeAt = now
                } else if PageProbe.wokeAt > 0 {
                    PageProbe.stretches.append((now, now - PageProbe.wokeAt))
                    PageProbe.wokeAt = 0
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    /// The window is up; without a stress import the pages are measured now.
    static func attach(container: ModelContainer, selection: SelectionModel, people: PeopleScanController, stacks: PhotoStackAnalyzer) {
        guard isEnabled, !started else { return }
        started = true
        self.container = container
        self.selection = selection
        self.people = people
        self.stacks = stacks
        report = "page probe: \(ProcessInfo.processInfo.processorCount) cores\n"
        Task { await run() }
    }

    static func importStarted() {
        guard isEnabled else { return }
        stretches.removeAll()
        let phase = Phase(name: "first import", start: CACurrentMediaTime(), footprint: footprint())
        importPhase = phase
        begin(phase)
        // Import takes minutes: a coarser sample covers it.
        MainThreadSampler.start(interval: 10_000)
    }

    /// Called by the host after a destination has replaced the previous page
    /// shell. The probe records the callback itself, never the action call.
    static func shellReady() { mark(\.selectionToShell) }

    /// Called on the next main-queue turn after the destination shell is
    /// installed, when its first useful content can be drawn.
    static func contentReady() { mark(\.firstContent) }

    /// Called after a real thumbnail has been obtained or read from cache.
    static func thumbnailReady() { mark(\.firstThumbnail) }

    /// Called when a page task is cancelled while a new generation replaces it.
    static func cancellationObserved() {
        guard activePhaseStart != nil else { return }
        activeMetrics.cancellationObserved = true
    }

    static func importFinished(summary: String) {
        guard isEnabled, let phase = importPhase else { return }
        report += summary + "\n"
        finish(phase, settled: CACurrentMediaTime(), timedOut: false)
        importPhase = nil
    }

    private static func run() async {
        // A stress import measures itself; the pages wait for it and for the
        // background work it starts (faces, bursts, place names).
        if StressLibrary.requestedCount != nil {
            while StressLibrary.stage != .finished { try? await Task.sleep(for: .milliseconds(200)) }
            await measure("after import (faces, bursts, place names)", timeout: 600, quiet: 3, sampleInterval: 10_000) {} until: {
                people?.isScanning != true && stacks?.isRunning != true
            }
        } else {
            try? await Task.sleep(for: .seconds(2))
        }
        let destinations: [(String, SidebarDestination)] = [
            ("People", .people), ("Map", .map), ("Timeline", .timeline), ("Chapters", .trips), ("Library", .library)
        ]
        for (name, destination) in destinations {
            await measure(name) { selection?.requestedDestination = destination }
        }
        if let photo = newestPhotoID() {
            await measure("viewer open") { selection?.openViewer(photo, in: [photo]) }
            await measure("viewer close") { selection?.viewerRequest = nil }
        }
        await measure("Chapters again") { selection?.requestedDestination = .trips }
        if let trip = largestTripID() {
            await measure("chapter with most photos") { selection?.openTripID = trip }
            await measure("back to chapters") { selection?.openTripID = nil }
        }
        await measure("Timeline again") { selection?.requestedDestination = .timeline }
        await measure("Library again") { selection?.requestedDestination = .library }
        write()
        if let folder { FileManager.default.createFile(atPath: folder.appending(path: "page-report-done").path, contents: nil) }
    }

    /// Runs `action`, then waits until the main thread has been quiet for
    /// `quiet` seconds (and `until` holds) or `timeout` passes.
    private static func measure(
        _ name: String,
        // A page can keep producing low-value SwiftUI graph updates while it
        // is usable (People is the current example). Keep a bounded phase so
        // one noisy page cannot prevent the rest of the report from running.
        // A timeout is still recorded in the report as evidence of that
        // page's responsiveness problem.
        timeout: TimeInterval = 45,
        quiet: TimeInterval = 1.5,
        sampleInterval: UInt32 = 2_000,
        _ action: () -> Void,
        until done: () -> Bool = { true }
    ) async {
        // Let the previous step's last frames pass.
        try? await Task.sleep(for: .milliseconds(300))
        stretches.removeAll()
        let phase = Phase(name: name, start: CACurrentMediaTime(), footprint: footprint())
        begin(phase)
        MainThreadSampler.start(interval: sampleInterval)
        action()
        var timedOut = false
        while true {
            try? await Task.sleep(for: .milliseconds(100))
            let now = CACurrentMediaTime()
            if now - phase.start > timeout {
                timedOut = true
                break
            }
            guard now - phase.start > quiet, done() else { continue }
            let recent = stretches.filter { $0.end > now - quiet }
            let busy = recent.reduce(0) { $0 + $1.length }
            if recent.allSatisfy({ $0.length < 0.05 }) && busy < quiet * 0.2 { break }
        }
        let settled = stretches.last(where: { $0.length >= 0.05 })?.end ?? phase.start
        finish(phase, settled: settled, timedOut: timedOut)
    }

    private static func finish(_ phase: Phase, settled: CFTimeInterval, timedOut: Bool) {
        let metrics = activeMetrics
        let mine = stretches.filter { $0.end >= phase.start }
        let longest = mine.map(\.length).max() ?? 0
        let busy = mine.reduce(0) { $0 + $1.length }
        let memory = footprint()
        report += String(
            format: "page report (%@): selection-to-shell %@, first-content %@, first-thumbnail %@, fully-settled %.2f s%@, cancellation-observed %@, longest stall %.0f ms, stalls>100ms %d, main busy %.2f s, memory %.0f MB (%+.0f)\n",
            phase.name, format(metrics.selectionToShell), format(metrics.firstContent), format(metrics.firstThumbnail),
            max(0, settled - phase.start), timedOut ? " (timed out)" : "",
            metrics.cancellationObserved ? "yes" : "no", longest * 1000,
            mine.filter { $0.length > 0.1 }.count, busy,
            Double(memory) / 1_048_576, (Double(memory) - Double(phase.footprint)) / 1_048_576
        )
        report += MainThreadSampler.stopAndReport(top: 25, ownTop: 30, selfTop: 12)
        activePhaseStart = nil
        activeMetrics = Metrics()
        write()
    }

    private static func begin(_ phase: Phase) {
        activePhaseStart = phase.start
        activeMetrics = Metrics()
    }

    private static func mark(_ keyPath: WritableKeyPath<Metrics, CFTimeInterval?>) {
        guard let start = activePhaseStart else { return }
        if activeMetrics[keyPath: keyPath] == nil {
            activeMetrics[keyPath: keyPath] = max(0, CACurrentMediaTime() - start)
        }
    }

    private static func format(_ value: CFTimeInterval?) -> String {
        guard let value else { return "not observed" }
        return String(format: "%.2f s", value)
    }

    private static func write() {
        guard let folder else { return }
        try? report.write(to: folder.appending(path: "page-report.txt"), atomically: true, encoding: .utf8)
    }

    private static func newestPhotoID() -> String? {
        guard let context = container?.mainContext else { return nil }
        let video = MediaKind.video.rawValue
        var descriptor = FetchDescriptor<MediaItem>(
            predicate: #Predicate { $0.deletedAt == nil && $0.kindRaw != video },
            sortBy: [SortDescriptor(\.captureDate, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first?.id
    }

    private static func largestTripID() -> String? {
        guard let context = container?.mainContext, let trips = try? context.fetch(FetchDescriptor<Trip>()) else { return nil }
        return trips.max { $0.items.count < $1.items.count }?.id
    }

    /// The memory macOS charges the app for (Activity Monitor's "Memory").
    private static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
#endif
