import XCTest

/// As in every Apple app, a double click on the window's top bar (the page
/// title, the empty toolbar) does what System Settings ▸ Desktop & Dock says,
/// zoom by default, on every page. Toolbar controls and the page's own rows
/// below the bar keep their clicks.
final class MomentsTitleBarUITests: XCTestCase {
    private let launchTimeout: TimeInterval = 30

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testDoubleClickOnTheTopBarZoomsTheWindow() throws {
        let setting = UserDefaults(suiteName: UserDefaults.globalDomain)?.string(forKey: "AppleActionOnDoubleClick")
        if setting == "Minimize" || setting == "None" {
            throw XCTSkip("This Mac is set to \(setting ?? "") on a title bar double click")
        }
        let log = "/tmp/moments-titlebar-\(UUID().uuidString).log"
        let app = XCUIApplication()
        app.launchArguments = ["-MomentsUITesting", "-MomentsUITestTitleBarLog", log, "-AppleLanguages", "(en)", "-AppleLocale", "en"]
        app.launch()
        app.activate()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: launchTimeout))
        let title = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 260, dy: 26))

        // The page title, on every page.
        for page in ["sidebar.people", "sidebar.map", "sidebar.timeline", "sidebar.trips", "sidebar.library"] {
            let item = element(in: app, identifier: page)
            XCTAssertTrue(item.waitForExistence(timeout: launchTimeout), "Missing \(page)")
            item.click()
            Thread.sleep(forTimeInterval: 1)
            assertDoubleClickTogglesZoom(window, at: title, "the title on \(page)")
        }

        let more = element(in: app, identifier: "library.type-more")
        XCTAssertTrue(more.waitForExistence(timeout: launchTimeout))
        for size in ["small", "large"] {
            Thread.sleep(forTimeInterval: 1)
            assertDoubleClickTogglesZoom(window, at: title, "the Library title (\(size) window)")
            // The Library's own row under the bar is page content.
            let row = window.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: more.frame.maxX + 16 - window.frame.minX, dy: more.frame.midY - window.frame.minY))
            assertDoubleClickLeavesWindow(window, at: row, "the Library header row (\(size) window)")
            // A toolbar control is that control's.
            let search = app.searchFields.firstMatch
            if search.exists {
                assertDoubleClickLeavesWindow(window, at: search.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)), "the search field (\(size) window)")
                app.typeKey(.escape, modifierFlags: [])
            }
            if size == "small" {
                let before = window.frame
                title.doubleClick()
                Thread.sleep(forTimeInterval: 1.2)
                XCTAssertNotEqual(window.frame, before, "Could not zoom the window for the large pass")
            }
        }

        let report = (try? String(contentsOfFile: log, encoding: .utf8)) ?? "(no log)"
        print("TITLEBAR-LOG-BEGIN\n\(report)\nTITLEBAR-LOG-END")
        if report != "(no log)" {
            // The app takes the double click itself rather than leaving it to AppKit.
            XCTAssertTrue(report.contains("handled"), report)
        }
    }

    /// Double-clicks twice: the window changes size once, then goes back.
    private func assertDoubleClickTogglesZoom(_ window: XCUIElement, at point: XCUICoordinate, _ place: String) {
        let before = window.frame
        point.doubleClick()
        Thread.sleep(forTimeInterval: 1.2)
        XCTAssertNotEqual(window.frame, before, "A double click on \(place) did not zoom the window")
        point.doubleClick()
        Thread.sleep(forTimeInterval: 1.2)
        XCTAssertEqual(window.frame, before, "A second double click on \(place) did not restore the window")
    }

    private func assertDoubleClickLeavesWindow(_ window: XCUIElement, at point: XCUICoordinate, _ place: String) {
        let before = window.frame
        point.doubleClick()
        Thread.sleep(forTimeInterval: 1.2)
        XCTAssertEqual(window.frame, before, "A double click on \(place) resized the window")
    }

    private func element(in app: XCUIApplication, identifier: String) -> XCUIElement {
        XCTAssertEqual(app.state, .runningForeground, "Moments lost focus; stopping before clicking another app")
        return app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
