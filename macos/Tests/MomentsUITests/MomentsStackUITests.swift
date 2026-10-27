import AppKit
import XCTest

/// Bursts: four look-alike synthetic shots a second apart show as one stack
/// with a count; the viewer's strip switches between them, sets the cover,
/// and takes the stack apart with Undo.
final class MomentsStackUITests: XCTestCase {
    private let timeout: TimeInterval = 15
    private var app: XCUIApplication?

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// A failure carries a picture of the window, printed in the job log.
    override func record(_ issue: XCTIssue) {
        var issue = issue
        if let app {
            let line = issue.sourceCodeContext.location?.lineNumber ?? 0
            let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            attachment.name = "stack-failure-line-\(line)-evidence"
            attachment.lifetime = .keepAlways
            issue.add(attachment)
        }
        super.record(issue)
    }

    func testBurstShowsAsAStackAndTheViewerPicksTheCover() {
        let app = launch()
        let shown = element(app, "library.stack.demo-burst-1").waitForExistence(timeout: timeout)
        capture(app, "stack-01-library-evidence")
        XCTAssertTrue(shown, "The burst did not show as a stack")
        XCTAssertFalse(element(app, "library.photo.demo-burst-2").exists, "A burst shot showed on its own next to its stack")

        // Open the stack: the strip lists every shot.
        element(app, "library.photo.demo-burst-1").doubleClick()
        XCTAssertTrue(element(app, "viewer").waitForExistence(timeout: timeout))
        XCTAssertTrue(element(app, "viewer.stack").waitForExistence(timeout: timeout), "The viewer has no strip for the stack")
        for index in 1...4 {
            XCTAssertTrue(element(app, "viewer.stack.demo-burst-\(index)").exists, "Shot \(index) is missing from the strip")
        }
        capture(app, "stack-02-viewer-strip-evidence")

        // The arrow walks the stack's shots before leaving it.
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(waitForSelected(element(app, "viewer.stack.demo-burst-2")), "The right arrow did not move to the next shot")

        // Click the third shot and make it the cover.
        clickCentre(element(app, "viewer.stack.demo-burst-3"))
        XCTAssertTrue(waitForSelected(element(app, "viewer.stack.demo-burst-3")))
        let setCover = element(app, "viewer.stack.setCover")
        XCTAssertTrue(setCover.isEnabled)
        clickCentre(setCover)
        XCTAssertTrue(element(app, "viewer.stack.undo").waitForExistence(timeout: timeout), "No Undo after changing the cover")
        XCTAssertFalse(setCover.isEnabled, "The cover's own button should be off")
        capture(app, "stack-03-cover-set-evidence")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(element(app, "viewer").waitForNonExistence(timeout: timeout))
        XCTAssertTrue(element(app, "library.stack.demo-burst-3").waitForExistence(timeout: timeout), "The Library does not show the new cover")

        // Take the stack apart: every shot shows on its own; ⌘Z stacks them again.
        pauseLongerThanADoubleClick()
        element(app, "library.photo.demo-burst-3").doubleClick()
        XCTAssertTrue(element(app, "viewer.stack.unstack").waitForExistence(timeout: timeout))
        clickCentre(element(app, "viewer.stack.unstack"))
        XCTAssertTrue(element(app, "viewer.stack").waitForNonExistence(timeout: timeout), "The strip stayed after unstacking")
        capture(app, "stack-04-unstacked-viewer-evidence")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(element(app, "library.photo.demo-burst-2").waitForExistence(timeout: timeout), "Unstacked shots do not show on their own")
        capture(app, "stack-05-unstacked-library-evidence")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(element(app, "library.stack.demo-burst-3").waitForExistence(timeout: timeout), "⌘Z did not stack the shots again")
        XCTAssertTrue(element(app, "library.photo.demo-burst-2").waitForNonExistence(timeout: timeout))
    }

    func testStacksInASmallWindowAndTheDenseGrid() {
        let app = launch(extra: ["-MomentsUITestSmallWindow", "-moments.library.photosPerRow", "8"])
        let shown = element(app, "library.stack.demo-burst-1").waitForExistence(timeout: timeout)
        capture(app, "stack-06-small-dense-grid-evidence")
        XCTAssertTrue(shown)
        element(app, "library.photo.demo-burst-1").doubleClick()
        XCTAssertTrue(element(app, "viewer.stack").waitForExistence(timeout: timeout))
        let window = app.windows.firstMatch
        XCTAssertTrue(window.frame.contains(element(app, "viewer.stack").frame), "The strip spills outside a small window")
        let unstack = element(app, "viewer.stack.unstack")
        XCTAssertTrue(unstack.exists && !unstack.frame.isEmpty && window.frame.contains(unstack.frame), "The stack buttons do not fit a small window")
        capture(app, "stack-07-small-viewer-evidence")
    }

    func testStackOnTheTimeline() {
        let app = launch()
        XCTAssertTrue(element(app, "library.stack.demo-burst-1").waitForExistence(timeout: timeout))
        element(app, "sidebar.timeline").click()
        let stack = element(app, "trips.stack.demo-burst-1")
        XCTAssertTrue(stack.waitForExistence(timeout: timeout), "The Timeline does not show the burst as a stack")
        XCTAssertFalse(element(app, "trips.photo.demo-burst-2").exists)
        capture(app, "stack-08-timeline-evidence")
    }

    private func launch(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-MomentsUITesting", "-MomentsUITestBurst", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh-Hans"] + extra
        app.launch()
        app.activate()
        self.app = app
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: timeout))
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: timeout))
        return app
    }

    private func waitForSelected(_ element: XCUIElement) -> Bool {
        // The open shot carries the Selected trait.
        let selected = NSPredicate(format: "selected == true")
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: selected, object: element)], timeout: timeout) == .completed
    }

    /// XCUITest does not count the viewer's strip and header buttons as
    /// hittable over the dimmed window, so they are clicked where they are.
    private func clickCentre(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    private func pauseLongerThanADoubleClick() {
        RunLoop.current.run(until: Date().addingTimeInterval(NSEvent.doubleClickInterval + 0.3))
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        // Only the app window, never the rest of the desktop.
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
