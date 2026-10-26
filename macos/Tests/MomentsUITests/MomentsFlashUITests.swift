import XCTest

/// Clicks must not make the window flash. The app records its own windows
/// after every click (FlashProbe, -MomentsUITestFlashDir); a flash is a frame
/// that differs from both the frame before the click and the settled frame.
/// The CI workflow prints the report and the frames of any flash.
final class MomentsFlashUITests: XCTestCase {
    private let launchTimeout: TimeInterval = 12

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testClicksDoNotFlashTheWindow() throws {
        guard let folder = ProcessInfo.processInfo.environment["MOMENTS_FLASH_DIR"], folder.hasPrefix("/") else {
            throw XCTSkip("MOMENTS_FLASH_DIR was not supplied")
        }
        let reportURL = URL(fileURLWithPath: folder).appending(path: "report.txt")
        try? FileManager.default.removeItem(at: reportURL)
        let app = XCUIApplication()
        app.launchArguments = ["-MomentsUITesting", "-MomentsUITestFlashDir", folder, "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh-Hans"]
        app.launch()
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: launchTimeout))
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: launchTimeout))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "sidebar.library").firstMatch.waitForExistence(timeout: launchTimeout))
        Thread.sleep(forTimeInterval: 3)

        // One capture session per click, in this order. Map screens draw
        // their tiles after appearing, so their sessions are not judged.
        var clicks: [(name: String, judged: Bool)] = []
        func sidebar(_ name: String) {
            XCTAssertEqual(app.state, .runningForeground, "Moments lost focus; stopping before clicking another app")
            let item = app.descendants(matching: .any).matching(identifier: "sidebar.\(name)").firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: launchTimeout))
            item.click()
            clicks.append((name, !["places", "footprints"].contains(name)))
            Thread.sleep(forTimeInterval: 2)
        }
        func blank(_ name: String) {
            XCTAssertEqual(app.state, .runningForeground, "Moments lost focus; stopping before clicking another app")
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.08)).click()
            clicks.append((name, true))
            Thread.sleep(forTimeInterval: 2)
        }
        for name in ["review", "places", "footprints", "timeline", "library", "review", "library", "library"] {
            sidebar(name)
        }
        blank("blank")
        blank("blank-again")
        // A key press ends the last capture session so the report is complete.
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 2)

        let report = try String(contentsOf: reportURL, encoding: .utf8)
        let note = XCTAttachment(string: report)
        note.name = "flash-report"
        note.lifetime = .keepAlways
        add(note)
        // Sessions are "#<n> ..." blocks; a flashing window line ends in FLASH.
        let sessions = report.components(separatedBy: "\n#").dropFirst()
        XCTAssertGreaterThanOrEqual(sessions.count, clicks.count, "Missing capture sessions:\n\(report)")
        for (click, session) in zip(clicks, sessions) where click.judged {
            XCTAssertFalse(session.contains("FLASH"), "The window flashed after clicking \(click.name):\n#\(session)")
        }
    }
}
