import XCTest

/// Temporary diagnostic (remove after the cause is fixed): which launch
/// arguments leave Moments without a window?
final class LaunchDiagnosticsUITests: XCTestCase {
    func testWhichLaunchArgumentsOpenAWindow() {
        let store = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("moments-diag-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: store, withIntermediateDirectories: true)
        let variants: [(String, [String])] = [
            ("store-dir only", ["-MomentsUITestStoreDirectory", store, "-ApplePersistenceIgnoreState", "YES"]),
            ("uitesting only", ["-MomentsUITesting", "-ApplePersistenceIgnoreState", "YES"]),
            ("uitesting + language", ["-MomentsUITesting", "-AppleLanguages", "(en)", "-AppleLocale", "en", "-ApplePersistenceIgnoreState", "YES"]),
            ("language only + store", ["-MomentsUITestStoreDirectory", store, "-AppleLanguages", "(en)", "-AppleLocale", "en", "-ApplePersistenceIgnoreState", "YES"]),
            ("uitesting, no persistence flag", ["-MomentsUITesting"])
        ]
        var lines: [String] = []
        for (name, arguments) in variants {
            let app = XCUIApplication()
            app.launchArguments = arguments
            let started = Date()
            app.launch()
            app.activate()
            let found = app.windows.firstMatch.waitForExistence(timeout: 15)
            lines.append("\(name): window=\(found) after \(String(format: "%.1f", Date().timeIntervalSince(started)))s state=\(app.state.rawValue) windows=\(app.windows.count)")
            app.terminate()
        }
        let note = XCTAttachment(string: lines.joined(separator: "\n"))
        note.name = "launch-diagnostics"
        note.lifetime = .keepAlways
        add(note)
        print("LAUNCH-DIAG\n" + lines.joined(separator: "\n"))
    }
}
