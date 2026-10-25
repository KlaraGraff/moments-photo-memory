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
        guard Self.isUnitTestHost else { return }
        NSApp.windows.forEach { $0.orderOut(nil) }
    }

    /// UI tests start from a clean slate without the -ApplePersistenceIgnoreState
    /// launch argument: combined with -MomentsUITesting that argument left
    /// SwiftUI's WindowGroup without its initial window.
    func application(_ application: NSApplication, shouldRestoreSecureApplicationState coder: NSCoder) -> Bool {
        !ProcessInfo.processInfo.arguments.contains("-MomentsUITesting")
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
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
