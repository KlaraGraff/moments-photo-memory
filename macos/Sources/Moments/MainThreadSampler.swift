#if DEBUG
import Darwin
import Foundation

/// UI-test-only profiler for ScrollProbe: while running, a background thread
/// interrupts the main thread every 2 ms with a signal whose handler records
/// the main thread's return addresses. `sample` cannot read the app's stacks
/// on the CI Mac, so the app samples itself. The report lists the functions
/// seen most often anywhere on the stack (inclusive) and at its top (self).
enum MainThreadSampler {
    private static let maxSamples = 12_000
    private static let maxDepth = 96
    private static let frames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: maxSamples * maxDepth)
    private static let depths = UnsafeMutablePointer<Int32>.allocate(capacity: maxSamples)
    private nonisolated(unsafe) static var count = 0
    private nonisolated(unsafe) static var recording = false
    private nonisolated(unsafe) static var mainThread: pthread_t?
    private nonisolated(unsafe) static var installed = false
    /// Stops the previous run's thread when a new run starts right away.
    private nonisolated(unsafe) static var generation = 0
    private nonisolated(unsafe) static var interval: UInt32 = 2_000
    private nonisolated(unsafe) static var startedAt: UInt64 = 0
    /// When the buffer filled up (uptime in ns, 0 if it did not); the report
    /// says so. A plain clock read is safe inside the signal handler.
    private nonisolated(unsafe) static var fullAt: UInt64 = 0
    /// One stack taken on request from another thread while the main thread
    /// does not answer (see `stuckStacks`), apart from the profile buffers.
    private static let stuckMaxDepth = 128
    private static let stuckFrames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: stuckMaxDepth)
    private nonisolated(unsafe) static var stuckDepth: Int32 = 0
    private nonisolated(unsafe) static var stuckWanted = false

    /// Call on the main thread before `stuckStacks` may be used.
    static func prepareForStuckStacks() {
        mainThread = pthread_self()
        // Allocate and initialise here: the signal handler must not malloc
        // or run a lazy initialiser.
        _ = stuckFrames
        stuckDepth = 0
        stuckWanted = false
        installHandlerIfNeeded()
    }

    private static func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        signal(SIGUSR2) { _ in MainThreadSampler.record() }
    }

    /// Call on the main thread. Every `interval` microseconds, or less often
    /// when the buffer could not hold `covering` seconds at that rate: the
    /// profile then spans the whole phase instead of only its start.
    static func start(interval: UInt32 = 2_000, covering seconds: Double = 0) {
        mainThread = pthread_self()
        count = 0
        startedAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        fullAt = 0
        let needed = seconds * 1_000_000 / Double(maxSamples)
        self.interval = max(interval, UInt32(min(needed.rounded(.up), 1_000_000)))
        // Allocate the buffers here: the signal handler must not malloc.
        _ = frames
        _ = depths
        generation += 1
        let run = generation
        installHandlerIfNeeded()
        recording = true
        Thread.detachNewThread {
            while recording, generation == run, let mainThread {
                pthread_kill(mainThread, SIGUSR2)
                usleep(interval)
            }
        }
    }

    private static func record() {
        if stuckWanted {
            stuckDepth = backtrace(stuckFrames, Int32(stuckMaxDepth))
            stuckWanted = false
        }
        guard recording else { return }
        guard count < maxSamples else {
            if fullAt == 0 { fullAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
            return
        }
        let depth = backtrace(frames + count * maxDepth, Int32(maxDepth))
        depths[count] = depth
        count += 1
    }

    /// Stops sampling and returns the report. Call on the main thread.
    static func stopAndReport(top: Int = 45, ownTop: Int = 60, selfTop: Int = 30) -> String {
        recording = false
        var inclusive: [String: Int] = [:]
        var selfCounts: [String: Int] = [:]
        var names: [UInt: String] = [:]
        func name(_ address: UnsafeMutableRawPointer) -> String {
            let key = UInt(bitPattern: address)
            if let known = names[key] { return known }
            var info = Dl_info()
            var result = "?"
            if dladdr(address, &info) != 0, let symbol = info.dli_sname {
                result = demangle(String(cString: symbol))
            } else if dladdr(address, &info) != 0, let image = info.dli_fname {
                result = "(\(URL(fileURLWithPath: String(cString: image)).lastPathComponent))"
            }
            names[key] = result
            return result
        }
        for sample in 0..<count {
            let depth = Int(depths[sample])
            // The interrupted code starts below the signal handler's frames.
            var skip = 0
            for index in 0..<min(depth, 6) {
                if let address = frames[sample * maxDepth + index], name(address).contains("sigtramp") {
                    skip = index + 1
                    break
                }
            }
            guard depth > skip else { continue }
            var seen = Set<String>()
            for index in skip..<depth {
                guard let address = frames[sample * maxDepth + index] else { continue }
                let symbol = name(address)
                if index == skip { selfCounts[symbol, default: 0] += 1 }
                if seen.insert(symbol).inserted { inclusive[symbol, default: 0] += 1 }
            }
        }
        var text = "main thread samples: \(count) (every \(Double(interval) / 1_000) ms)"
        if fullAt > startedAt {
            text += String(format: ", buffer full after %.1f s: the rest of the phase is not in this profile", Double(fullAt - startedAt) / 1e9)
        }
        text += "\n"
        text += "inclusive (on the stack):\n"
        for (symbol, hits) in inclusive.sorted(by: { $0.value > $1.value }).prefix(top) {
            text += String(format: "  %5.1f%% %@\n", Double(hits) * 100 / Double(max(count, 1)), String(symbol.prefix(200)))
        }
        // The app's own frames, which the framework lines above hide.
        text += "inclusive, Moments code only:\n"
        for (symbol, hits) in inclusive.filter({ $0.key.contains("Moments.") && !$0.key.contains("$main") }).sorted(by: { $0.value > $1.value }).prefix(ownTop) {
            text += String(format: "  %5.1f%% %@\n", Double(hits) * 100 / Double(max(count, 1)), String(symbol.prefix(240)))
        }
        text += "self (top of stack):\n"
        for (symbol, hits) in selfCounts.sorted(by: { $0.value > $1.value }).prefix(selfTop) {
            text += String(format: "  %5.1f%% %@\n", Double(hits) * 100 / Double(max(count, 1)), String(symbol.prefix(200)))
        }
        return text
    }

    /// The main thread's stack, `samples` times, from another thread: for a
    /// main thread that stopped answering, where a profile report (which runs
    /// on the main thread) can never be written. Call off the main thread.
    static func stuckStacks(samples: Int = 4, gap: UInt32 = 500_000, top: Int = 70) -> String {
        guard let mainThread else { return "main thread stack: unknown thread\n" }
        var text = ""
        var previous: [UInt] = []
        for index in 1...max(1, samples) {
            stuckDepth = 0
            stuckWanted = true
            pthread_kill(mainThread, SIGUSR2)
            var waited: UInt32 = 0
            while stuckWanted, waited < 2_000_000 {
                usleep(1_000)
                waited += 1_000
            }
            if stuckWanted {
                stuckWanted = false
                text += "main thread stack \(index): the main thread did not take the signal within 2 s\n"
            } else {
                var addresses: [UInt] = []
                var skipping = true
                for frame in 0..<Int(stuckDepth) {
                    guard let address = stuckFrames[frame] else { continue }
                    // The handler's own frames sit above the interrupted code.
                    if skipping {
                        if frame < 6, symbolName(address).contains("sigtramp") { skipping = false }
                        continue
                    }
                    addresses.append(UInt(bitPattern: address))
                }
                if skipping {
                    // No signal trampoline found: keep everything.
                    addresses = (0..<Int(stuckDepth)).compactMap { stuckFrames[$0].map { UInt(bitPattern: $0) } }
                }
                if addresses == previous {
                    text += "main thread stack \(index): same as the one before\n"
                } else {
                    text += "main thread stack \(index) (\(addresses.count) frames):\n"
                    for address in addresses.prefix(top) {
                        text += "  " + String(symbolName(UnsafeMutableRawPointer(bitPattern: address)!).prefix(240)) + "\n"
                    }
                }
                previous = addresses
            }
            if index < samples { usleep(gap) }
        }
        return text
    }

    private static func symbolName(_ address: UnsafeMutableRawPointer) -> String {
        var info = Dl_info()
        if dladdr(address, &info) != 0, let symbol = info.dli_sname {
            return demangle(String(cString: symbol))
        }
        if dladdr(address, &info) != 0, let image = info.dli_fname {
            return "(\(URL(fileURLWithPath: String(cString: image)).lastPathComponent))"
        }
        return "?"
    }

    private typealias Demangle = @convention(c) (UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32) -> UnsafeMutablePointer<CChar>?
    private static let swiftDemangle: Demangle? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle") else { return nil }
        return unsafeBitCast(symbol, to: Demangle.self)
    }()

    private static func demangle(_ symbol: String) -> String {
        guard symbol.hasPrefix("$s") || symbol.hasPrefix("_$s"), let swiftDemangle else { return symbol }
        return symbol.withCString { pointer in
            guard let output = swiftDemangle(pointer, strlen(pointer), nil, nil, 0) else { return symbol }
            defer { free(output) }
            return String(cString: output)
        }
    }
}
#endif
