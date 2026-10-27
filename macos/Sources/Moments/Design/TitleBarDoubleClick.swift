import AppKit

/// A double click on an empty part of the window's top bar (title, toolbar
/// background) does what System Settings ▸ Desktop & Dock says ("Double-click
/// a window's title bar to"), as in every Apple app.
///
/// AppKit does this on its own (it does on the hosted test Mac), but on
/// maple's Mac a double click on the page title left the window as it was,
/// while the same zoom started by the app worked. So the app watches the
/// double click, and when the window hasn't changed once it is over, does
/// the action itself. It never acts twice.
@MainActor
enum TitleBarDoubleClick {
    private static var monitor: Any?
    /// The window whose bar got the second click, and its frame then.
    private static var pending: (window: NSWindow, frame: NSRect)?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
            // Local monitors run on the main thread.
            MainActor.assumeIsolated { watch(event) }
            return event
        }
    }

    private static func watch(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            pending = nil
            guard event.clickCount == 2, let window = event.window,
                  isOnEmptyTopBar(event, in: window) else { return }
            pending = (window, window.frame)
        case .leftMouseUp:
            guard let press = pending else { return }
            pending = nil
            let window = press.window, frame = press.frame
            // Long enough for AppKit's own zoom or fill to have started.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let untouched = window.frame == frame && !window.isMiniaturized
                if untouched { perform(in: window) }
                #if DEBUG
                TitleBarProbe.note("\(untouched ? "performed" : "left to AppKit") \(frame) -> \(window.frame)")
                #endif
            }
        default:
            break
        }
    }

    static func perform(in window: NSWindow) {
        let defaults = UserDefaults.standard
        var action = defaults.string(forKey: "AppleActionOnDoubleClick")
        #if DEBUG
        // UI tests turn AppKit's own action off and give the app one, to
        // stand in for a Mac where AppKit's does nothing.
        if let stand = defaults.string(forKey: "MomentsUITestTitleBarAction") { action = stand }
        #endif
        switch action {
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
            // The page title is a label (a text field that can't be edited
            // or selected); a double click there belongs to the window.
            let isLabel = (current as? NSTextField).map { !$0.isEditable && !$0.isSelectable } ?? false
            if (current is NSControl && !isLabel) || current is NSText || name.contains("ItemViewer") { isControl = true }
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
