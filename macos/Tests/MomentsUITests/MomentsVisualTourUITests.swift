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
        app.launchArguments = ["-MomentsUITesting", "-MomentsUITestPeople", "-AppleLanguages", "(en)", "-AppleLocale", "en"]
        app.launch()
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: timeout))
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: timeout))

        let library = element(app, "sidebar.library")
        XCTAssertTrue(library.waitForExistence(timeout: timeout))
        _ = element(app, "library.people").waitForExistence(timeout: timeout)
        capture(app, "tour-01-library-evidence")

        // Focused text field: the ring should read as a deeper shadow, not a bright line.
        let photo = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.photo."))
            .firstMatch
        if photo.waitForExistence(timeout: timeout) {
            let photoID = String(photo.identifier.dropFirst("library.photo.".count))
            let note = element(app, "library.memory.\(photoID)")
            if note.waitForExistence(timeout: timeout) {
                note.click()
                note.typeText("Focus")
                capture(app, "tour-02-library-note-focused-evidence")
                app.typeKey(.escape, modifierFlags: [])
            }
        }

        // A face over the photos: that person's photos, in place.
        let person = element(app, "library.person.Alex")
        if person.waitForExistence(timeout: timeout) {
            person.click()
            if element(app, "library.scope").waitForExistence(timeout: timeout) {
                Thread.sleep(forTimeInterval: 0.8)
                capture(app, "tour-03-person-photos-evidence")
                // The small map over them opens the large one.
                let map = element(app, "library.scope.map")
                if map.waitForExistence(timeout: 3) {
                    map.click()
                    if element(app, "map.view").waitForExistence(timeout: timeout) {
                        Thread.sleep(forTimeInterval: 1.2)
                        capture(app, "tour-04-large-map-evidence")
                        element(app, "map.back").click()
                    }
                }
                let close = element(app, "library.scope.close")
                if close.waitForExistence(timeout: timeout) { close.click() }
            }
        }

        // The large viewer, with the photo's place, faces and small map.
        if photo.waitForExistence(timeout: timeout) {
            photo.doubleClick()
            if element(app, "viewer").waitForExistence(timeout: timeout) {
                Thread.sleep(forTimeInterval: 1.0)
                capture(app, "tour-05-viewer-evidence")
                app.typeKey(.escape, modifierFlags: [])
            }
        }

        let trips = element(app, "sidebar.trips")
        XCTAssertTrue(trips.waitForExistence(timeout: timeout), "Missing sidebar.trips")
        trips.click()
        Thread.sleep(forTimeInterval: 1.2)
        capture(app, "tour-06-chapters-evidence")
        let card = element(app, "trips.card.journeyA")
        if card.waitForExistence(timeout: timeout) {
            card.click()
            if element(app, "trips.back").waitForExistence(timeout: timeout) {
                Thread.sleep(forTimeInterval: 1.2)
                capture(app, "tour-07-chapter-evidence")
                element(app, "trips.back").click()
            }
        }

        // Settings: one page.
        app.typeKey(",", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 1.0)
        if app.windows.count > 1 {
            let attachment = XCTAttachment(screenshot: app.windows.element(boundBy: 0).screenshot())
            attachment.name = "tour-08-settings-evidence"
            attachment.lifetime = .keepAlways
            add(attachment)
            app.typeKey("w", modifierFlags: .command)
        }

        // Apple Photos import sheet last: it asks for Photos access, and the
        // system prompt covers everything after it.
        library.click()
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
