import AppKit

/// A double click on an empty part of the window's top bar (title, toolbar
/// background) does what System Settings ▸ Desktop & Dock says ("Double-click
/// a window's title bar to"), as in every Apple app.
///
/// AppKit does this on its own, but on maple's Mac it did nothing over the
/// page title while the same zoom, started by the app, worked. So the app
/// takes the double click itself and leaves AppKit nothing to do twice.
@MainActor
enum TitleBarDoubleClick {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            // Local monitors run on the main thread.
            MainActor.assumeIsolated { take(event) } ? nil : event
        }
    }

    /// True when the event was a double click on the bar and is handled here.
    private static func take(_ event: NSEvent) -> Bool {
        guard event.clickCount == 2, let window = event.window,
              isOnEmptyTopBar(event, in: window) else { return false }
        perform(in: window)
        #if DEBUG
        TitleBarProbe.note("performed \(UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "default") from \(window.frame)")
        #endif
        return true
    }

    static func perform(in window: NSWindow) {
        let defaults = UserDefaults.standard
        switch defaults.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize":
            window.performMiniaturize(nil)
        case "None":
            break
        case nil where defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick"):
            // The older setting, from before the action had a menu.
            window.performMiniaturize(nil)
        default:
            // "Maximize" (Zoom), "Fill" and the default all make the window fill the screen.
            window.performZoom(nil)
        }
    }

    /// Above the content, on the bar itself or the title, not on a button,
    /// the search field or another toolbar item.
    private static func isOnEmptyTopBar(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard window.styleMask.contains(.titled), !window.styleMask.contains(.fullScreen),
              window.attachedSheet == nil,
              event.locationInWindow.y > window.contentLayoutRect.maxY,
              let frameView = window.contentView?.superview else { return false }
        var view = frameView.hitTest(frameView.convert(event.locationInWindow, from: nil))
        var chain: [String] = []
        var isControl = false
        while let current = view {
            let name = String(describing: type(of: current))
            chain.append(name)
            if current is NSControl || current is NSText || name.contains("ItemViewer") { isControl = true }
            view = current.superview
        }
        #if DEBUG
        TitleBarProbe.record(handled: !isControl, chain: chain)
        #endif
        return !isControl
    }
}

#if DEBUG
/// UI tests: which views a top bar double click landed on, and whether the
/// app took it (-MomentsUITestTitleBarLog <file>).
enum TitleBarProbe {
    static func record(handled: Bool, chain: [String]) {
        note("\(handled ? "handled" : "skipped") \(chain.prefix(6).joined(separator: " < "))")
    }

    static func note(_ text: String) {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-MomentsUITestTitleBarLog"), index + 1 < arguments.count else { return }
        let line = text + "\n"
        let url = URL(fileURLWithPath: arguments[index + 1])
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
#endif
