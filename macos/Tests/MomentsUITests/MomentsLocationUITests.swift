import AppKit
import XCTest

/// Set Location: a synthetic photo the camera gave no location gets one by
/// searching a place name (a synthetic search, no network), shows on the map
/// with the hand-set mark, and Undo takes it off again. At a large and a
/// small (900×600) window.
final class MomentsLocationUITests: XCTestCase {
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
            attachment.name = "location-failure-line-\(line)-evidence"
            attachment.lifetime = .keepAlways
            issue.add(attachment)
        }
        super.record(issue)
    }

    func testSearchSetShowOnMapAndUndo() {
        setLocation(launch(), prefix: "location")
    }

    func testSearchSetShowOnMapAndUndoInASmallWindow() {
        setLocation(launch(smallWindow: true), prefix: "location-small")
    }

    private func setLocation(_ app: XCUIApplication, prefix: String) {
        let photo = element(app, "library.photo.demo-unlocated-1")
        XCTAssertTrue(photo.waitForExistence(timeout: timeout), "The photo without a location is not in the Library")
        photo.click()
        photo.rightClick()
        let menuItem = app.menuItems["Set Location…"].firstMatch
        XCTAssertTrue(menuItem.waitForExistence(timeout: timeout), "The context menu has no Set Location")
        menuItem.click()

        // Search a place name; nothing is set until the main button.
        let search = element(app, "location.search")
        XCTAssertTrue(search.waitForExistence(timeout: timeout), "Set Location did not open")
        let done = element(app, "location.done")
        XCTAssertTrue(done.exists)
        XCTAssertFalse(done.isEnabled, "Set Location is on before a place was chosen")
        let window = app.windows.firstMatch
        let sheet = app.sheets.firstMatch
        if sheet.exists {
            XCTAssertTrue(window.frame.insetBy(dx: -1, dy: -1).contains(sheet.frame), "The sheet spills outside the window (\(sheet.frame) in \(window.frame))")
        }
        capture(app, "\(prefix)-01-sheet-evidence")
        search.click()
        search.typeText("Harbour\r")
        let result = element(app, "location.result.0")
        XCTAssertTrue(result.waitForExistence(timeout: timeout), "The search showed no place")
        result.click()
        XCTAssertTrue(element(app, "location.pin").waitForExistence(timeout: timeout), "Choosing a place put no pin on the map")
        XCTAssertTrue(done.isEnabled, "Set Location stayed off with a pin on the map")
        capture(app, "\(prefix)-02-pin-evidence")
        done.click()
        XCTAssertTrue(done.waitForNonExistence(timeout: timeout), "The sheet did not close")
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: timeout), "A sheet is still open")
        XCTAssertTrue(element(app, "correction.bar").waitForExistence(timeout: timeout), "No Undo bar after setting the location")

        // The viewer marks it as set by hand; its small map opens the large
        // map at the photo.
        pauseLongerThanADoubleClick()
        photo.doubleClick()
        XCTAssertTrue(element(app, "viewer").waitForExistence(timeout: timeout))
        XCTAssertTrue(element(app, "viewer.location.manual").waitForExistence(timeout: timeout), "The viewer does not say the location was set by hand")
        let miniMap = element(app, "viewer.place.map")
        XCTAssertTrue(miniMap.waitForExistence(timeout: timeout), "The viewer shows no small map for the new location")
        capture(app, "\(prefix)-03-viewer-evidence")
        miniMap.click()
        let marker = element(app, "map.marker.demo-unlocated-1")
        XCTAssertTrue(marker.waitForExistence(timeout: timeout), "The photo is not on the map")
        let value = marker.value as? String ?? ""
        XCTAssertTrue(value.contains("Set by hand"), "The pin is not marked as set by hand (\(value))")
        capture(app, "\(prefix)-04-map-evidence")

        // Undo from the bar: the photo leaves the map.
        let undo = element(app, "correction.undo")
        if undo.waitForExistence(timeout: timeout) {
            undo.click()
        } else {
            app.typeKey("z", modifierFlags: .command)
        }
        XCTAssertTrue(marker.waitForNonExistence(timeout: timeout), "Undo left the photo on the map")
        capture(app, "\(prefix)-05-undone-evidence")
    }

    private func pauseLongerThanADoubleClick() {
        RunLoop.current.run(until: Date().addingTimeInterval(NSEvent.doubleClickInterval + 0.3))
    }

    private func launch(smallWindow: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-MomentsUITesting", "-MomentsUITestUnlocated", "-AppleLanguages", "(en)", "-AppleLocale", "en"]
        if smallWindow { app.launchArguments += ["-MomentsUITestSmallWindow"] }
        app.launch()
        app.activate()
        self.app = app
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: timeout), "Moments is not the frontmost app")
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: timeout), "Moments opened no window")
        XCTAssertTrue(window.isHittable, "The Moments window is covered or off screen")
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        XCTAssertEqual(app.state, .runningForeground, "Moments lost focus; stopping before clicking another app")
        return app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        // Capture only the app window, never the rest of the desktop.
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
