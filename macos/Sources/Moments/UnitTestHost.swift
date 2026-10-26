#if DEBUG
import AppKit
import SwiftUI

/// Unit tests run inside the app as their host process. That host must stay
/// invisible: no Dock icon, no window, no focus change, so a test run never
/// interrupts whoever is using the Mac. UI tests (-MomentsUITesting or
/// -MomentsUITestStoreDirectory) are not affected; they need the real window.
final class UnitTestHostDelegate: NSObject, NSApplicationDelegate {
    static let isUnitTestHost: Bool = {
        let process = ProcessInfo.processInfo
        return process.environment["XCTestConfigurationFilePath"] != nil
            && !process.arguments.contains("-MomentsUITesting")
            && !process.arguments.contains("-MomentsUITestStoreDirectory")
    }()

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard Self.isUnitTestHost else { return }
        NSApp.setActivationPolicy(.prohibited)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.arguments.contains("-MomentsUITesting") {
            // Each UI test starts from the demo store; trip locks and covers
            // from the test before must not carry over (they live in a test suite).
            TripAssignmentLocks.store.removeObject(forKey: TripAssignmentLocks.defaultsKey)
            TripAssignmentLocks.store.removeObject(forKey: TripCoverChoice.defaultsKey)
            ensureUITestWindow()
            return
        }
        guard Self.isUnitTestHost else { return }
        NSApp.windows.forEach { $0.orderOut(nil) }
    }

    /// On CI, launches with -MomentsUITesting plus the language arguments
    /// sometimes leave SwiftUI's WindowGroup without its initial window. UI
    /// tests need one, so the app opens it itself through its own File > New
    /// Window command; no keystroke ever leaves the app.
    private func ensureUITestWindow() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) else { return }
            let items = NSApp.mainMenu?.items.flatMap { $0.submenu?.items ?? [] } ?? []
            guard let newWindow = items.first(where: { $0.keyEquivalent == "n" && $0.keyEquivalentModifierMask == .command }),
                  let action = newWindow.action else { return }
            NSApp.sendAction(action, to: newWindow.target, from: newWindow)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

}

/// Placed as the only content of the unit-test host's window; hides that
/// window as soon as it exists.
struct UnitTestHostWindowHider: NSViewRepresentable {
    func makeNSView(context: Context) -> HidingView { HidingView() }
    func updateNSView(_ nsView: HidingView, context: Context) {}

    final class HidingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.orderOut(nil)
        }
    }
}
#endif
