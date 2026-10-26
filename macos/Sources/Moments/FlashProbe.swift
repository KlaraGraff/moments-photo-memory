#if DEBUG
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// UI-test-only, enabled by `-MomentsUITestFlashDir <folder>`: after every
/// click or key press it captures Moments' own windows about 60 times a
/// second for 1.5 s and writes a per-frame report plus the frames of any
/// flash (a frame that differs from both the frame before the click and the
/// settled frame) into the folder. Own windows need no screen-recording
/// permission, so this also works on the CI Mac.
@MainActor
enum FlashProbe {
    private struct Frame {
        let time: TimeInterval
        let image: CGImage
        let luma: [Float]
    }

    private static var folder: URL?
    private static var monitor: Any?
    private static var timer: Timer?
    private static var deadline: TimeInterval = 0
    private static var session: (label: String, start: TimeInterval, before: [Int: Frame], frames: [Int: [Frame]])?
    private static var sessionCount = 0
    private static var report = ""
    private static let clock = CACurrentMediaTime()

    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    /// CGWindowListCreateImage is unavailable to Swift on the current SDK but
    /// still present; it captures this app's own windows without permission.
    private static let createImage: CreateImage? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
              let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(symbol, to: CreateImage.self)
    }()

    static func startIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-MomentsUITestFlashDir"), index + 1 < arguments.count else { return }
        let url = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        folder = url
        append("capture available: \(createImage != nil)")
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { event in
            MainActor.assumeIsolated {
                let label = event.type == .keyDown ? "key \(event.charactersIgnoringModifiers ?? "")" : "click in \(event.window?.title ?? "-")"
                begin(label)
            }
            return event
        }
    }

    private static func now() -> TimeInterval { CACurrentMediaTime() - clock }

    private static func begin(_ label: String) {
        finishSession()
        // The event has not been handled yet, so this is the frame before the click.
        var before: [Int: Frame] = [:]
        for window in captureWindows() { before[window.key] = window.value }
        session = (label, now(), before, [:])
        deadline = now() + 1.5
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private static func tick() {
        guard session != nil else { return }
        for (number, frame) in captureWindows() {
            // Keep only frames that changed, so a session holds a few images, not 90.
            if let last = session?.frames[number]?.last, changedShare(frame.luma, last.luma) == 0 { continue }
            session?.frames[number, default: []].append(frame)
        }
        if now() > deadline {
            finishSession()
            timer?.invalidate()
            timer = nil
        }
    }

    private static func captureWindows() -> [Int: Frame] {
        guard let createImage else { return [:] }
        var result: [Int: Frame] = [:]
        let time = now()
        for window in NSApp.windows where window.isVisible && window.windowNumber > 0 {
            // .optionIncludingWindow = 1 << 3, .boundsIgnoreFraming = 1 << 0, .nominalResolution = 1 << 4
            guard let image = createImage(.null, 1 << 3, UInt32(window.windowNumber), (1 << 0) | (1 << 4))?.takeRetainedValue(),
                  image.width > 8, image.height > 8 else { continue }
            result[window.windowNumber] = Frame(time: time, image: image, luma: lumaGrid(image))
        }
        return result
    }

    /// A 48x30 luma grid is enough to see a window-wide flash.
    private static func lumaGrid(_ image: CGImage) -> [Float] {
        let w = 48, h = 30
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.interpolationQuality = .medium
            context?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return (0..<(w * h)).map { i in
            (0.2126 * Float(pixels[i * 4]) + 0.7152 * Float(pixels[i * 4 + 1]) + 0.0722 * Float(pixels[i * 4 + 2])) / 255
        }
    }

    private static func changedShare(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 1 }
        var changed = 0
        for i in a.indices where abs(a[i] - b[i]) > 0.08 { changed += 1 }
        return Float(changed) / Float(a.count)
    }

    private static func finishSession() {
        guard let current = session else { return }
        session = nil
        sessionCount += 1
        var text = String(format: "#%d %@ at %.2fs\n", sessionCount, current.label, current.start)
        for (number, frames) in current.frames.sorted(by: { $0.key < $1.key }) {
            guard let settled = frames.last else { continue }
            let before = current.before[number]
            var worst: Frame?
            var worstScore: Float = 0
            var lines: [String] = []
            for frame in frames {
                let vsBefore = before.map { changedShare(frame.luma, $0.luma) } ?? 1
                let vsEnd = changedShare(frame.luma, settled.luma)
                let mean = frame.luma.reduce(0, +) / Float(max(frame.luma.count, 1))
                lines.append(String(format: "%4.0fms %dx%d mean %.3f vsBefore %.2f vsEnd %.2f",
                                    (frame.time - current.start) * 1000, frame.image.width, frame.image.height, mean, vsBefore, vsEnd))
                let score = min(vsBefore, vsEnd)
                if score > worstScore { worstScore = score; worst = frame }
            }
            let flash = worstScore > 0.2
            text += String(format: "  window %d: %d changed frames, worst transient %.2f%@\n", number, frames.count, worstScore, flash ? " FLASH" : "")
            // Only frames whose content changed, to keep the log readable.
            var previous: String?
            for line in lines {
                let key = String(line.dropFirst(7))
                if key != previous { text += "    \(line)\n" }
                previous = key
            }
            if flash, let worst {
                if let before { write(before.image, name: "\(sessionCount)-w\(number)-1-before") }
                write(worst.image, name: "\(sessionCount)-w\(number)-2-flash")
                write(settled.image, name: "\(sessionCount)-w\(number)-3-after")
            }
        }
        append(text)
    }

    private static func write(_ image: CGImage, name: String) {
        guard let folder,
              let destination = CGImageDestinationCreateWithURL(folder.appending(path: "\(name).png") as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    private static func append(_ text: String) {
        report += text + "\n"
        guard let folder else { return }
        try? report.write(to: folder.appending(path: "report.txt"), atomically: true, encoding: .utf8)
    }
}
#endif
