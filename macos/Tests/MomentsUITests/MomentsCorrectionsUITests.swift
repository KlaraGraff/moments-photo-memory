import AppKit
import XCTest

/// Correcting what the automatic organizing got wrong, at a large and a small
/// window: the date and time of several photos, place names and duplicate
/// places, and who a face is. Each change shows an Undo bar that works.
final class MomentsCorrectionsUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Stop at the first failure so a lost window never gets clicks.
        continueAfterFailure = false
    }

    private let timeout: TimeInterval = 12

    // MARK: Date and time

    func testAdjustTheDateOfSeveralPhotos() {
        adjustDates(launch(), prefix: "fix-date")
    }

    func testAdjustTheDateOfSeveralPhotosInASmallWindow() {
        adjustDates(launch(smallWindow: true), prefix: "fix-date-small")
    }

    private func adjustDates(_ app: XCUIApplication, prefix: String) {
        let photos = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.photo."))
        let first = photos.element(boundBy: 0)
        let second = photos.element(boundBy: 1)
        XCTAssertTrue(second.waitForExistence(timeout: timeout))
        first.click()
        XCUIElement.perform(withKeyModifiers: .command) { second.click() }
        XCTAssertEqual(second.value as? String, "Selected")

        first.rightClick()
        let adjust = app.menuItems["Adjust Date and Time of 2 Photos…"].firstMatch
        XCTAssertTrue(adjust.waitForExistence(timeout: timeout), "The context menu has no Adjust Date and Time for the selection")
        adjust.click()

        let done = element(in: app, identifier: "viewer.date.done")
        XCTAssertTrue(done.waitForExistence(timeout: timeout), "Adjust Date and Time did not open")
        XCTAssertTrue(app.staticTexts["Adjust date and time of 2 photos"].exists, "The sheet is not for both photos")
        capture(app, named: "\(prefix)-01-editor-evidence")

        // One hour (or minute) later for the earliest photo moves both.
        let time = element(in: app, identifier: "date.editor.time")
        XCTAssertTrue(time.waitForExistence(timeout: timeout))
        // Into the field's digits, clear of its "Time" label.
        time.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).click()
        app.typeKey(.upArrow, modifierFlags: [])
        XCTAssertTrue(element(in: app, identifier: "date.editor.shift").waitForExistence(timeout: timeout), "The sheet does not say how far the photos move")
        capture(app, named: "\(prefix)-02-shift-evidence")
        done.click()
        // The bar is up before the sheet has finished closing; the window
        // takes no clicks until it has.
        XCTAssertTrue(done.waitForNonExistence(timeout: timeout), "The date sheet did not close")
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: timeout), "A sheet is still open")

        let bar = element(in: app, identifier: "correction.bar")
        XCTAssertTrue(bar.waitForExistence(timeout: timeout), "No Undo bar after adjusting the date")
        capture(app, named: "\(prefix)-03-undo-bar-evidence")
        undoFromBar(app, bar: bar, prefix: prefix)
    }

    // MARK: Places

    func testRenameAndMergePlaces() {
        editPlaces(launch(), prefix: "fix-place")
    }

    func testRenameAndMergePlacesInASmallWindow() {
        editPlaces(launch(smallWindow: true), prefix: "fix-place-small")
    }

    /// A place is renamed where it shows: click its name under a photo, type
    /// over the name in the heading. A name another place already has joins
    /// the two places.
    private func editPlaces(_ app: XCUIApplication, prefix: String) {
        let place = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.place."))
            .firstMatch
        XCTAssertTrue(place.waitForExistence(timeout: timeout), "No place under a photo")
        place.click()
        let field = app.textFields["library.scope.place"]
        XCTAssertTrue(field.waitForExistence(timeout: timeout), "The place's heading has no name field")
        let original = field.value as? String ?? ""
        XCTAssertFalse(original.isEmpty, "The place's heading shows no name")
        let count = photoCount(app)
        XCTAssertGreaterThan(count, 0)
        capture(app, named: "\(prefix)-01-place-evidence")

        // Rename, then take it back from the bar.
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("Harbour\r")
        let bar = element(in: app, identifier: "correction.bar")
        XCTAssertTrue(bar.waitForExistence(timeout: timeout), "No Undo bar after renaming the place")
        let renamed = NSPredicate(format: "value == %@", "Harbour")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: renamed, evaluatedWith: field)], timeout: timeout), .completed, "The rename did not apply")
        XCTAssertEqual(photoCount(app), count, "Renaming a place changed which photos are there")
        capture(app, named: "\(prefix)-02-renamed-evidence")
        undoFromBar(app, bar: bar, prefix: prefix)
        let restored = NSPredicate(format: "value == %@", original)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: restored, evaluatedWith: field)], timeout: timeout), .completed, "Undo did not bring the old name back")

        // Two places that are really one: give this one the other's name.
        let other = original == "Demo place 1" ? "Demo place 2" : "Demo place 1"
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(other + "\r")
        XCTAssertTrue(bar.waitForExistence(timeout: timeout), "No Undo bar after joining two places")
        let joined = NSPredicate(format: "value == %@", other)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: joined, evaluatedWith: field)], timeout: timeout), .completed, "The second rename did not apply")
        XCTAssertGreaterThan(photoCount(app), count, "The same name did not join the two places")
        capture(app, named: "\(prefix)-03-joined-evidence")
        undoFromBar(app, bar: bar, prefix: prefix)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: restored, evaluatedWith: field)], timeout: timeout), .completed, "Undo did not separate the two places")
        XCTAssertEqual(photoCount(app), count)
        element(in: app, identifier: "window.back").click()
    }

    private func photoCount(_ app: XCUIApplication) -> Int {
        let count = element(in: app, identifier: "library.photoCount")
        XCTAssertTrue(count.waitForExistence(timeout: timeout))
        // Let a regroup after a scope change publish its count.
        Thread.sleep(forTimeInterval: 0.5)
        return Int(count.value as? String ?? "") ?? -1
    }

    // MARK: People

    func testAFaceLeadsToItsPhotosAndTheViewerListsTheFace() {
        followAFace(launch(people: true), prefix: "fix-face")
    }

    func testAFaceLeadsToItsPhotosAndTheViewerListsTheFaceInASmallWindow() {
        followAFace(launch(smallWindow: true, people: true), prefix: "fix-face-small")
    }

    private func followAFace(_ app: XCUIApplication, prefix: String) {
        // The row of faces over the photos: Sam's face shows Sam's photos.
        let sam = element(in: app, identifier: "library.person.Sam")
        XCTAssertTrue(sam.waitForExistence(timeout: timeout), "The seeded person is not in the row of faces")
        capture(app, named: "\(prefix)-01-faces-evidence")
        sam.click()
        XCTAssertTrue(element(in: app, identifier: "library.scope").waitForExistence(timeout: timeout), "The face did not show Sam's photos")

        // In the large viewer the face is listed with its person's name, as
        // the menu that says "This isn't Sam, it's…". (The column's scroll
        // view stands in for its controls, so the menu is not clicked here;
        // moving a face is covered by the unit tests.)
        // The seeded Sam face is on the third demo photo.
        let photo = element(in: app, identifier: "library.photo.D0003")
        XCTAssertTrue(photo.waitForExistence(timeout: timeout))
        photo.doubleClick()
        XCTAssertTrue(element(in: app, identifier: "viewer").waitForExistence(timeout: timeout), "Double click did not open the photo")
        XCTAssertTrue(element(in: app, identifier: "viewer.face.demo-face-3").waitForExistence(timeout: timeout), "The viewer does not list who is in the photo")
        capture(app, named: "\(prefix)-02-viewer-evidence")
        app.typeKey(.escape, modifierFlags: [])
        element(in: app, identifier: "window.back").click()
    }

    // MARK: Helpers

    /// Undo from the bar at the bottom of the window; the bar goes away.
    private func undoFromBar(_ app: XCUIApplication, bar: XCUIElement, prefix: String) {
        let undo = element(in: app, identifier: "correction.undo")
        XCTAssertTrue(undo.waitForExistence(timeout: timeout), "The bar has no Undo button")
        let before = "undo \(undo.frame) hittable \(undo.isHittable), bar \(bar.frame), window \(app.windows.firstMatch.frame)"
        let focused = app.debugDescription.split(separator: "\n").filter { $0.contains("Keyboard Focused") && !$0.contains("Cell,") }
        let windows = app.windows.allElementsBoundByIndex.map { "\($0.identifier)|\($0.title)|\($0.frame)" }
            + app.sheets.allElementsBoundByIndex.map { "sheet \($0.frame)" }
            + app.popovers.allElementsBoundByIndex.map { "popover \($0.frame)" }
            + app.dialogs.allElementsBoundByIndex.map { "dialog \($0.frame)" }
        undo.click()
        let closed = bar.waitForNonExistence(timeout: timeout)
        var after = ""
        if !closed {
            capture(app, named: "\(prefix)-undo-still-open-evidence")
            // What would have worked, to tell a lost first click from a dead button.
            undo.click()
            after += bar.waitForNonExistence(timeout: 3) ? "a second click closed it" : "a second click did not close it"
            if bar.exists {
                app.typeKey("z", modifierFlags: .command)
                after += bar.waitForNonExistence(timeout: 3) ? "; Command-Z closed it" : "; Command-Z did not close it"
            }
        }
        XCTAssertTrue(closed, "Undo did not close the bar (\(before), focused \(focused), windows \(windows)); \(after): \(bar.debugDescription)")
    }

    private func launch(smallWindow: Bool = false, people: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-MomentsUITesting", "-AppleLanguages", "(en)", "-AppleLocale", "en"]
        if smallWindow { app.launchArguments += ["-MomentsUITestSmallWindow"] }
        if people { app.launchArguments += ["-MomentsUITestPeople"] }
        app.launch()
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: timeout), "Moments is not the frontmost app")
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: timeout), "Moments opened no window")
        XCTAssertTrue(window.isHittable, "The Moments window is covered or off screen")
        return app
    }

    private func element(in app: XCUIApplication, identifier: String) -> XCUIElement {
        XCTAssertEqual(app.state, .runningForeground, "Moments lost focus; stopping before clicking another app")
        return app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func capture(_ app: XCUIApplication, named name: String) {
        // Capture only the app window, never the rest of the desktop.
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
