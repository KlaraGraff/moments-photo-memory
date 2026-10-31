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

    /// Call on the main thread. Every `interval` microseconds; 2 ms covers
    /// 24 s before the buffer is full, longer intervals cover longer runs.
    static func start(interval: UInt32 = 2_000) {
        mainThread = pthread_self()
        count = 0
        self.interval = interval
        // Allocate the buffers here: the signal handler must not malloc.
        _ = frames
        _ = depths
        generation += 1
        let run = generation
        if !installed {
            installed = true
            signal(SIGUSR2) { _ in MainThreadSampler.record() }
        }
        recording = true
        Thread.detachNewThread {
            while recording, generation == run, let mainThread {
                pthread_kill(mainThread, SIGUSR2)
                usleep(interval)
            }
        }
    }

    private static func record() {
        guard recording, count < maxSamples else { return }
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
        var text = "main thread samples: \(count) (every \(Double(interval) / 1_000) ms)\n"
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
