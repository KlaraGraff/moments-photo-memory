#if DEBUG
import AppKit
import SwiftUI
import os

/// UI-test-only diagnostics, enabled by -MomentsUITestLayoutProbe. After each
/// sidebar selection change it samples the window, toolbar, split columns and
/// scroll positions every few milliseconds and logs every value that changes,
/// so a CI run shows what moves on screen. The CI workflow prints the log.
enum LayoutProbe {
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("-MomentsUITestLayoutProbe")
    private static let logger = Logger(subsystem: "org.example.Moments.layoutprobe", category: "layout")
    private static let start = Date()

    static func log(_ message: String) {
        guard isEnabled else { return }
        let elapsed = String(format: "%.3f", Date().timeIntervalSince(start))
        logger.notice("LAYOUTPROBE \(elapsed, privacy: .public) \(message, privacy: .public)")
    }

    static func describe(_ rect: CGRect) -> String {
        String(format: "(%.1f,%.1f %.1fx%.1f)", rect.minX, rect.minY, rect.width, rect.height)
    }
}

extension View {
    /// Logs this view's window-space frame whenever SwiftUI lays it out differently.
    @ViewBuilder
    func layoutProbeFrame(_ name: String) -> some View {
        if LayoutProbe.isEnabled {
            background {
                GeometryReader { proxy in
                    Color.clear.onChange(of: proxy.frame(in: .global), initial: true) { _, frame in
                        LayoutProbe.log("view \(name) \(LayoutProbe.describe(frame))")
                    }
                }
            }
        } else {
            self
        }
    }

    /// Samples AppKit geometry for a second after `trigger` changes.
    @ViewBuilder
    func layoutProbeWindow(trigger: String) -> some View {
        if LayoutProbe.isEnabled {
            background { LayoutProbeWindowSampler(trigger: trigger) }
        } else {
            self
        }
    }
}

private struct LayoutProbeWindowSampler: NSViewRepresentable {
    let trigger: String

    func makeNSView(context: Context) -> SamplerView { SamplerView() }

    func updateNSView(_ view: SamplerView, context: Context) {
        view.select(trigger)
    }

    final class SamplerView: NSView {
        private var lastTrigger: String?
        private var lastValues: [String: String] = [:]
        private var timer: Timer?
        private var deadline = Date()
        private var clickMonitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            sample()
            guard clickMonitor == nil else { return }
            // Any click, not only sidebar ones: maple sees the window flash on clicks anywhere.
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
                LayoutProbe.log("mouse \(event.type == .leftMouseDown ? "down" : "up") in \(event.window?.title ?? "-")")
                self?.startSampling()
                return event
            }
        }

        func select(_ trigger: String) {
            guard trigger != lastTrigger else { return }
            lastTrigger = trigger
            LayoutProbe.log("select \(trigger)")
            startSampling()
        }

        private func startSampling() {
            deadline = Date().addingTimeInterval(1.2)
            sample()
            guard timer == nil else { return }
            let timer = Timer(timeInterval: 0.004, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        private func tick() {
            sample()
            if Date() > deadline {
                timer?.invalidate()
                timer = nil
            }
        }

        private func sample() {
            guard let window else { return }
            var values: [String: String] = [
                "window.frame": LayoutProbe.describe(window.frame),
                "window.contentLayoutRect": LayoutProbe.describe(window.contentLayoutRect),
                "window.title": window.title,
                "window.toolbarItems": window.toolbar?.items.map { $0.itemIdentifier.rawValue }.joined(separator: ",") ?? "none",
                "window.titlebarSeparator": "\(window.titlebarSeparatorStyle.rawValue)",
                "window.appearance": window.appearance?.name.rawValue ?? "inherit",
                "window.effectiveAppearance": window.effectiveAppearance.name.rawValue,
                "app.appearance": NSApp.appearance?.name.rawValue ?? "system",
                "app.effectiveAppearance": NSApp.effectiveAppearance.name.rawValue,
                "window.isKey": "\(window.isKeyWindow)",
            ]
            // Every app window, so the Settings window shows up too.
            for other in NSApp.windows where other !== window && other.isVisible {
                values["other[\(other.title)].appearance"] = other.appearance?.name.rawValue ?? "inherit"
                values["other[\(other.title)].effectiveAppearance"] = other.effectiveAppearance.name.rawValue
            }
            if let content = window.contentView {
                collect(content, path: "content", depth: 0, into: &values)
            }
            for (key, value) in values.sorted(by: { $0.key < $1.key }) where lastValues[key] != value {
                LayoutProbe.log("\(key) \(lastValues[key] ?? "-") -> \(value)")
            }
            for key in lastValues.keys where values[key] == nil {
                LayoutProbe.log("\(key) gone")
            }
            lastValues = values
        }

        /// Split view columns and scroll offsets, which is what visibly jumps.
        private func collect(_ view: NSView, path: String, depth: Int, into values: inout [String: String]) {
            guard depth < 40 else { return }
            if let appearance = view.appearance {
                values["\(path).appearance"] = appearance.name.rawValue
            }
            if let split = view as? NSSplitView {
                for (index, column) in split.arrangedSubviews.enumerated() {
                    values["\(path).column\(index)"] = LayoutProbe.describe(column.frame)
                }
            }
            if let scroll = view as? NSScrollView {
                let frame = scroll.convert(scroll.bounds, to: nil)
                values["\(path).scroll"] = "\(LayoutProbe.describe(frame)) offset \(LayoutProbe.describe(scroll.contentView.bounds))"
            }
            for (index, child) in view.subviews.enumerated() {
                collect(child, path: "\(path)/\(index)", depth: depth + 1, into: &values)
            }
        }
    }
}
#endif
