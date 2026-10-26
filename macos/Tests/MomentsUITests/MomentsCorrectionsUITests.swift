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

    private func editPlaces(_ app: XCUIApplication, prefix: String) {
        openPlacesEditor(app)
        capture(app, named: "\(prefix)-01-editor-evidence")

        // Two places that are really one: tick both and keep one name.
        let one = element(in: app, identifier: "places.editor.check.demo place 1")
        let two = element(in: app, identifier: "places.editor.check.demo place 2")
        XCTAssertTrue(two.waitForExistence(timeout: timeout))
        one.click()
        two.click()
        let merge = element(in: app, identifier: "places.editor.merge")
        XCTAssertTrue(merge.waitForExistence(timeout: timeout), "No Merge button for two ticked places")
        merge.click()
        let keep = app.menuItems["Demo place 1"].firstMatch
        XCTAssertTrue(keep.waitForExistence(timeout: timeout))
        keep.click()
        XCTAssertTrue(element(in: app, identifier: "places.editor.row.demo place 2").waitForNonExistence(timeout: timeout), "The merged place is still listed")
        capture(app, named: "\(prefix)-02-merged-evidence")

        // Rename a place, then take it back from the sheet.
        element(in: app, identifier: "places.editor.rename.demo place 3").click()
        let field = element(in: app, identifier: "places.editor.name-field")
        XCTAssertTrue(field.waitForExistence(timeout: timeout))
        field.typeKey("a", modifierFlags: .command)
        field.typeText("Harbour\r")
        XCTAssertTrue(element(in: app, identifier: "places.editor.row.harbour").waitForExistence(timeout: timeout), "The rename did not apply")
        capture(app, named: "\(prefix)-03-renamed-evidence")
        element(in: app, identifier: "places.editor.undo").click()
        XCTAssertTrue(element(in: app, identifier: "places.editor.row.demo place 3").waitForExistence(timeout: timeout), "Undo did not bring the old name back")
        element(in: app, identifier: "places.editor.done").click()

        // The Map's filter lists the merged place once.
        element(in: app, identifier: "sidebar.map").click()
        let filterButton = element(in: app, identifier: "toolbar.filter")
        XCTAssertTrue(filterButton.waitForExistence(timeout: 30), "The Map has no Filter button")
        filterButton.click()
        let popover = app.popovers.firstMatch
        XCTAssertTrue(popover.waitForExistence(timeout: timeout), "Filter did not open its options")
        let place = popover.descendants(matching: .any).matching(identifier: "filter.place").firstMatch
        XCTAssertTrue(place.waitForExistence(timeout: timeout), "The Map's filters have no Place filter: \(popover.debugDescription)")
        place.click()
        let merged = app.menuItems["Demo place 1"].firstMatch
        XCTAssertTrue(merged.waitForExistence(timeout: timeout), "The Map's Place filter does not list the merged place: \(app.menus.firstMatch.debugDescription)")
        XCTAssertFalse(app.menuItems["Demo place 2"].exists, "The Map still lists the merged place")
        merged.click()
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 1.5)
        capture(app, named: "\(prefix)-04-map-evidence")

        // Filters are saved settings: leave none behind for the next test.
        filterButton.click()
        XCTAssertTrue(place.waitForExistence(timeout: timeout))
        place.click()
        app.menuItems["All places"].firstMatch.click()
        app.typeKey(.escape, modifierFlags: [])
    }

    private func openPlacesEditor(_ app: XCUIApplication) {
        let place = element(in: app, identifier: "filter.place")
        XCTAssertTrue(place.waitForExistence(timeout: timeout), "The Library has no Place filter")
        place.click()
        let edit = app.menuItems["Rename or Merge Places…"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: timeout), "The Place filter has no Rename or Merge Places")
        edit.click()
        XCTAssertTrue(element(in: app, identifier: "places.editor.done").waitForExistence(timeout: timeout), "The places sheet did not open")
    }

    // MARK: People

    func testThisIsntAlexItsSam() {
        moveFaces(launch(people: true), prefix: "fix-face")
    }

    func testThisIsntAlexItsSamInASmallWindow() {
        moveFaces(launch(smallWindow: true, people: true), prefix: "fix-face-small")
    }

    private func moveFaces(_ app: XCUIApplication, prefix: String) {
        element(in: app, identifier: "sidebar.people").click()
        let face = element(in: app, identifier: "people.face.demo-face-1")
        XCTAssertTrue(face.waitForExistence(timeout: timeout), "The seeded face is not on the People screen")
        capture(app, named: "\(prefix)-01-people-evidence")

        face.rightClick()
        let sam = app.menuItems["Sam"].firstMatch
        XCTAssertTrue(sam.waitForExistence(timeout: timeout), "The face has no “This isn’t Alex, it’s…” menu")
        sam.click()
        let bar = element(in: app, identifier: "correction.bar")
        XCTAssertTrue(bar.waitForExistence(timeout: timeout), "No Undo bar after moving the face")
        capture(app, named: "\(prefix)-02-moved-evidence")
        undoFromBar(app, bar: bar, prefix: prefix)
        XCTAssertTrue(face.waitForExistence(timeout: timeout), "Undo did not bring the face back to Alex")

        // In the large viewer: Sam's photo, "This isn't Sam, it's… Alex".
        element(in: app, identifier: "people.person.demo-person-sam").click()
        // The seeded Sam face is on the third demo photo.
        let photo = element(in: app, identifier: "library.photo.D0003")
        XCTAssertTrue(photo.waitForExistence(timeout: timeout))
        photo.doubleClick()
        XCTAssertTrue(element(in: app, identifier: "viewer").waitForExistence(timeout: timeout), "Double click did not open the photo")
        let who = app.menuButtons["Sam"].firstMatch
        XCTAssertTrue(who.waitForExistence(timeout: timeout), "The viewer does not show who is in the photo")
        who.click()
        let alex = app.menuItems["Alex"].firstMatch
        XCTAssertTrue(alex.waitForExistence(timeout: timeout))
        alex.click()
        XCTAssertTrue(app.menuButtons["Alex"].firstMatch.waitForExistence(timeout: timeout), "The face did not move to Alex")
        capture(app, named: "\(prefix)-03-viewer-evidence")

        // Filters are saved settings: leave none behind for the next test.
        app.typeKey(.escape, modifierFlags: [])
        let chip = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Person:")).firstMatch
        if chip.waitForExistence(timeout: timeout) { chip.click() }
    }

    // MARK: Helpers

    /// Undo from the bar at the bottom of the window; the bar goes away.
    private func undoFromBar(_ app: XCUIApplication, bar: XCUIElement, prefix: String) {
        let undo = element(in: app, identifier: "correction.undo")
        XCTAssertTrue(undo.waitForExistence(timeout: timeout), "The bar has no Undo button")
        let before = "undo \(undo.frame) hittable \(undo.isHittable), bar \(bar.frame), window \(app.windows.firstMatch.frame)"
        undo.click()
        let closed = bar.waitForNonExistence(timeout: timeout)
        if !closed { capture(app, named: "\(prefix)-undo-still-open-evidence") }
        XCTAssertTrue(closed, "Undo did not close the bar (\(before)): \(bar.debugDescription)")
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
