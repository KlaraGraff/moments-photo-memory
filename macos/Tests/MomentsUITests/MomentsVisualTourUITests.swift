import AppKit
import XCTest

/// Visits every screen and sheet once and keeps a screenshot of each, so a
/// visual change can be checked on the hosted Mac without a person's screen.
final class MomentsVisualTourUITests: XCTestCase {
    private let timeout: TimeInterval = 12

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testVisualTourEnglish() {
        let app = XCUIApplication()
        app.launchArguments = ["-MomentsUITesting", "-AppleLanguages", "(en)", "-AppleLocale", "en"]
        app.launch()
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: timeout))
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: timeout))

        let library = element(app, "sidebar.library")
        XCTAssertTrue(library.waitForExistence(timeout: timeout))
        capture(app, "tour-01-library-evidence")

        // Focused text field: the ring should read as a deeper shadow, not a bright line.
        let photo = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.photo."))
            .firstMatch
        if photo.waitForExistence(timeout: timeout) {
            let photoID = String(photo.identifier.dropFirst("library.photo.".count))
            let note = element(app, "library.note.\(photoID)")
            if note.waitForExistence(timeout: timeout) {
                note.click()
                note.typeText("Focus")
                capture(app, "tour-02-library-note-focused-evidence")
                app.typeKey(.escape, modifierFlags: [])
            }
        }

        // The smart group sheet from the screenshot report. Its button only
        // shows while a filter is on.
        let photosOnly = app.radioButtons["Photos"].firstMatch
        XCTAssertTrue(photosOnly.waitForExistence(timeout: timeout))
        photosOnly.click()
        let save = element(app, "library.save-smart-group")
        XCTAssertTrue(save.waitForExistence(timeout: timeout))
        save.click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: timeout))
        Thread.sleep(forTimeInterval: 0.6)
        capture(app, "tour-03-smart-group-sheet-evidence")
        // Two conditions show whether rows and the label column line up.
        let addCondition = element(app, "groupEditor.addCondition")
        if addCondition.waitForExistence(timeout: timeout) {
            addCondition.click()
            addCondition.click()
            Thread.sleep(forTimeInterval: 0.6)
            capture(app, "tour-03b-smart-group-conditions-evidence")
        }
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: timeout))
        app.radioButtons["All"].firstMatch.click()

        // A manual group from the sidebar menu.
        let newGroup = element(app, "sidebar.new-group")
        XCTAssertTrue(newGroup.waitForExistence(timeout: timeout))
        newGroup.click()
        let manual = app.menuItems["New manual group"]
        if manual.waitForExistence(timeout: timeout) {
            manual.click()
            XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: timeout))
            Thread.sleep(forTimeInterval: 0.6)
            capture(app, "tour-04-manual-group-sheet-evidence")
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: timeout))
        }

        for (index, step) in [
            ("sidebar.review", "review"),
            ("sidebar.people", "people"),
            ("sidebar.places", "places"),
            ("sidebar.footprints", "footprints"),
            ("sidebar.timeline", "timeline"),
        ].enumerated() {
            let item = element(app, step.0)
            XCTAssertTrue(item.waitForExistence(timeout: timeout), "Missing \(step.0)")
            item.click()
            Thread.sleep(forTimeInterval: 1.2)
            capture(app, "tour-\(String(format: "%02d", index + 5))-\(step.1)-evidence")
        }

        // Settings window.
        app.typeKey(",", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 1.0)
        let settings = app.windows.element(boundBy: 0)
        if settings.exists, app.windows.count > 1 {
            let attachment = XCTAttachment(screenshot: settings.screenshot())
            attachment.name = "tour-11-settings-evidence"
            attachment.lifetime = .keepAlways
            add(attachment)
            app.typeKey("w", modifierFlags: .command)
        }

        // Apple Photos import sheet last: it asks for Photos access, and the
        // system prompt covers everything after it.
        app.typeKey("p", modifierFlags: [.command, .shift])
        if app.sheets.firstMatch.waitForExistence(timeout: timeout) {
            Thread.sleep(forTimeInterval: 0.6)
            capture(app, "tour-10-photos-import-sheet-evidence")
            app.typeKey(.escape, modifierFlags: [])
        }
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        XCTAssertEqual(app.state, .runningForeground, "Moments lost focus; stopping before clicking another app")
        return app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
