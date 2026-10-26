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
            clicks.append((name, name != "map"))
            Thread.sleep(forTimeInterval: 2)
        }
        func blank(_ name: String) {
            XCTAssertEqual(app.state, .runningForeground, "Moments lost focus; stopping before clicking another app")
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.08)).click()
            clicks.append((name, true))
            Thread.sleep(forTimeInterval: 2)
        }
        for name in ["people", "map", "timeline", "library", "people", "library", "library"] {
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
        XCTAssertTrue(report.hasPrefix("capture available: true"), "The app could not capture its window:\n\(report)")
        // Sessions are "#<n> ..." blocks; a flashing window line ends in FLASH.
        let sessions = report.components(separatedBy: "\n#").dropFirst()
        XCTAssertGreaterThanOrEqual(sessions.count, clicks.count, "Missing capture sessions:\n\(report)")
        for (click, session) in zip(clicks, sessions) where click.judged {
            XCTAssertTrue(session.contains(" frames, worst transient"), "No frames captured after clicking \(click.name):\n#\(session)")
            XCTAssertFalse(session.contains("FLASH"), "The window flashed after clicking \(click.name):\n#\(session)")
        }
    }
}

/// maple's windows (900 and 1111 pt wide, English): the media-type switcher
/// was capped below its natural width, so AppKit drew it wider than its slot,
/// over the photo count, and every data change flipped it between the two.
final class MomentsLibraryHeaderUITests: XCTestCase {
    private let launchTimeout: TimeInterval = 12

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testTypeSwitcherStaysInItsSlotAt900() throws { try checkHeader(width: "900") }
    func testTypeSwitcherStaysInItsSlotAt1111() throws { try checkHeader(width: "1111") }
    func testTypeSwitcherStaysInItsSlotAt1440() throws { try checkHeader(width: "1440") }

    private func checkHeader(width: String) throws {
        let app = XCUIApplication()
        var arguments = ["-MomentsUITesting", "-AppleLanguages", "(en)", "-AppleLocale", "en", "-MomentsUITestWindowWidth", width]
        let flashFolder = ProcessInfo.processInfo.environment["MOMENTS_FLASH_DIR"].map { $0 + "/header-\(width)" }
        if let flashFolder { arguments += ["-MomentsUITestFlashDir", flashFolder] }
        app.launchArguments = arguments
        app.launch()
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: launchTimeout))
        let title = app.descendants(matching: .any).matching(identifier: "library.title").firstMatch
        let count = app.descendants(matching: .any).matching(identifier: "library.photoCount").firstMatch
        let picker = app.descendants(matching: .any).matching(identifier: "library.type-filter").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: launchTimeout))
        // The page title moved to the window's title bar (#74); the count sits
        // under the filters. Both checks still hold where they apply.
        XCTAssertTrue(count.exists)
        let sidebar = app.descendants(matching: .any).matching(identifier: "sidebar.library").firstMatch
        Thread.sleep(forTimeInterval: 1)

        func assertInSlot(_ moment: String) {
            let p = picker.frame, c = count.frame
            let t = title.exists ? title.frame : .null
            let message = "\(moment) at width \(width): switcher \(p), title \(t), count \(c)"
            print("HEADER-GEOMETRY \(message)")
            if title.exists {
                XCTAssertGreaterThanOrEqual(p.minX, t.minX - 1, "Switcher pokes out left of the header inset. \(message)")
            } else {
                XCTAssertGreaterThan(p.minX, sidebar.frame.maxX, "Switcher pokes into the sidebar. \(message)")
            }
            XCTAssertFalse(p.insetBy(dx: 1, dy: 1).intersects(c), "Switcher covers the photo count. \(message)")
            if title.exists {
                XCTAssertFalse(p.insetBy(dx: 1, dy: 1).intersects(t), "Switcher covers the title. \(message)")
            }
        }
        assertInSlot("at rest")

        // Favouriting saves the store and rebuilds the Library; maple saw the
        // switcher jump on every one.
        let star = app.buttons.matching(NSPredicate(format: "label == %@", "Favorite")).firstMatch
        XCTAssertTrue(star.waitForExistence(timeout: launchTimeout))
        for round in 1...4 {
            XCTAssertEqual(app.state, .runningForeground, "Moments lost focus; stopping before clicking another app")
            star.click()
            Thread.sleep(forTimeInterval: 1.8)
            assertInSlot("after favourite click \(round)")
        }
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 2)
        if let flashFolder,
           let report = try? String(contentsOf: URL(fileURLWithPath: flashFolder).appending(path: "report.txt"), encoding: .utf8) {
            print("HEADER-FLASH-REPORT \(width)\n\(report)")
            XCTAssertFalse(report.contains("FLASH"), "The window flashed on a favourite click at width \(width):\n\(report)")
            XCTAssertFalse(report.contains("CONTROL-JUMP"), "A control jumped on a favourite click at width \(width):\n\(report)")
        }
    }
}
