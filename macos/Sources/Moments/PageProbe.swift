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
///
/// A heartbeat thread rewrites `page-heartbeat.txt` every few seconds (the
/// phase, how long it has run, how many phases finished, and how long the
/// main thread has left a ping unanswered), so the CI watchdog can tell a slow
/// page from a stuck one. When the main thread stops answering it also writes
/// the main thread's stack to `page-stuck-main.txt`, which a report written on
/// the main thread could never contain.
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
    private static var activePhaseToken: UInt64?
    private static var activePhaseName: String?
    private static var activeMetrics = Metrics()
    private static var nextPhaseToken: UInt64 = 0
    private static var started = false
    /// Phases left out (`-MomentsUITestPageProbeSkip "Map,People"`): a page
    /// that freezes the app would otherwise hide every page after it.
    private static var skipped: Set<String> = []
    /// Map layers left out (`-MomentsUITestPageProbeMapLayers "routes,pins"`):
    /// probe-only switches in the Map screen that narrow down what freezes it.
    static private(set) var mapLayersLeftOut: Set<String> = []
    /// Read by the heartbeat thread.
    nonisolated private static let status = PageProbeStatus()

    private struct Phase {
        let name: String
        let start: CFTimeInterval
        let footprint: UInt64
        let token: UInt64
    }

    private struct Metrics {
        var selectionToShell: CFTimeInterval?
        var firstContent: CFTimeInterval?
        var firstThumbnail: CFTimeInterval?
        var cancellationObserved = false
    }

    static var isEnabled: Bool { folder != nil }

    /// Page work captures this token when it starts. Events from a task that
    /// began during an earlier phase cannot satisfy the current phase.
    static var phaseToken: UInt64? { activePhaseToken }

    static func startIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-MomentsUITestPageProbe"), index + 1 < arguments.count else { return }
        let url = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        folder = url
        if let skip = arguments.firstIndex(of: "-MomentsUITestPageProbeSkip"), skip + 1 < arguments.count {
            skipped = Set(arguments[skip + 1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        }
        if let layers = arguments.firstIndex(of: "-MomentsUITestPageProbeMapLayers"), layers + 1 < arguments.count {
            mapLayersLeftOut = Set(arguments[layers + 1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        }
        MainThreadSampler.prepareForStuckStacks()
        startHeartbeat(folder: url)
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
        report = "page probe: \(ProcessInfo.processInfo.processorCount) cores, \(StressLibrary.requestedCount.map { "\($0) synthetic photos" } ?? "no stress library")\n"
        if !skipped.isEmpty { report += "skipped: \(skipped.sorted().joined(separator: ", "))\n" }
        if !mapLayersLeftOut.isEmpty { report += "map layers left out: \(mapLayersLeftOut.sorted().joined(separator: ", "))\n" }
        status.begin("waiting for the window")
        Task { await run() }
    }

    static func importStarted() {
        guard isEnabled else { return }
        stretches.removeAll()
        nextPhaseToken &+= 1
        let phase = Phase(name: "first import", start: CACurrentMediaTime(), footprint: footprint(), token: nextPhaseToken)
        importPhase = phase
        begin(phase)
        // Import takes minutes: a coarser sample covers it.
        MainThreadSampler.start(interval: 10_000)
    }

    /// Called by a destination after its shell has appeared. The phase token
    /// keeps a delayed callback from an earlier page from being counted here.
    static func shellReady(token: UInt64?) { mark(\.selectionToShell, token: token) }

    /// Called after a destination's first useful content or first batch is
    /// ready. It is intentionally separate from shell appearance.
    static func contentReady(token: UInt64?) { mark(\.firstContent, token: token) }

    /// Called after a real thumbnail has been obtained or read from cache.
    static func thumbnailReady(token: UInt64?) { mark(\.firstThumbnail, token: token) }

    /// A page's note for the current phase, e.g. how much it drew. Ignored
    /// when no phase is active, so a stale task cannot pollute the report.
    static func note(_ line: String) {
        guard let name = activePhaseName, activePhaseStart != nil else { return }
        report += "note (\(name)): \(line)\n"
        write()
    }

    /// Called by a page task from its cancellation path. Projection saves do
    /// not count: they are source changes, not proof that page work stopped.
    static func cancellationObserved(token: UInt64?) {
        guard activePhaseStart != nil, token == activePhaseToken else { return }
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
            await measure("after import (faces, bursts, place names)", timeout: 600, quiet: 3, waitsForContent: false, sampleInterval: 10_000) {} until: {
                people?.isScanning != true && stacks?.isRunning != true
            } describe: {
                "faces scanning \(people?.isScanning == true ? "yes" : "no"), bursts \(stacks?.isRunning == true ? "yes" : "no")"
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
            await measure("favorite on") { toggleFavorite(photo) }
            await measure("favorite off") { toggleFavorite(photo) }
            await measure("viewer close", waitsForContent: false) { selection?.viewerRequest = nil }
        }
        await measure("Chapters again") { selection?.requestedDestination = .trips }
        if let trip = largestTripID() {
            await measure("chapter with most photos") { selection?.openTripID = trip }
            await measure("back to chapters") { selection?.openTripID = nil }
        }
        await measure("Timeline again") { selection?.requestedDestination = .timeline }
        await measure("Library again") { selection?.requestedDestination = .library }
        write()
        status.begin("done")
        if let folder { FileManager.default.createFile(atPath: folder.appending(path: "page-report-done").path, contents: nil) }
    }

    /// Runs `action`, then waits until the main thread has been quiet for
    /// `quiet` seconds (and `until` holds, and — with `waitsForContent` — the
    /// page has reported its first content) or `timeout` passes.
    private static func measure(
        _ name: String,
        // A page can keep producing low-value SwiftUI graph updates while it
        // is usable (People is the current example). Keep a bounded phase so
        // one noisy page cannot prevent the rest of the report from running.
        // A timeout is still recorded in the report as evidence of that
        // page's responsiveness problem.
        timeout: TimeInterval = 45,
        quiet: TimeInterval = 1.5,
        // A page can build its content off the main thread, so the main thread
        // may be quiet before the content is there. Keep the phase open until
        // the page reports its first content (or the timeout passes).
        waitsForContent: Bool = true,
        sampleInterval: UInt32 = 2_000,
        _ action: () -> Void,
        until done: () -> Bool = { true },
        describe: () -> String = { "" }
    ) async {
        guard !skipped.contains(name) else { return }
        // Let the previous step's last frames pass.
        try? await Task.sleep(for: .milliseconds(300))
        stretches.removeAll()
        nextPhaseToken &+= 1
        let phase = Phase(name: name, start: CACurrentMediaTime(), footprint: footprint(), token: nextPhaseToken)
        begin(phase)
        MainThreadSampler.start(interval: sampleInterval, covering: timeout)
        action()
        var timedOut = false
        while true {
            try? await Task.sleep(for: .milliseconds(100))
            let now = CACurrentMediaTime()
            if now - phase.start > timeout {
                timedOut = true
                break
            }
            let ready = done()
            let hasContent: Bool = !waitsForContent || activeMetrics.firstContent != nil
            if ready, !hasContent {
                status.set(detail: "waiting for first content")
            } else {
                status.set(detail: ready ? "waiting for a quiet main thread" : "waiting for background work: \(describe())")
            }
            guard now - phase.start > quiet, ready, hasContent else { continue }
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
        status.finished(phase.name, timedOut: timedOut)
        activePhaseStart = nil
        activePhaseToken = nil
        activePhaseName = nil
        activeMetrics = Metrics()
        write()
    }

    private static func begin(_ phase: Phase) {
        status.begin(phase.name)
        activePhaseStart = phase.start
        activePhaseToken = phase.token
        activePhaseName = phase.name
        activeMetrics = Metrics()
    }

    private static func mark(_ keyPath: WritableKeyPath<Metrics, CFTimeInterval?>, token: UInt64?) {
        guard let start = activePhaseStart, token == activePhaseToken else { return }
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

    /// The viewer's star button, pressed by the probe: the same model call and
    /// the same save, on the main context.
    private static func toggleFavorite(_ photoID: String) {
        guard let context = container?.mainContext else { return }
        var descriptor = FetchDescriptor<MediaItem>(predicate: #Predicate { $0.id == photoID })
        descriptor.fetchLimit = 1
        guard let item = try? context.fetch(descriptor).first else { return }
        item.setFavorite(!item.isFavorite, context: context)
        try? context.save()
    }

    private static func largestTripID() -> String? {
        guard let context = container?.mainContext, let trips = try? context.fetch(FetchDescriptor<Trip>()) else { return nil }
        return trips.max { $0.items.count < $1.items.count }?.id
    }

    /// Every 5 s: the heartbeat line, a ping to the main thread, and the main
    /// thread's stack once it has left a ping unanswered for 30 s (again at
    /// 3 minutes). Runs off the main thread, so it keeps going when the main
    /// thread is stuck.
    nonisolated private static func startHeartbeat(folder: URL) {
        let heartbeat = folder.appending(path: "page-heartbeat.txt")
        let stuck = folder.appending(path: "page-stuck-main.txt")
        let launched = CACurrentMediaTime()
        Thread.detachNewThread {
            var beat = 0
            var dumps: [Double] = []
            while true {
                beat += 1
                let now = CACurrentMediaTime()
                if status.sendPingIfIdle(now: now) {
                    DispatchQueue.main.async { status.pingAnswered() }
                }
                let state = status.snapshot(now: now)
                // Tab-separated key=value; the phase name goes last because
                // it has spaces in it.
                let line = String(
                    format: "beat=%d\tuptime=%.1f\tphases_done=%d\tphase_elapsed=%.1f\tmain_silent=%.1f\tmemory_mb=%.0f\tlast_finished=%@\tdetail=%@\tphase=%@\n",
                    beat, now - launched, state.phasesDone, state.phaseElapsed, state.mainSilent,
                    Double(footprint()) / 1_048_576, state.lastFinished, state.detail, state.phase
                )
                try? line.write(to: heartbeat, atomically: true, encoding: .utf8)
                for threshold in [30.0, 180.0] where state.mainSilent >= threshold && !dumps.contains(threshold) {
                    dumps.append(threshold)
                    var text = (try? String(contentsOf: stuck, encoding: .utf8)) ?? ""
                    text += String(format: "== main thread silent for %.0f s during \"%@\" (%.0f s into the phase)\n", state.mainSilent, state.phase, state.phaseElapsed)
                    text += MainThreadSampler.stuckStacks()
                    try? text.write(to: stuck, atomically: true, encoding: .utf8)
                }
                // Answering again re-arms the dumps for a later stall.
                if state.mainSilent < 5 { dumps.removeAll() }
                Thread.sleep(forTimeInterval: 5)
            }
        }
    }

    /// The memory macOS charges the app for (Activity Monitor's "Memory").
    nonisolated private static func footprint() -> UInt64 {
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

/// What the heartbeat reports. The main thread updates it and the heartbeat
/// thread reads it, so every access takes the lock.
private final class PageProbeStatus: @unchecked Sendable {
    struct Snapshot {
        let phase: String
        let phaseElapsed: Double
        let phasesDone: Int
        let lastFinished: String
        let detail: String
        let mainSilent: Double
    }

    private let lock = NSLock()
    private var phase = "launch"
    private var phaseStart = CACurrentMediaTime()
    private var phasesDone = 0
    private var lastFinished = "none"
    private var detail = ""
    /// When the unanswered ping was sent; nil while none is waiting.
    private var pingSentAt: CFTimeInterval?

    func begin(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        phase = name
        phaseStart = CACurrentMediaTime()
        detail = ""
    }

    func finished(_ name: String, timedOut: Bool) {
        lock.lock(); defer { lock.unlock() }
        phasesDone += 1
        lastFinished = timedOut ? "\(name) (timed out)" : name
        phase = "between phases"
        phaseStart = CACurrentMediaTime()
        detail = ""
    }

    func set(detail: String) {
        lock.lock(); defer { lock.unlock() }
        self.detail = detail
    }

    /// True when a new ping should go out: none is waiting for an answer.
    func sendPingIfIdle(now: CFTimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard pingSentAt == nil else { return false }
        pingSentAt = now
        return true
    }

    func pingAnswered() {
        lock.lock(); defer { lock.unlock() }
        pingSentAt = nil
    }

    func snapshot(now: CFTimeInterval) -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(
            phase: phase,
            phaseElapsed: now - phaseStart,
            phasesDone: phasesDone,
            lastFinished: lastFinished,
            detail: detail.replacingOccurrences(of: "\t", with: " "),
            mainSilent: pingSentAt.map { now - $0 } ?? 0
        )
    }
}
#endif
