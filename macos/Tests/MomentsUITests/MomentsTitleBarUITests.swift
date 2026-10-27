import XCTest

/// As in every Apple app, a double click on an empty part of the window's top
/// bar does what System Settings ▸ Desktop & Dock says (zoom by default), on
/// every page. The Library's header row continues the title bar's paper, so
/// it does the same; controls keep their own clicks.
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
        let app = XCUIApplication()
        app.launchArguments = ["-MomentsUITesting", "-AppleLanguages", "(en)", "-AppleLocale", "en"]
        app.launch()
        app.activate()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: launchTimeout))
        let corner = window.coordinate(withNormalizedOffset: .zero)

        // The page title in the toolbar, on every page.
        for page in ["sidebar.library", "sidebar.people", "sidebar.map", "sidebar.timeline", "sidebar.trips"] {
            let item = element(in: app, identifier: page)
            XCTAssertTrue(item.waitForExistence(timeout: launchTimeout), "Missing \(page)")
            item.click()
            Thread.sleep(forTimeInterval: 1)
            assertDoubleClickTogglesZoom(window, at: corner.withOffset(CGVector(dx: 260, dy: 26)), "the title bar on \(page)")
        }

        // The Library's header row, at the small starting size and again
        // with the window filling the screen.
        element(in: app, identifier: "sidebar.library").click()
        let more = element(in: app, identifier: "library.type-more")
        let types = element(in: app, identifier: "library.type-filter")
        XCTAssertTrue(more.waitForExistence(timeout: launchTimeout))
        for size in ["small", "large"] {
            Thread.sleep(forTimeInterval: 1)
            let gap = window.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: more.frame.maxX + 16 - window.frame.minX, dy: more.frame.midY - window.frame.minY))
            assertDoubleClickTogglesZoom(window, at: gap, "the Library header row (\(size) window)")

            // A double click on a control is that control's, not the window's.
            let before = window.frame
            types.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick()
            Thread.sleep(forTimeInterval: 1.2)
            XCTAssertEqual(window.frame, before, "A double click on the type picker resized the window")

            if size == "small" {
                corner.withOffset(CGVector(dx: 260, dy: 26)).doubleClick()
                Thread.sleep(forTimeInterval: 1.2)
                XCTAssertNotEqual(window.frame, before, "Could not zoom the window for the large pass")
            }
        }
    }

    /// Double-clicks twice: the window changes size, then goes back.
    private func assertDoubleClickTogglesZoom(_ window: XCUIElement, at point: XCUICoordinate, _ place: String) {
        let before = window.frame
        point.doubleClick()
        Thread.sleep(forTimeInterval: 1.2)
        XCTAssertNotEqual(window.frame, before, "A double click on \(place) did not zoom the window")
        point.doubleClick()
        Thread.sleep(forTimeInterval: 1.2)
        XCTAssertEqual(window.frame, before, "A second double click on \(place) did not restore the window")
    }

    private func element(in app: XCUIApplication, identifier: String) -> XCUIElement {
        XCTAssertEqual(app.state, .runningForeground, "Moments lost focus; stopping before clicking another app")
        return app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
