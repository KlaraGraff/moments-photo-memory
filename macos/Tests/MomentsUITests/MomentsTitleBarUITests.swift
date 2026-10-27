import XCTest

/// As in every Apple app, a double click on an empty part of the window's top
/// bar (title bar and toolbar) does what System Settings ▸ Desktop & Dock says,
/// zooming the window by default, on every page.
final class MomentsTitleBarUITests: XCTestCase {
    private let launchTimeout: TimeInterval = 30

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
    }

    func testDoubleClickOnTheTopBarZoomsTheWindow() {
        let setting = UserDefaults(suiteName: UserDefaults.globalDomain)?.string(forKey: "AppleActionOnDoubleClick") ?? "(default)"
        print("TITLEBAR AppleActionOnDoubleClick=\(setting)")
        if setting == "Minimize" || setting == "None" {
            // This Mac is set to minimize or do nothing; zooming is not expected.
            return
        }
        let app = XCUIApplication()
        app.launchArguments = ["-MomentsUITesting", "-AppleLanguages", "(en)", "-AppleLocale", "en"]
        app.launch()
        app.activate()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: launchTimeout))
        let library = app.descendants(matching: .any).matching(identifier: "sidebar.library").firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: launchTimeout))

        var results: [String] = []
        for page in ["sidebar.library", "sidebar.people", "sidebar.map", "sidebar.timeline", "sidebar.trips"] {
            let item = app.descendants(matching: .any).matching(identifier: page).firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: launchTimeout), "Missing \(page)")
            item.click()
            Thread.sleep(forTimeInterval: 1)
            // Above the sidebar, right of the window buttons; and the middle
            // of the page's toolbar, left of its buttons.
            for spot in ["sidebar top", "toolbar middle"] {
                let before = window.frame
                let point = spot == "sidebar top"
                    ? CGVector(dx: 110, dy: 16)
                    : CGVector(dx: before.width * 0.5, dy: 26)
                window.coordinate(withNormalizedOffset: .zero).withOffset(point).doubleClick()
                Thread.sleep(forTimeInterval: 1.5)
                let after = window.frame
                let zoomed = after != before
                results.append("\(page) \(spot) at \(point): \(zoomed ? "zoomed" : "NOTHING") \(before) -> \(after)")
                XCTAssertTrue(zoomed, "Double click on \(page) \(spot) did not zoom the window")
                if zoomed {
                    // Back to where it was for the next spot.
                    window.coordinate(withNormalizedOffset: .zero).withOffset(point).doubleClick()
                    Thread.sleep(forTimeInterval: 1.5)
                }
            }
        }
        print("TITLEBAR-REPORT-BEGIN\n\(results.joined(separator: "\n"))\nTITLEBAR-REPORT-END")
        let shot = XCTAttachment(screenshot: window.screenshot())
        shot.name = "titlebar-window"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
