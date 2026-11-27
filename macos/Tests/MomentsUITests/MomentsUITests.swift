import AppKit
import XCTest

final class MomentsUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Stop at the first failure: a test must never keep clicking once Moments
        // is not the frontmost app, or its clicks land in other apps.
        continueAfterFailure = false
    }

    private let launchTimeout: TimeInterval = 12

    func testNavigationScreenshotsEnglish() {
        let app = launch(language: "en")
        navigateAndCapture(app, prefix: "en", settleMap: true)
    }

    func testNavigationScreenshotsChinese() {
        let app = launch(language: "zh-Hans")
        navigateAndCapture(app, prefix: "zh-Hans", settleMap: true)
    }

    func testNavigationScreenshotsGermanDarkSmallWindow() {
        let app = launch(language: "de", darkMode: true, smallWindow: true)
        // The app is light only: with the Mac in Dark Mode the window must still
        // render the light paper palette, not light text on a light background.
        assertWindowRendersLight(app)
        navigateAndCapture(app, prefix: "de-dark-small", settleMap: true)
    }

    func testMemoryIsSavedWhenLeavingTheField() {
        let app = launch(language: "en")
        let library = element(in: app, identifier: "sidebar.library")
        XCTAssertTrue(library.waitForExistence(timeout: launchTimeout))

        // Sections run newest first, so use the first visible demo photo.
        let photo = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.photo."))
            .firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: launchTimeout))
        let photoID = String(photo.identifier.dropFirst("library.photo.".count))
        photo.click()

        // The ruled line under each photo is your memory. Like a caption in
        // Photos, leaving the field (here: clicking the sidebar) keeps it.
        let memory = element(in: app, identifier: "library.memory.\(photoID)")
        XCTAssertTrue(memory.waitForExistence(timeout: launchTimeout))
        let text = "UI smoke memory \(UUID().uuidString)"
        memory.click()
        memory.typeText(text)
        capture(app, named: "memory-01-typed-evidence")
        XCTAssertTrue((memory.value as? String ?? "").contains(text), "The typed words are not in the field: \(String(describing: memory.value))")

        for destination in ["sidebar.trips", "sidebar.library"] {
            let item = element(in: app, identifier: destination)
            XCTAssertTrue(item.waitForExistence(timeout: launchTimeout), "Missing sidebar item \(destination)")
            item.click()
            if destination == "sidebar.trips" { capture(app, named: "memory-02-left-evidence") }
        }

        XCTAssertTrue(memory.waitForExistence(timeout: launchTimeout))
        capture(app, named: "memory-03-back-evidence")
        XCTAssertTrue((memory.value as? String ?? "").contains(text), "Leaving the field did not keep the memory: \(String(describing: memory.value))")
        capture(app, named: "library-02-memory-persisted")
    }

    func testReturnSavesTheWordsAsTheMemoryUnderThePhoto() {
        let app = launch(language: "en")
        let photo = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.photo."))
            .firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: launchTimeout))
        let photoID = String(photo.identifier.dropFirst("library.photo.".count))

        let memory = element(in: app, identifier: "library.memory.\(photoID)")
        XCTAssertTrue(memory.waitForExistence(timeout: launchTimeout))
        memory.click()
        memory.typeText("Synthetic memory about this spot\r")

        // Return ends typing; the words stay right there as the memory, with
        // no AI step in between (UI tests hand nothing to a model).
        XCTAssertTrue((memory.value as? String ?? "").contains("Synthetic memory about this spot"), "Return did not keep the words under the photo")

        // The viewer's column shows the same memory.
        photo.doubleClick()
        let viewer = element(in: app, identifier: "viewer")
        XCTAssertTrue(viewer.waitForExistence(timeout: launchTimeout))
        let inViewer = viewer.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND value CONTAINS %@", "library.memory.\(photoID)", "Synthetic memory about this spot"))
            .firstMatch
        XCTAssertTrue(inViewer.waitForExistence(timeout: launchTimeout), "The viewer did not show the memory")
        capture(app, named: "library-03-memory-saved")
    }

    func testClickSelectsSecondClickDeselectsDoubleClickOpensTheViewer() {
        let app = launch(language: "en")
        let photos = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.photo."))
        let first = photos.element(boundBy: 0)
        let second = photos.element(boundBy: 1)
        XCTAssertTrue(second.waitForExistence(timeout: launchTimeout))

        // One click selects, a second (separate) click deselects.
        first.click()
        XCTAssertEqual(first.value as? String, "Selected")
        pauseLongerThanADoubleClick()
        first.click()
        XCTAssertEqual(first.value as? String, "Not selected", "A second click did not deselect the photo")

        // Command-click adds, Esc clears.
        pauseLongerThanADoubleClick()
        first.click()
        XCUIElement.perform(withKeyModifiers: .command) { second.click() }
        XCTAssertEqual(first.value as? String, "Selected")
        XCTAssertEqual(second.value as? String, "Selected")
        capture(app, named: "grid-01-two-selected-evidence")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(first.value as? String, "Not selected", "Esc did not clear the selection")
        XCTAssertEqual(second.value as? String, "Not selected")

        // Double click opens the large viewer; the right arrow pages, Esc closes.
        pauseLongerThanADoubleClick()
        first.doubleClick()
        let viewer = element(in: app, identifier: "viewer")
        XCTAssertTrue(viewer.waitForExistence(timeout: launchTimeout), "Double click did not open the photo")
        let counter = element(in: app, identifier: "viewer.counter")
        XCTAssertTrue(counter.waitForExistence(timeout: launchTimeout))
        let start = counter.value as? String
        capture(app, named: "grid-02-viewer-evidence")
        app.typeKey(.rightArrow, modifierFlags: [])
        let paged = NSPredicate(format: "value != %@", start ?? "")
        expectation(for: paged, evaluatedWith: counter)
        waitForExpectations(timeout: launchTimeout)
        capture(app, named: "grid-02b-viewer-paged-evidence")

        // ⌘= and the scroll wheel zoom in; a double click fits the photo again.
        let image = element(in: app, identifier: "viewer.image")
        XCTAssertEqual(image.value as? String, "100%")
        // The photo sits under the hover paging buttons' row, so point at it
        // by coordinate instead of asking for the element's hit point.
        let photoCentre = image.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let zoomed = NSPredicate(format: "value != %@", "100%")
        let fitted = NSPredicate(format: "value == %@", "100%")
        app.typeKey("=", modifierFlags: .command)
        expectation(for: zoomed, evaluatedWith: image)
        waitForExpectations(timeout: launchTimeout)
        photoCentre.doubleClick()
        expectation(for: fitted, evaluatedWith: image)
        waitForExpectations(timeout: launchTimeout)
        XCUIElement.perform(withKeyModifiers: .command) { photoCentre.scroll(byDeltaX: 0, deltaY: 8) }
        expectation(for: zoomed, evaluatedWith: image)
        waitForExpectations(timeout: launchTimeout)
        capture(app, named: "grid-02c-viewer-zoomed-evidence")
        pauseLongerThanADoubleClick()
        photoCentre.doubleClick()
        expectation(for: fitted, evaluatedWith: image)
        waitForExpectations(timeout: launchTimeout)

        // Over the photo, the scroll wheel turns to another photo.
        let beforeWheel = counter.value as? String
        pauseLongerThanADoubleClick()
        photoCentre.scroll(byDeltaX: 0, deltaY: -3)
        expectation(for: NSPredicate(format: "value != %@", beforeWheel ?? ""), evaluatedWith: counter)
        waitForExpectations(timeout: launchTimeout)

        // The column edits in place: type over the place, adjust the date.
        // By type: the column's scroll view also answers to its children's identifiers.
        let place = app.textFields["viewer.place"]
        XCTAssertTrue(place.waitForExistence(timeout: launchTimeout))
        // SwiftUI reports the field with its scroll view's frame, which has no
        // hit point; click the place line by its position under the date.
        let date = app.buttons["viewer.date"]
        // Its frame may be reported as the column's; 30 pt down is on the date either way.
        let dateTitle = date.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)).withOffset(CGVector(dx: 40, dy: 30))
        date.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 1)).withOffset(CGVector(dx: 30, dy: 47)).click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText("Harbour cafe\r")
        capture(app, named: "grid-02c2-viewer-place-typed-evidence")
        // The corrected place shows what it was found as.
        let corrected = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", "Corrected, was", "Corrected, was")).firstMatch
        XCTAssertTrue(corrected.waitForExistence(timeout: launchTimeout), "Typing over the place did not correct it")
        dateTitle.click()
        let dateDone = app.buttons["viewer.date.done"]
        XCTAssertTrue(dateDone.waitForExistence(timeout: launchTimeout), "Clicking the date did not open the date editor")
        capture(app, named: "grid-02d-viewer-date-evidence")
        dateDone.click()
        capture(app, named: "grid-02e-viewer-edited-evidence")
        app.typeKey(.escape, modifierFlags: [])
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: viewer)
        waitForExpectations(timeout: launchTimeout)

        // Back in the grid, Space opens the selected photo again.
        app.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(viewer.waitForExistence(timeout: launchTimeout), "Space did not open the selected photo")
        app.typeKey(" ", modifierFlags: [])
        expectation(for: gone, evaluatedWith: viewer)
        waitForExpectations(timeout: launchTimeout)

        // ⌘− twice: the dense grid has photos only, no memory lines.
        let photoID = String(first.identifier.dropFirst("library.photo.".count))
        let note = element(in: app, identifier: "library.memory.\(photoID)")
        XCTAssertTrue(note.exists)
        app.typeKey("-", modifierFlags: .command)
        app.typeKey("-", modifierFlags: .command)
        let noteGone = NSPredicate(format: "exists == false")
        expectation(for: noteGone, evaluatedWith: note)
        waitForExpectations(timeout: launchTimeout)
        capture(app, named: "grid-03-compact-evidence")
        app.typeKey("=", modifierFlags: .command)
        app.typeKey("=", modifierFlags: .command)
        XCTAssertTrue(note.waitForExistence(timeout: launchTimeout), "⌘+ did not bring the print size back")
    }

    /// The viewer at the smallest window size: photo, column and header must not overlap.
    func testViewerFitsTheSmallWindow() {
        let app = launch(language: "en", smallWindow: true)
        let first = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.photo.")).element(boundBy: 0)
        XCTAssertTrue(first.waitForExistence(timeout: launchTimeout))
        first.doubleClick()
        let viewer = element(in: app, identifier: "viewer")
        XCTAssertTrue(viewer.waitForExistence(timeout: launchTimeout))
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(window.contains(viewer.frame), "The viewer card spills outside the window")
        let close = element(in: app, identifier: "viewer.close")
        let date = app.buttons["viewer.date"]
        XCTAssertTrue(date.waitForExistence(timeout: launchTimeout))
        XCTAssertFalse(close.frame.intersects(date.frame), "The header overlaps the info column")
        capture(app, named: "grid-04-viewer-small-window-evidence")
    }

    /// Two clicks closer together than the double-click interval are a double click.
    private func pauseLongerThanADoubleClick() {
        RunLoop.current.run(until: Date().addingTimeInterval(NSEvent.doubleClickInterval + 0.3))
    }

    /// Opens the large map of every photo the way a person does: Chapters,
    /// then the small map over the cards. The click lands on the small map's
    /// margin, clear of the stamps (a stamp opens its chapter instead).
    @discardableResult
    private func openLargeMap(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        element(in: app, identifier: "sidebar.trips").click()
        let footprints = element(in: app, identifier: "trips.footprints")
        XCTAssertTrue(footprints.waitForExistence(timeout: launchTimeout), "Chapters has no small map over the cards", file: file, line: line)
        footprints.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.92)).click()
        let map = element(in: app, identifier: "map.view")
        XCTAssertTrue(map.waitForExistence(timeout: 30), "The small map did not open the large map", file: file, line: line)
        return map
    }

    /// Opens the large map and zooms from the globe to the photos.
    private func openMapAtPhotos(_ app: XCUIApplication) -> XCUIElement {
        let map = openLargeMap(app)
        let fit = element(in: app, identifier: "map.fit")
        XCTAssertTrue(fit.waitForExistence(timeout: launchTimeout))
        // The fitted region needs the clustered snapshot; give it a moment.
        Thread.sleep(forTimeInterval: 1.0)
        fit.click()
        Thread.sleep(forTimeInterval: 2.0)
        return map
    }

    /// Section titles, the time and the place under a photo look like
    /// information; clicking them must do something.
    func testInfoUnderPhotosIsClickable() {
        exerciseInfoClicks(launch(language: "en"), prefix: "info")
    }

    func testInfoUnderPhotosIsClickableInASmallWindow() {
        exerciseInfoClicks(launch(language: "en", smallWindow: true), prefix: "info-small")
    }

    private func exerciseInfoClicks(_ app: XCUIApplication, prefix: String) {
        let anyID = { (prefix: String) in
            app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
        }
        let firstPhoto = anyID("library.photo.")
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: launchTimeout))

        // A section title selects its photos.
        let section = anyID("library.section.")
        XCTAssertTrue(section.waitForExistence(timeout: launchTimeout), "Library section title is not a control")
        section.click()
        // A trip title waits out the double-click interval (double-click renames).
        let selected = NSPredicate(format: "value == %@", "Selected")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: selected, evaluatedWith: firstPhoto)], timeout: 5), .completed, "Clicking the section title did not select its photos")
        app.typeKey(.escape, modifierFlags: [])

        // The time under a photo opens the date editor.
        let time = anyID("library.time.")
        XCTAssertTrue(time.waitForExistence(timeout: launchTimeout), "The time under a photo is not a control")
        time.click()
        let done = element(in: app, identifier: "viewer.date.done")
        XCTAssertTrue(done.waitForExistence(timeout: launchTimeout), "Clicking the time did not open the date editor")
        capture(app, named: "\(prefix)-01-date-editor-evidence")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(done.waitForNonExistence(timeout: launchTimeout))

        // The place under a photo shows the photos taken there, right in
        // the Library, with a heading that leads back to every photo.
        let allCount = libraryPhotoCount(app)
        let place = anyID("library.place.")
        XCTAssertTrue(place.waitForExistence(timeout: launchTimeout), "The place under a photo is not a control")
        place.click()
        let heading = element(in: app, identifier: "library.scope")
        XCTAssertTrue(heading.waitForExistence(timeout: launchTimeout), "Clicking the place did not show its photos")
        let placeCount = libraryPhotoCount(app)
        XCTAssertGreaterThan(placeCount, 0)
        XCTAssertLessThan(placeCount, allCount, "Only the place's photos should be listed")
        capture(app, named: "\(prefix)-02-place-photos-evidence")

        // The heading's small map opens the large map with those photos; Back returns.
        let smallMap = element(in: app, identifier: "library.scope.map")
        XCTAssertTrue(smallMap.waitForExistence(timeout: launchTimeout), "The place's heading has no small map")
        smallMap.click()
        XCTAssertTrue(element(in: app, identifier: "map.view").waitForExistence(timeout: 30), "The small map did not open the large map")
        Thread.sleep(forTimeInterval: 1.5)
        capture(app, named: "\(prefix)-03-place-on-map-evidence")
        let back = element(in: app, identifier: "window.back")
        XCTAssertTrue(back.waitForExistence(timeout: launchTimeout), "The large map has no Back")
        back.click()
        XCTAssertTrue(heading.waitForExistence(timeout: launchTimeout), "Back did not return to the place's photos")

        let close = element(in: app, identifier: "window.back")
        close.click()
        XCTAssertTrue(heading.waitForNonExistence(timeout: launchTimeout), "All photos did not leave the place")
        XCTAssertEqual(libraryPhotoCount(app), allCount)
    }

    /// A place's photos go back to all photos with the window's back button
    /// (an arrow, not a cross) and with Command-[, and all photos come back
    /// at the section that was at the top, not at the top of the Library.
    func testBackFromAPlacesPhotosReturnsWhereAllPhotosWereLeft() {
        let app = launch(language: "en")
        let allCount = libraryPhotoCount(app)
        let sections = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT (identifier BEGINSWITH %@)", "library.section.", "library.section.person."))
        XCTAssertTrue(sections.firstMatch.waitForExistence(timeout: launchTimeout))
        let firstSectionID: String = sections.firstMatch.identifier
        let topSection = element(in: app, identifier: "library.topSection")
        XCTAssertTrue(topSection.waitForExistence(timeout: launchTimeout))
        // Scroll until a later section is at the top.
        var leftAt: String = ""
        for _ in 0..<8 {
            sections.firstMatch.scroll(byDeltaX: 0, deltaY: -800)
            Thread.sleep(forTimeInterval: 0.8)
            leftAt = topSection.value as? String ?? ""
            if !leftAt.isEmpty, leftAt != "section:" + firstSectionID.dropFirst("library.section.".count) { break }
        }
        let leftSectionID: String = String(leftAt.dropFirst("section:".count))
        XCTAssertFalse(leftSectionID.isEmpty, "No section reached the top while scrolling")
        XCTAssertNotEqual("library.section." + leftSectionID, firstSectionID, "Scrolling never left the first section")

        let places = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.place."))
        let place: XCUIElement? = places.allElementsBoundByIndex.first { (place: XCUIElement) -> Bool in place.isHittable }
        guard let place else {
            XCTFail("No place under a photo is in view after scrolling")
            return
        }
        place.click()
        let heading = element(in: app, identifier: "library.scope")
        XCTAssertTrue(heading.waitForExistence(timeout: launchTimeout), "Clicking the place did not show its photos")
        let back = element(in: app, identifier: "window.back")
        XCTAssertTrue(back.waitForExistence(timeout: launchTimeout), "A place's photos have no way back")
        let backInHeading: Bool = heading.descendants(matching: .any).matching(identifier: "window.back").count > 0
        XCTAssertFalse(backInHeading, "The way back should be the window's back button, not a cross in the heading")
        capture(app, named: "scope-back-01-place-evidence")

        back.click()
        XCTAssertTrue(heading.waitForNonExistence(timeout: launchTimeout), "Back did not leave the place")
        XCTAssertEqual(libraryPhotoCount(app), allCount)
        let returned = element(in: app, identifier: "library.section." + leftSectionID)
        XCTAssertTrue(returned.waitForExistence(timeout: launchTimeout), "The section that was at the top is gone")
        Thread.sleep(forTimeInterval: 0.5)
        capture(app, named: "scope-back-02-returned-evidence")
        XCTAssertTrue(returned.isHittable, "All photos did not come back at the section that was at the top (top is now \(topSection.value ?? "nil"))")

        // Command-[ goes back too, as on Chapters and the Map.
        let placeAgain: XCUIElement? = places.allElementsBoundByIndex.first { (place: XCUIElement) -> Bool in place.isHittable }
        guard let placeAgain else {
            XCTFail("No place under a photo is in view after going back")
            return
        }
        placeAgain.click()
        XCTAssertTrue(heading.waitForExistence(timeout: launchTimeout))
        app.typeKey("[", modifierFlags: .command)
        XCTAssertTrue(heading.waitForNonExistence(timeout: launchTimeout), "Command-[ did not go back to all photos")
        XCTAssertEqual(libraryPhotoCount(app), allCount)
    }

    /// People are a row of faces over the photos, not a page. A face shows
    /// that person's photos in place; a group nobody named is named there.
    func testFacesOverThePhotosShowAPersonsPhotos() {
        exerciseFaces(launch(language: "en", extraArguments: ["-MomentsUITestPeople"]), prefix: "faces")
    }

    func testFacesOverThePhotosShowAPersonsPhotosInASmallWindow() {
        exerciseFaces(launch(language: "en", smallWindow: true, extraArguments: ["-MomentsUITestPeople"]), prefix: "faces-small")
    }

    private func exerciseFaces(_ app: XCUIApplication, prefix: String) {
        let allCount = libraryPhotoCount(app)
        let strip = element(in: app, identifier: "library.people")
        XCTAssertTrue(strip.waitForExistence(timeout: launchTimeout), "The Library has no row of faces")
        let alex = element(in: app, identifier: "library.person.Alex")
        XCTAssertTrue(alex.waitForExistence(timeout: launchTimeout), "A named person is missing from the row of faces")
        capture(app, named: "\(prefix)-01-row-evidence")
        alex.click()

        // The Library narrows in place: a heading with the face and name,
        // only that person's photos, and the way back.
        let heading = element(in: app, identifier: "library.scope")
        XCTAssertTrue(heading.waitForExistence(timeout: launchTimeout), "A face did not show that person's photos")
        XCTAssertEqual(libraryPhotoCount(app), 2, "Alex is in two synthetic photos")
        XCTAssertTrue(strip.waitForNonExistence(timeout: launchTimeout), "The row of faces should give way to the heading")
        capture(app, named: "\(prefix)-02-person-evidence")

        // The face in the heading picks which face stands for Alex.
        let headingFace = element(in: app, identifier: "library.scope.face")
        XCTAssertTrue(headingFace.waitForExistence(timeout: launchTimeout), "A person's face in the heading is not a control")
        let coverBefore: String = (headingFace.value as? String) ?? ""
        headingFace.click()
        let picks = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT (identifier ENDSWITH %@)", "library.scope.face.pick.", "." + coverBefore))
        let other = picks.firstMatch
        XCTAssertTrue(other.waitForExistence(timeout: launchTimeout), "Clicking the face did not offer Alex's other faces")
        capture(app, named: "\(prefix)-02b-key-face-picker-evidence")
        let pickedID: String = String(other.identifier.dropFirst("library.scope.face.pick.".count))
        other.click()
        XCTAssertTrue(other.waitForNonExistence(timeout: launchTimeout), "Picking a face did not close the picker")
        let changed = NSPredicate(format: "value == %@", pickedID)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: changed, evaluatedWith: headingFace)], timeout: launchTimeout), .completed, "The picked face does not stand for Alex")

        element(in: app, identifier: "window.back").click()
        XCTAssertTrue(heading.waitForNonExistence(timeout: launchTimeout))
        XCTAssertEqual(libraryPhotoCount(app), allCount)

        // A group nobody has named: the name is typed in the heading.
        let unnamed = element(in: app, identifier: "library.person.unnamed")
        XCTAssertTrue(unnamed.waitForExistence(timeout: launchTimeout), "The unnamed group is missing from the row of faces")
        unnamed.click()
        let name = app.textFields["library.scope.name"]
        XCTAssertTrue(name.waitForExistence(timeout: launchTimeout), "The unnamed group has no name field")
        XCTAssertEqual(libraryPhotoCount(app), 5, "The unnamed group is in five synthetic photos")
        name.click()
        name.typeText("Robin\r")
        capture(app, named: "\(prefix)-03-named-evidence")
        element(in: app, identifier: "window.back").click()
        XCTAssertTrue(element(in: app, identifier: "library.person.Robin").waitForExistence(timeout: launchTimeout), "The named group did not join the row of faces")
        XCTAssertTrue(unnamed.waitForNonExistence(timeout: launchTimeout), "The group still asks for a name")

        // A name someone else has: the app asks before joining the two, and
        // then shows both people's photos as one person's.
        alex.click()
        XCTAssertTrue(name.waitForExistence(timeout: launchTimeout), "Alex's heading has no name field")
        XCTAssertEqual(libraryPhotoCount(app), 2)
        name.click()
        name.typeKey("a", modifierFlags: .command)
        name.typeText("Robin\r")
        let merge = app.buttons["Merge"].firstMatch
        XCTAssertTrue(merge.waitForExistence(timeout: launchTimeout), "Typing another person's name did not ask before merging")
        XCTAssertEqual(libraryPhotoCount(app), 2, "The two people were joined before the question was answered")
        capture(app, named: "\(prefix)-04-merge-question-evidence")
        // Return takes the default answer, Merge. Not a click: the first
        // match can be the Touch Bar's copy of the button, which cannot be
        // clicked.
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(merge.waitForNonExistence(timeout: launchTimeout))
        let joined: Int = libraryPhotoCount(app)
        XCTAssertEqual(joined, 7, "After the merge the heading should show both people's photos: Alex's two and the group's five")
        capture(app, named: "\(prefix)-05-merged-evidence")
        element(in: app, identifier: "window.back").click()
        XCTAssertTrue(alex.waitForNonExistence(timeout: launchTimeout), "Alex is still in the row of faces after joining Robin")
        XCTAssertTrue(element(in: app, identifier: "library.person.Robin").waitForExistence(timeout: launchTimeout), "Robin left the row of faces")
    }

    /// The search field finds people by name, as it finds places and trips.
    func testSearchFindsAPersonByName() {
        let app = launch(language: "en", extraArguments: ["-MomentsUITestPeople"])
        let allCount = libraryPhotoCount(app)
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: launchTimeout), "The Library has no search field")
        search.click()
        search.typeText("Alex")
        let narrowed = NSPredicate(format: "value == %@", "2")
        let count = element(in: app, identifier: "library.photoCount")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: narrowed, evaluatedWith: count)], timeout: launchTimeout), .completed, "Searching a person's name did not find their photos (\(count.value as? String ?? "") of \(allCount))")
        capture(app, named: "search-01-person-evidence")
    }

    func testPlacesMapHasSyntheticMarkers() {
        let app = launch(language: "en")
        let map = openMapAtPhotos(app)
        let firstMarker = element(in: app, identifier: "map.marker.D0001")
        XCTAssertTrue(firstMarker.waitForExistence(timeout: launchTimeout), "Route-start synthetic place marker was not exposed")
        // Record where every marker and label sits, so a failure in CI says why.
        let placeElements = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "map."))
            .allElementsBoundByIndex
        let layout = placeElements.map { "\($0.identifier) \($0.elementType.rawValue) \($0.frame) hittable=\($0.isHittable)" }
        let note = XCTAttachment(string: (["map \(map.frame)"] + layout).joined(separator: "\n"))
        note.name = "places-layout"
        note.lifetime = .keepAlways
        add(note)
        XCTAssertGreaterThanOrEqual(firstMarker.frame.width, 16, "Route-start marker is too narrow to be visible")
        XCTAssertGreaterThanOrEqual(firstMarker.frame.height, 16, "Route-start marker is too short to be visible")
        XCTAssertTrue(map.frame.contains(firstMarker.frame), "Route-start marker is outside the Places map")
        XCTAssertTrue(firstMarker.isHittable, "Route-start marker is not hittable")
        let marker = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "map.marker."))
            .firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: launchTimeout), "Synthetic place marker was not exposed")
        capture(app, named: "map-01-photo-pins-evidence")
    }

    /// The way maple went: the large map, a place, one of its photos looked
    /// at, then "Show in Library". Back returns to the map with that place's
    /// photos open, and once more to where the map was opened.
    func testBackFromShowInLibraryReturnsToTheMapsPlace() {
        let app = launch(language: "en")
        _ = openMapAtPhotos(app)
        let marker = element(in: app, identifier: "map.marker.D0001")
        XCTAssertTrue(marker.waitForExistence(timeout: launchTimeout))
        marker.click()
        let panel = element(in: app, identifier: "map.panel")
        XCTAssertTrue(panel.waitForExistence(timeout: launchTimeout), "Clicking a place did not open its photos")

        let photo = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "map.panel.photo."))
            .firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: launchTimeout), "The place's strip has no photo")
        photo.click()
        let viewer = element(in: app, identifier: "viewer")
        XCTAssertTrue(viewer.waitForExistence(timeout: launchTimeout), "Clicking a photo in the strip did not open it")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(viewer.waitForNonExistence(timeout: launchTimeout))
        XCTAssertTrue(panel.exists, "Closing the photo closed the place's strip too")

        element(in: app, identifier: "map.panel.show-in-library").click()
        let heading = element(in: app, identifier: "library.scope")
        XCTAssertTrue(heading.waitForExistence(timeout: launchTimeout), "Show in Library did not show the place's photos")
        let map = element(in: app, identifier: "map.view")
        XCTAssertTrue(map.waitForNonExistence(timeout: launchTimeout))
        capture(app, named: "back-map-01-show-in-library-evidence")

        let back = element(in: app, identifier: "window.back")
        XCTAssertTrue(back.waitForExistence(timeout: launchTimeout), "The Library has no Back after Show in Library")
        back.click()
        XCTAssertTrue(map.waitForExistence(timeout: 30), "Back did not return to the large map")
        XCTAssertTrue(panel.waitForExistence(timeout: 30), "The map came back without the place that was open")
        XCTAssertFalse(heading.exists, "The place's photos stayed in front of the map")
        Thread.sleep(forTimeInterval: 1.0)
        capture(app, named: "back-map-02-returned-evidence")

        // The map was opened from Chapters: Back closes it there.
        back.click()
        XCTAssertTrue(map.waitForNonExistence(timeout: launchTimeout), "Back did not close the large map")
        XCTAssertTrue(back.waitForNonExistence(timeout: launchTimeout), "Chapters has nothing to go back to, yet shows Back")
    }

    func testPlacesPanelIsCompactAndCloses() {
        let app = launch(language: "en")
        let map = openMapAtPhotos(app)
        let marker = element(in: app, identifier: "map.marker.D0001")
        XCTAssertTrue(marker.waitForExistence(timeout: launchTimeout))
        marker.click()

        let panel = element(in: app, identifier: "map.panel")
        XCTAssertTrue(panel.waitForExistence(timeout: launchTimeout), "Clicking a place did not open its photo panel")
        Thread.sleep(forTimeInterval: 1.0)
        capture(app, named: "map-02-panel-open-evidence")
        let title = element(in: app, identifier: "map.panel.title")
        let titleText = (title.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? title.label
        log("places panel \(panel.frame) map \(map.frame) title '\(titleText)'")
        XCTAssertLessThan(panel.frame.height, map.frame.height * 0.45, "The photo panel covers most of the map (panel \(panel.frame), map \(map.frame))")
        XCTAssertGreaterThan(panel.frame.minY, map.frame.midY, "The photo panel should sit at the bottom of the map")

        element(in: app, identifier: "map.panel.close").click()
        XCTAssertTrue(panel.waitForNonExistence(timeout: launchTimeout), "The close button did not close the photo panel")

        marker.click()
        XCTAssertTrue(panel.waitForExistence(timeout: launchTimeout))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(panel.waitForNonExistence(timeout: launchTimeout), "Escape did not close the photo panel")
        capture(app, named: "map-03-panel-closed")
    }

    /// Settings are reachable from the sidebar, not only via ⌘,, and are one
    /// page: no tabs and no language picker; AI organizing is rows of it.
    func testSidebarOpensSettingsAsOnePage() {
        let app = launch(language: "en")
        let gear = element(in: app, identifier: "sidebar.settings")
        XCTAssertTrue(gear.waitForExistence(timeout: launchTimeout))
        let windowsBefore = app.windows.count
        gear.click()
        // A whole-tree label search timed out on the runner; a new window is
        // enough to prove the Settings window opened.
        let deadline = Date().addingTimeInterval(launchTimeout)
        while app.windows.count <= windowsBefore && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.3)
        }
        if app.windows.count <= windowsBefore {
            capture(app, named: "settings-00b-gear-no-window-evidence")
            print("SIDEBAR-GEAR frame=\(gear.frame) hittable=\(gear.isHittable) window=\(app.windows.firstMatch.frame)")
        }
        XCTAssertGreaterThan(app.windows.count, windowsBefore, "The settings window did not open")
        // Sharing and the backup sit on the same page.
        XCTAssertTrue(element(in: app, identifier: "settings.backup-status").waitForExistence(timeout: launchTimeout), "Settings has no backup section")
        let window = app.windows.containing(.any, identifier: "settings.backup-status").firstMatch
        let aboutSharing = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Sharing", "Sharing")
        XCTAssertTrue(window.staticTexts.matching(aboutSharing).firstMatch.waitForExistence(timeout: launchTimeout), "Settings has no sharing section")
        // AI organizing is a few rows of the same page.
        XCTAssertTrue(element(in: app, identifier: "settings.ai-enabled").waitForExistence(timeout: launchTimeout), "Settings has no AI switch")
        XCTAssertFalse(element(in: app, identifier: "settings.language").exists, "The language picker is back in Settings")
        XCTAssertFalse(element(in: app, identifier: "settings.auto-organize").exists, "The organize switch is back in Settings")
        XCTAssertEqual(window.toolbars.buttons.count, 0, "Settings has tabs again")
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "settings-01-one-page-evidence"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.typeKey("w", modifierFlags: .command)
    }

    /// Settings: AI starts on, and a custom model is an address, a model
    /// name and a key, tied to no one provider.
    func testAISettingsStartOnAndACustomModelIsJustThreeFields() {
        let app = launch(language: "en", extraArguments: ["-moments.ai.engine", "cloud"])
        app.typeKey(",", modifierFlags: .command)
        let toggle = element(in: app, identifier: "settings.ai-enabled")
        XCTAssertTrue(toggle.waitForExistence(timeout: launchTimeout), "Settings has no AI switch")
        let value: String = String(describing: toggle.value ?? "nil")
        XCTAssertTrue(["1", "true"].contains(value), "AI does not start on: \(value)")
        for identifier in ["settings.ai-engine", "settings.ai-address", "settings.ai-model", "settings.ai-key"] {
            XCTAssertTrue(element(in: app, identifier: identifier).exists, "\(identifier) is missing")
        }
        let window = app.windows.containing(.any, identifier: "settings.ai-enabled").firstMatch
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "settings-03-ai-custom-evidence"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The app follows the Mac's language: the sidebar comes from the
    /// catalog in German (small window) and in Chinese.
    func testSidebarIsTranslated() {
        let cases = [
            ("de", true, "Mediathek"),
            ("zh-Hans", false, "图库"),
        ]
        for (language, smallWindow, libraryLabel) in cases {
            let app = launch(language: language, smallWindow: smallWindow)
            // The small window may start with the sidebar folded away.
            let library = element(in: app, identifier: "sidebar.library")
            let sidebarShown = library.waitForExistence(timeout: smallWindow ? 5 : launchTimeout)
            XCTAssertTrue(sidebarShown || smallWindow, "The sidebar is missing in \(language)")
            if sidebarShown {
                // macOS puts a sidebar row's text in the value of its static text.
                let parts = [library] + library.descendants(matching: .any).allElementsBoundByIndex
                let texts = parts.flatMap { [$0.label, $0.title, $0.value as? String ?? ""] }.filter { !$0.isEmpty }
                XCTAssertTrue(texts.contains(libraryLabel), "The sidebar reads \(texts), not \(libraryLabel), in \(language)")
            }
            capture(app, named: "language-01-\(language)-evidence")
            app.terminate()
        }
    }

    /// Settings shows the automatic backup and the one button there is, also
    /// at the small window size. The in-memory test
    /// store has no backups, so the row says so.
    func testSettingsShowAutomaticBackup() {
        let app = launch(language: "en", smallWindow: true)
        app.typeKey(",", modifierFlags: .command)
        let status = element(in: app, identifier: "settings.backup-status")
        XCTAssertTrue(status.waitForExistence(timeout: launchTimeout), "Settings has no backup row")
        let restore = element(in: app, identifier: "settings.backup-restore")
        XCTAssertTrue(restore.exists, "The backup row has no Restore from Backup button")
        let window = app.windows.containing(.any, identifier: "settings.backup-status").firstMatch
        // The row's own text, not a walk over every text on the page: the
        // AI rows above gain a status line a moment after the page opens,
        // and a list taken by index then misses its last entry.
        let reads = NSPredicate(format: "label == %@ OR value == %@", "No backup yet", "No backup yet")
        let settled = XCTWaiter.wait(for: [expectation(for: reads, evaluatedWith: status)], timeout: launchTimeout)
        XCTAssertEqual(settled, .completed, "The backup row reads \(status.label) / \(status.value as? String ?? "")")
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "settings-03-backup-evidence"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }

    func testFootprintsGlobeOpens() {
        let app = launch(language: "en")
        assertGlobeFullyVisible(app, screenshot: "map-04-globe-evidence")
    }

    /// In the smallest window nothing overlaps: the Library has no rows of
    /// controls over its photos, Chapters keeps its small map inside the
    /// window, and the large map's countries card clears its controls.
    func testSmallWindowHasNoOverlaps() {
        let app = launch(language: "en", smallWindow: true, extraArguments: ["-MomentsUITestPeople"])
        XCTAssertTrue(element(in: app, identifier: "library.photoCount").waitForExistence(timeout: launchTimeout))
        // No rows of controls over the photos: the filters sit behind the
        // toolbar's Filter button, which fits the small window.
        for identifier in ["filter.date", "library.type-filter", "library.grouping", "library.review-banner"] {
            XCTAssertFalse(element(in: app, identifier: identifier).exists, "\(identifier) is back above the photos")
        }
        let window = app.windows.firstMatch.frame
        let filterButton = element(in: app, identifier: "toolbar.filter")
        XCTAssertTrue(filterButton.waitForExistence(timeout: launchTimeout), "The Library has no Filter button")
        XCTAssertTrue(window.contains(filterButton.frame), "The Filter button \(filterButton.frame) spills outside the window \(window)")
        let strip = element(in: app, identifier: "library.people")
        XCTAssertTrue(strip.waitForExistence(timeout: launchTimeout))
        XCTAssertTrue(window.contains(strip.frame), "The row of faces \(strip.frame) spills outside the window \(window)")
        capture(app, named: "small-01-library-evidence")

        element(in: app, identifier: "sidebar.trips").click()
        let footprints = element(in: app, identifier: "trips.footprints")
        XCTAssertTrue(footprints.waitForExistence(timeout: launchTimeout), "Chapters has no small map over the cards")
        XCTAssertTrue(app.windows.firstMatch.frame.contains(footprints.frame), "The small map \(footprints.frame) spills outside the window")
        capture(app, named: "small-02-chapters-evidence")

        openLargeMap(app)
        let stats = element(in: app, identifier: "map.stats")
        let toolbar = element(in: app, identifier: "map.toolbar")
        XCTAssertTrue(stats.waitForExistence(timeout: 30))
        XCTAssertTrue(toolbar.waitForExistence(timeout: launchTimeout))
        Thread.sleep(forTimeInterval: 1.5)
        capture(app, named: "small-03-map-evidence")
        XCTAssertFalse(stats.frame.intersects(toolbar.frame), "Countries card \(stats.frame) overlaps the map controls \(toolbar.frame)")
        let back = element(in: app, identifier: "window.back")
        XCTAssertTrue(back.waitForExistence(timeout: launchTimeout), "The large map has no Back in the small window")
        back.click()
        XCTAssertTrue(footprints.waitForExistence(timeout: launchTimeout), "Back did not return to Chapters")

        // A chapter: its people, its route map and its days fit side by side.
        element(in: app, identifier: "trips.card.journeyA").click()
        let tripMemory = element(in: app, identifier: "trips.memory.trip")
        XCTAssertTrue(tripMemory.waitForExistence(timeout: launchTimeout))
        let route = element(in: app, identifier: "trips.map")
        XCTAssertTrue(route.waitForExistence(timeout: launchTimeout), "The chapter has no route map")
        XCTAssertTrue(app.windows.firstMatch.frame.contains(route.frame), "The route map \(route.frame) spills outside the window")
        XCTAssertFalse(route.frame.intersects(tripMemory.frame), "The route map overlaps the memory line")
        capture(app, named: "small-04-chapter-evidence")
    }

    func testFootprintsGlobeFitsSmallWindow() {
        let app = launch(language: "en", smallWindow: true)
        assertGlobeFullyVisible(app, screenshot: "map-05-globe-small-window-evidence")
    }

    /// The globe sits on black space: scan the middle row and column of the
    /// map for the first and last bright pixels. A cropped globe touches the
    /// map's edges.
    private func assertGlobeFullyVisible(_ app: XCUIApplication, screenshot name: String, file: StaticString = #filePath, line: UInt = #line) {
        // The large map of every photo opens on the globe. The first MapKit
        // globe of a test run can take longer to appear.
        let globe = openLargeMap(app, file: file, line: line)
        Thread.sleep(forTimeInterval: 3.0)
        capture(app, named: name)

        guard let cgImage = globe.screenshot().image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            XCTFail("Could not read the globe screenshot", file: file, line: line)
            return
        }
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        func luminance(_ x: Int, _ y: Int) -> Double {
            let index = (y * width + x) * 4
            return (0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1]) + 0.0722 * Double(pixels[index + 2])) / 255
        }
        let threshold = 0.08
        // Ignore the compass and scale overlays near the corners: scan the middle third.
        let row = height / 2
        let column = width / 2
        // Stars are single bright pixels; the globe is a run of them.
        func runs(_ count: Int, _ value: (Int) -> Double) -> [Int] {
            (0..<count).filter { start in
                start + 4 <= count && (start..<start + 4).allSatisfy { value($0) > threshold }
            }
        }
        let bright = runs(width) { luminance($0, row) }.flatMap { [$0, $0 + 3] }
        let brightRows = runs(height) { luminance(column, $0) }.flatMap { [$0, $0 + 3] }
        let samples = [0.0, 0.25, 0.5, 0.75, 1.0].map { fraction -> String in
            let x = min(width - 1, Int(Double(width - 1) * fraction))
            return String(format: "%.2f", luminance(x, row))
        }
        log("\(name) globe \(globe.frame) px \(width)x\(height) row x=\(bright.first ?? -1)...\(bright.last ?? -1) column y=\(brightRows.first ?? -1)...\(brightRows.last ?? -1) row samples \(samples)")
        guard let left = bright.first, let right = bright.last, let top = brightRows.first, let bottom = brightRows.last else {
            XCTFail("The globe did not render", file: file, line: line)
            return
        }
        let marginX = max(2, width / 100)
        let marginY = max(2, height / 100)
        XCTAssertGreaterThan(left, marginX, "The globe is cut off on the left", file: file, line: line)
        XCTAssertLessThan(right, width - 1 - marginX, "The globe is cut off on the right", file: file, line: line)
        XCTAssertGreaterThan(top, marginY, "The globe is cut off at the top", file: file, line: line)
        XCTAssertLessThan(bottom, height - 1 - marginY, "The globe is cut off at the bottom", file: file, line: line)
        // A globe pushed sideways (the map drawing under the sidebar) is off centre.
        let centreOffset = abs(Double(left + right) / 2 - Double(width) / 2)
        XCTAssertLessThan(centreOffset, Double(width) * 0.08, "The globe is not centred in the map (offset \(centreOffset) px)", file: file, line: line)
    }

    private func log(_ message: String) {
        print("MOMENTS-UI \(message)")
        let note = XCTAttachment(string: message)
        note.name = "note"
        note.lifetime = .keepAlways
        add(note)
    }

    /// The sidebar holds the two pages the app is for and nothing else:
    /// people, the map and the timeline are not pages, and nothing is tucked
    /// under a "More" row.
    func testSidebarHasOnlyLibraryAndChapters() {
        let app = launch(language: "en")
        for identifier in ["sidebar.library", "sidebar.trips", "sidebar.settings"] {
            XCTAssertTrue(element(in: app, identifier: identifier).waitForExistence(timeout: launchTimeout), "Missing \(identifier)")
        }
        for identifier in ["sidebar.more", "sidebar.map", "sidebar.people", "sidebar.timeline", "sidebar.review", "sidebar.places", "sidebar.footprints", "sidebar.import", "sidebar.new-group"] {
            XCTAssertFalse(element(in: app, identifier: identifier).exists, "\(identifier) should have left the sidebar")
        }
        // The Library opens straight on its photos: no banner, no rows of controls.
        for identifier in ["library.review-banner", "library.type-filter", "filter.date", "reorganize.all"] {
            XCTAssertFalse(element(in: app, identifier: identifier).exists, "\(identifier) is back")
        }
        capture(app, named: "sidebar-01-two-pages-evidence")

        let importButton = element(in: app, identifier: "toolbar.import")
        importButton.click()
        // Scoped to the button: the File menu has the same two commands.
        XCTAssertTrue(importButton.menuItems["Import Folder…"].waitForExistence(timeout: launchTimeout), "The + button did not open its menu")
        XCTAssertTrue(importButton.menuItems["Import from Apple Photos…"].exists)
        capture(app, named: "toolbar-01-import-menu-evidence")
        app.typeKey(.escape, modifierFlags: [])

        // Chapters brings its own +; the import + belongs to the Library.
        element(in: app, identifier: "sidebar.trips").click()
        XCTAssertTrue(element(in: app, identifier: "trips.new").waitForExistence(timeout: launchTimeout))
        XCTAssertTrue(importButton.waitForNonExistence(timeout: launchTimeout), "Chapters still shows the import +")
    }

    /// The filters on every page sit behind the toolbar's Filter button, right
    /// of the +: each chip in it opens its list, what is picked shows below
    /// with Clear, and the same filters narrow Chapters and the large map. A
    /// chapter card shows who was on it.
    func testFiltersNarrowTheLibraryChaptersAndTheMap() {
        let app = launch(language: "en", extraArguments: ["-MomentsUITestPeople"])
        let allCount = libraryPhotoCount(app)
        XCTAssertFalse(element(in: app, identifier: "filter.person").exists, "Filter chips are spread over the photos")
        let libraryFilter = element(in: app, identifier: "toolbar.filter")
        XCTAssertTrue(libraryFilter.waitForExistence(timeout: launchTimeout), "The Library has no Filter button")
        let importButton = element(in: app, identifier: "toolbar.import")
        XCTAssertTrue(importButton.exists)
        // Items in one toolbar group overlap by a point or two.
        XCTAssertGreaterThan(libraryFilter.frame.midX, importButton.frame.maxX - 4, "Filter is not right of the +")

        // Person, then back to every photo.
        var popover = openFilters(app, libraryFilter)
        for identifier in ["filter.type", "filter.place", "filter.trip", "filter.date", "filter.memory", "filter.person"] {
            XCTAssertTrue(popover.descendants(matching: .any).matching(identifier: identifier).firstMatch.exists, "\(identifier) is missing from Filter")
        }
        capture(app, named: "filters-01-chips-evidence")
        popover.descendants(matching: .any).matching(identifier: "filter.person").firstMatch.click()
        let alex = app.menuItems["Alex"].firstMatch
        XCTAssertTrue(alex.waitForExistence(timeout: launchTimeout), "Person did not open its list")
        alex.click()
        XCTAssertEqual(libraryPhotoCount(app), 2, "Alex is in two synthetic photos")
        XCTAssertEqual(libraryFilter.value as? String, "1", "Filter does not count the picked person")
        capture(app, named: "filters-02-person-evidence")
        popover = openFilters(app, libraryFilter)
        let clear = popover.descendants(matching: .any).matching(identifier: "filter.clear").firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: launchTimeout), "A picked filter shows no Clear")
        clear.click()
        XCTAssertEqual(libraryPhotoCount(app), allCount)

        // Trip: the Library, Chapters and the large map all narrow to it.
        popover = openFilters(app, libraryFilter)
        popover.descendants(matching: .any).matching(identifier: "filter.trip").firstMatch.click()
        let journey = app.menuItems["journeyA"].firstMatch
        XCTAssertTrue(journey.waitForExistence(timeout: launchTimeout), "Trip did not open its list")
        journey.click()
        let tripCount = libraryPhotoCount(app)
        XCTAssertTrue(tripCount > 0 && tripCount < allCount, "The Trip filter left \(tripCount) of \(allCount) photos")
        // The button closes what it opened.
        if popover.exists { libraryFilter.click() }
        XCTAssertTrue(popover.waitForNonExistence(timeout: launchTimeout), "The Filter popover did not close")

        element(in: app, identifier: "sidebar.trips").click()
        let filterButton = element(in: app, identifier: "toolbar.filter")
        XCTAssertTrue(filterButton.waitForExistence(timeout: launchTimeout), "Chapters has no Filter button")
        XCTAssertEqual(filterButton.value as? String, "1", "Chapters does not count the Library's filter")
        let card = element(in: app, identifier: "trips.card.journeyA")
        XCTAssertTrue(card.waitForExistence(timeout: launchTimeout))
        XCTAssertTrue(element(in: app, identifier: "trips.card.journeyB").waitForNonExistence(timeout: launchTimeout), "A chapter outside the filter still shows")
        let companions = element(in: app, identifier: "trips.card.people")
        XCTAssertTrue(companions.waitForExistence(timeout: launchTimeout), "The chapter card does not show who was there")
        XCTAssertTrue(element(in: app, identifier: "trips.card.person.Alex").exists, "A named person is missing from the card")
        capture(app, named: "filters-03-chapters-evidence")

        filterButton.click()
        popover = app.popovers.firstMatch
        XCTAssertTrue(popover.waitForExistence(timeout: launchTimeout), "Filter did not open the chips")
        XCTAssertTrue(popover.descendants(matching: .any).matching(identifier: "filter.trip").firstMatch.exists)
        capture(app, named: "filters-04-chapters-popover-evidence")
        popover.descendants(matching: .any).matching(identifier: "filter.clear").firstMatch.click()
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(element(in: app, identifier: "trips.card.journeyB").waitForExistence(timeout: launchTimeout), "Clearing the filter did not bring every chapter back")

        // The large map has the same Filter button.
        openLargeMap(app)
        XCTAssertTrue(element(in: app, identifier: "toolbar.filter").waitForExistence(timeout: 30), "The large map has no Filter button")
        capture(app, named: "filters-05-map-evidence")
        element(in: app, identifier: "window.back").click()

        // A face on a card opens that person's photos.
        element(in: app, identifier: "trips.card.person.Alex").click()
        XCTAssertTrue(element(in: app, identifier: "library.scope").waitForExistence(timeout: launchTimeout), "A face on the card did not show that person's photos")
        XCTAssertEqual(libraryPhotoCount(app), 2)
    }

    /// A chapter shows who is in it and where it went. A face opens that
    /// person's photos; the route map opens the large map with the chapter's
    /// photos, and Back returns to the chapter.
    func testChapterShowsItsPeopleAndOpensItsMap() {
        let app = launch(language: "en", extraArguments: ["-MomentsUITestPeople"])
        element(in: app, identifier: "sidebar.trips").click()
        let card = element(in: app, identifier: "trips.card.journeyA")
        XCTAssertTrue(card.waitForExistence(timeout: launchTimeout))

        // A stamp on the small map over the cards opens its chapter.
        let stamp = element(in: app, identifier: "trips.footprint.journeyA")
        XCTAssertTrue(stamp.waitForExistence(timeout: launchTimeout), "The chapter has no stamp on the small map")
        capture(app, named: "chapter-01-footprints-evidence")
        stamp.click()
        let tripMemory = element(in: app, identifier: "trips.memory.trip")
        XCTAssertTrue(tripMemory.waitForExistence(timeout: launchTimeout), "The stamp did not open its chapter")

        let route = element(in: app, identifier: "trips.map")
        XCTAssertTrue(route.waitForExistence(timeout: launchTimeout), "The chapter has no route map")
        let people = element(in: app, identifier: "trips.people")
        XCTAssertTrue(people.waitForExistence(timeout: launchTimeout), "The chapter does not show who is in it")
        capture(app, named: "chapter-02-people-and-map-evidence")

        route.click()
        XCTAssertTrue(element(in: app, identifier: "map.view").waitForExistence(timeout: 30), "The route map did not open the large map")
        Thread.sleep(forTimeInterval: 1.5)
        capture(app, named: "chapter-03-large-map-evidence")
        let back = element(in: app, identifier: "window.back")
        XCTAssertTrue(back.waitForExistence(timeout: launchTimeout), "The large map has no Back")
        back.click()
        XCTAssertTrue(tripMemory.waitForExistence(timeout: launchTimeout), "Back did not return to the chapter")

        // A face opens that person's photos in the Library.
        element(in: app, identifier: "trips.person.Alex").click()
        XCTAssertTrue(element(in: app, identifier: "library.scope").waitForExistence(timeout: launchTimeout), "A face on the chapter did not show that person's photos")
        XCTAssertEqual(libraryPhotoCount(app), 2)
    }

    func testTripsOpenATripWriteItsMemoryAndOpenAPhoto() {
        let app = launch(language: "en")
        element(in: app, identifier: "sidebar.trips").click()

        // The shelf: one cover card per trip.
        let card = element(in: app, identifier: "trips.card.journeyA")
        XCTAssertTrue(card.waitForExistence(timeout: launchTimeout), "Trip cover card was not exposed")
        XCTAssertTrue(element(in: app, identifier: "trips.card.journeyB").exists, "Every trip gets a card")
        Thread.sleep(forTimeInterval: 0.8)
        capture(app, named: "trips-01-shelf-evidence")
        card.click()

        // The trip: its memory line, then days with places and photos.
        let tripMemory = element(in: app, identifier: "trips.memory.trip")
        XCTAssertTrue(tripMemory.waitForExistence(timeout: launchTimeout), "Opening a trip did not show it")
        let dayLine = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "trips.memory.day."))
            .firstMatch
        XCTAssertTrue(dayLine.waitForExistence(timeout: launchTimeout), "A dated day has no memory line")

        tripMemory.click()
        tripMemory.typeText("Synthetic trip memory\r")
        let written = app.staticTexts
            .matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "Synthetic trip memory", "Synthetic trip memory"))
            .firstMatch
        let saved = written.waitForExistence(timeout: launchTimeout)
        capture(app, named: "trips-02a-after-return-evidence")
        XCTAssertTrue(saved, "Return did not save the trip memory")
        XCTAssertFalse((tripMemory.value as? String ?? "").contains("Synthetic trip memory"), "The memory line was not cleared after saving")
        Thread.sleep(forTimeInterval: 0.8)
        capture(app, named: "trips-02-trip-evidence")

        // A photo opens the large viewer, which pages through the trip.
        let photo = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "trips.photo.")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: launchTimeout))
        photo.click()
        let viewer = element(in: app, identifier: "viewer")
        XCTAssertTrue(viewer.waitForExistence(timeout: launchTimeout), "Clicking a photo did not open it")
        capture(app, named: "trips-03-viewer-evidence")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(viewer.waitForNonExistence(timeout: launchTimeout))

        // The open trip survives a visit to another screen.
        element(in: app, identifier: "sidebar.library").click()
        element(in: app, identifier: "sidebar.trips").click()
        XCTAssertTrue(tripMemory.waitForExistence(timeout: launchTimeout), "The open trip was lost on a screen switch")

        // Back to the shelf.
        let back = element(in: app, identifier: "window.back")
        XCTAssertTrue(back.waitForExistence(timeout: launchTimeout))
        back.click()
        XCTAssertTrue(card.waitForExistence(timeout: launchTimeout), "Back did not return to the trip cards")
        capture(app, named: "trips-04-shelf-with-memory-evidence")
    }

    func testDoubleClickRenamesATripInPlace() {
        let app = launch(language: "en")
        // The Library lists chapters as sections; a chapter's title renames in place.
        // Newest trips come first, so take whichever trip title is on screen.
        let title = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "trip.title."))
            .firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: launchTimeout), "The Library has no trip title")
        let tripID = String(title.identifier.dropFirst("trip.title.".count))
        title.doubleClick()
        let field = element(in: app, identifier: "trip.rename.\(tripID)")
        XCTAssertTrue(field.waitForExistence(timeout: launchTimeout), "Double-click did not start renaming")
        field.typeKey("a", modifierFlags: .command)
        field.typeText("Synthetic renamed trip\r")
        let renamed = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND (label CONTAINS %@ OR value CONTAINS %@)", "trip.title.\(tripID)", "Synthetic renamed trip", "Synthetic renamed trip"))
            .firstMatch
        XCTAssertTrue(renamed.waitForExistence(timeout: launchTimeout), "Return did not save the new name")
        capture(app, named: "library-04-trip-renamed-evidence")

        // The Trips card follows.
        element(in: app, identifier: "sidebar.trips").click()
        let cardName = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND (label CONTAINS %@ OR value CONTAINS %@)", "trips.card.name.\(tripID)", "Synthetic renamed trip", "Synthetic renamed trip"))
            .firstMatch
        XCTAssertTrue(cardName.waitForExistence(timeout: launchTimeout), "The trip card kept the old name")
    }

    func testTripDatesPreviewBeforeApplying() {
        let app = launch(language: "en")
        element(in: app, identifier: "sidebar.trips").click()
        let card = element(in: app, identifier: "trips.card.journeyA")
        XCTAssertTrue(card.waitForExistence(timeout: launchTimeout))

        // The print behind comes to the front as the cover with one click.
        let front = element(in: app, identifier: "trips.cover.front.journeyA")
        let behind = element(in: app, identifier: "trips.cover.back.journeyA")
        XCTAssertTrue(front.waitForExistence(timeout: launchTimeout), "The cover cannot be changed")
        XCTAssertTrue(behind.exists, "The print behind is not a choice of its own")
        let behindID: String = (behind.value as? String) ?? ""
        XCTAssertNotEqual(behindID, (front.value as? String) ?? "", "The two prints show the same photo")
        // Most of the print behind lies under the one in front; click the
        // strip of it that shows on the left, as a person would.
        behind.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5)).click()
        let swapped = NSPredicate(format: "value == %@", behindID)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: swapped, evaluatedWith: front)], timeout: launchTimeout), .completed, "Clicking the print behind did not make it the cover")
        capture(app, named: "trips-04b-cover-swapped-evidence")

        // The print in front opens every photo to pick from.
        front.click()
        let pick = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "trips.cover.pick."))
            .element(boundBy: 3)
        XCTAssertTrue(pick.waitForExistence(timeout: launchTimeout), "The cover picker shows no photos")
        capture(app, named: "trips-05-cover-picker-evidence")
        pick.click()
        XCTAssertTrue(pick.waitForNonExistence(timeout: launchTimeout), "Picking a cover did not close the picker")

        // The dates on the card open the date editor with a preview; nothing changes until Apply.
        element(in: app, identifier: "trips.card.dates.journeyA").click()
        let preview = element(in: app, identifier: "trips.dates.preview")
        XCTAssertTrue(preview.waitForExistence(timeout: launchTimeout), "The trip's dates show no preview")
        XCTAssertTrue(element(in: app, identifier: "trips.dates.apply").exists)
        capture(app, named: "trips-06-dates-preview-evidence")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(preview.waitForNonExistence(timeout: launchTimeout))
    }

    func testPlusOnTripsStartsANewTrip() {
        let app = launch(language: "en")
        element(in: app, identifier: "sidebar.trips").click()
        let plus = element(in: app, identifier: "trips.new")
        XCTAssertTrue(plus.waitForExistence(timeout: launchTimeout), "Trips has no + for a new trip")
        plus.click()
        let name = element(in: app, identifier: "trips.new.name")
        XCTAssertTrue(name.waitForExistence(timeout: launchTimeout), "+ did not open the new trip sheet")
        XCTAssertTrue(element(in: app, identifier: "trips.new.preview").exists, "The new trip sheet shows no preview")
        name.click()
        name.typeText("Synthetic new trip")
        capture(app, named: "trips-09-new-trip-evidence")
        element(in: app, identifier: "trips.new.create").click()
        let notice = element(in: app, identifier: "trips.notice")
        XCTAssertTrue(notice.waitForExistence(timeout: launchTimeout), "Creating a trip showed no note")
        element(in: app, identifier: "trips.notice.undo").click()
        XCTAssertTrue(notice.waitForNonExistence(timeout: launchTimeout))
    }

    func testNewCelebrationChapterGetsItsOwnCard() {
        let app = launch(language: "en")
        element(in: app, identifier: "sidebar.trips").click()
        element(in: app, identifier: "trips.new").click()
        let celebration = element(in: app, identifier: "chapters.new.type.celebration")
        XCTAssertTrue(celebration.waitForExistence(timeout: launchTimeout), "New chapter offers no kinds")
        celebration.click()
        let name = element(in: app, identifier: "trips.new.name")
        name.click()
        name.typeText("Synthetic birthday")
        capture(app, named: "chapters-01-new-celebration-evidence")
        element(in: app, identifier: "trips.new.create").click()

        // The new chapter opens; back on the shelf it has its own card, next
        // to the trips: there is no row of kinds to filter by.
        let back = element(in: app, identifier: "window.back")
        XCTAssertTrue(back.waitForExistence(timeout: launchTimeout), "The new chapter did not open")
        back.click()
        let card = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "trips.card.chapter."))
            .firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: launchTimeout), "The celebration has no card")
        XCTAssertTrue(element(in: app, identifier: "trips.card.journeyA").exists, "The trips left the shelf")
        XCTAssertFalse(element(in: app, identifier: "chapters.filter.celebration").exists, "The row of kinds is back")
        capture(app, named: "chapters-02-shelf-evidence")
    }

    func testSplitATripAtADayAndUndo() {
        let app = launch(language: "en")
        element(in: app, identifier: "sidebar.trips").click()
        let card = element(in: app, identifier: "trips.card.journeyA")
        XCTAssertTrue(card.waitForExistence(timeout: launchTimeout))
        let cards = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT (identifier BEGINSWITH %@) AND NOT (identifier BEGINSWITH %@)", "trips.card.", "trips.card.name.", "trips.card.dates."))
        let cardIDs = Set(cards.allElementsBoundByIndex.map(\.identifier))
        card.click()
        XCTAssertTrue(element(in: app, identifier: "trips.memory.trip").waitForExistence(timeout: launchTimeout))

        // Each day after the first can start a new trip.
        let menus = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "trips.day.menu."))
        XCTAssertTrue(menus.firstMatch.waitForExistence(timeout: launchTimeout), "Trip days have no menu")
        let third = menus.element(boundBy: 2)
        XCTAssertTrue(third.exists)
        third.click()
        let split = app.menuItems["Start a new trip from this day"]
        XCTAssertTrue(split.waitForExistence(timeout: launchTimeout), "The day menu cannot split the trip")
        capture(app, named: "trips-07-day-menu-evidence")
        split.click()

        let notice = element(in: app, identifier: "trips.notice")
        XCTAssertTrue(notice.waitForExistence(timeout: launchTimeout), "Splitting showed no note")
        capture(app, named: "trips-08-split-evidence")
        element(in: app, identifier: "trips.notice.undo").click()
        XCTAssertTrue(notice.waitForNonExistence(timeout: launchTimeout), "Undo did not finish")
        element(in: app, identifier: "window.back").click()
        XCTAssertTrue(card.waitForExistence(timeout: launchTimeout))
        Thread.sleep(forTimeInterval: 0.8)
        let afterIDs = Set(cards.allElementsBoundByIndex.map(\.identifier))
        XCTAssertTrue(afterIDs.isSubset(of: cardIDs), "Undo left the split-off trip behind: \(afterIDs.subtracting(cardIDs))")
    }

    func testTripPlaceShowsItsPhotosInLibrary() {
        let app = launch(language: "en")
        tripPlaceShowsItsPhotosInLibrary(app)
    }

    /// The Library restores where the user left it; a jump from a trip must still win.
    func testTripPlaceShowsItsPhotosInLibraryAfterScrolling() {
        let app = launch(language: "en")
        let photo = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.photo."))
            .firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: launchTimeout))
        photo.scroll(byDeltaX: 0, deltaY: -1500)
        Thread.sleep(forTimeInterval: 1)
        tripPlaceShowsItsPhotosInLibrary(app)
    }

    private func tripPlaceShowsItsPhotosInLibrary(_ app: XCUIApplication) {
        let allCount = libraryPhotoCount(app)
        element(in: app, identifier: "sidebar.trips").click()
        let card = element(in: app, identifier: "trips.card.journeyA")
        XCTAssertTrue(card.waitForExistence(timeout: launchTimeout))
        card.click()

        // A place's name lists its photos on their own in the Library.
        let place = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "trips.place.")).firstMatch
        XCTAssertTrue(place.waitForExistence(timeout: launchTimeout), "Trip place name was not exposed")
        place.click()

        let chip = element(in: app, identifier: "library.scope")
        XCTAssertTrue(chip.waitForExistence(timeout: launchTimeout), "Library should show the place as a heading over its photos")
        let scopedCount = libraryPhotoCount(app)
        XCTAssertGreaterThan(scopedCount, 0)
        XCTAssertLessThan(scopedCount, allCount, "Only the place's photos should be listed")

        let photo = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.photo."))
            .firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: launchTimeout))
        XCTAssertTrue(photo.isHittable, "The place's photos should be in view")
        // A sliver at the edge counts as hittable; the whole card must be visible
        // below the heading and inside the window.
        let window = app.windows.firstMatch.frame
        let frame = photo.frame
        XCTAssertGreaterThanOrEqual(frame.minY, chip.frame.maxY - 1, "The card is cut off at the top (card \(frame), chip \(chip.frame))")
        XCTAssertLessThanOrEqual(frame.maxY, window.maxY + 1, "The card is cut off at the bottom (card \(frame), window \(window))")
        capture(app, named: "trips-05-place-in-library-evidence")

        // Back returns to the chapter the place was clicked in, not to all
        // photos; once more, to the shelf; then there is nowhere to go back to.
        let back = element(in: app, identifier: "window.back")
        back.click()
        XCTAssertTrue(chip.waitForNonExistence(timeout: 5), "Back should leave the place")
        XCTAssertTrue(element(in: app, identifier: "trips.memory.trip").waitForExistence(timeout: launchTimeout), "Back did not return to the chapter the place was clicked in")
        capture(app, named: "trips-06-back-to-chapter-evidence")
        app.typeKey("[", modifierFlags: .command)
        XCTAssertTrue(card.waitForExistence(timeout: launchTimeout), "Command-[ did not return from the chapter to the shelf")
        XCTAssertTrue(back.waitForNonExistence(timeout: launchTimeout), "The shelf has nothing to go back to, yet shows Back")

        // The Library is where it was: every photo.
        element(in: app, identifier: "sidebar.library").click()
        XCTAssertTrue(element(in: app, identifier: "library.photoCount").waitForExistence(timeout: launchTimeout))
        XCTAssertFalse(chip.exists, "The place's photos stayed in the Library")
        XCTAssertEqual(libraryPhotoCount(app), allCount)
    }

    /// A link in the open photo's column leads elsewhere; Back returns to
    /// that photo, open as it was, and the next Back closes it.
    func testBackReopensThePhotoALinkWasClickedIn() {
        let app = launch(language: "en")
        let allCount = libraryPhotoCount(app)
        let first = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.photo.")).element(boundBy: 0)
        XCTAssertTrue(first.waitForExistence(timeout: launchTimeout))
        first.doubleClick()
        let viewer = element(in: app, identifier: "viewer")
        XCTAssertTrue(viewer.waitForExistence(timeout: launchTimeout))
        // The first photo with a place name has the link to the photos taken
        // there. Not the column's scroll view, which also answers to it; a
        // link-styled button may be reported as a link rather than a button.
        let scrollViewType: NSNumber = NSNumber(value: XCUIElement.ElementType.scrollView.rawValue)
        let linkQuery: NSPredicate = NSPredicate(format: "identifier == %@ AND elementType != %@", "viewer.place.photos", scrollViewType)
        let link = app.descendants(matching: .any).matching(linkQuery).firstMatch
        let next = element(in: app, identifier: "viewer.next")
        var found: Bool = link.waitForExistence(timeout: 3)
        for _ in 0..<15 where !found {
            guard next.isEnabled else { break }
            next.click()
            found = link.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(found, "No synthetic photo has a place name")
        let counter = element(in: app, identifier: "viewer.counter")
        let openedAt: String = (counter.value as? String) ?? ""
        link.click()
        let heading = element(in: app, identifier: "library.scope")
        XCTAssertTrue(heading.waitForExistence(timeout: launchTimeout), "The link did not show the photos taken there")
        XCTAssertTrue(viewer.waitForNonExistence(timeout: launchTimeout), "The viewer stayed open over the place's photos")
        capture(app, named: "back-01-place-from-viewer-evidence")

        let back = element(in: app, identifier: "window.back")
        XCTAssertTrue(back.waitForExistence(timeout: launchTimeout), "The place's photos have no Back")
        back.click()
        XCTAssertTrue(viewer.waitForExistence(timeout: launchTimeout), "Back did not reopen the photo the link was clicked in")
        XCTAssertTrue(heading.waitForNonExistence(timeout: launchTimeout), "Back did not leave the place's photos")
        XCTAssertEqual(counter.value as? String, openedAt, "Back reopened another photo")
        capture(app, named: "back-02-photo-reopened-evidence")

        app.typeKey("[", modifierFlags: .command)
        XCTAssertTrue(viewer.waitForNonExistence(timeout: launchTimeout), "Command-[ did not close the photo")
        XCTAssertTrue(back.waitForNonExistence(timeout: launchTimeout), "All photos have nothing to go back to, yet show Back")
        XCTAssertEqual(libraryPhotoCount(app), allCount)
    }

    /// Leaving the large map removes its map view, so MapKit stops drawing
    /// frames while you browse the Library or Chapters.
    func testMapViewIsReleasedAfterLeavingTheMap() {
        let app = launch(language: "en", mapProbe: true)
        let probe = element(in: app, identifier: "debug.mapviews")
        XCTAssertTrue(probe.waitForExistence(timeout: launchTimeout))
        XCTAssertEqual(probe.label, "mapviews=0")
        let onMap = NSPredicate(format: "label != %@", "mapviews=0")
        let gone = NSPredicate(format: "label == %@", "mapviews=0")
        // Back, and a click on either page in the sidebar, all leave the map.
        for exit in ["window.back", "sidebar.library", "sidebar.trips"] {
            openLargeMap(app)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: onMap, evaluatedWith: probe)], timeout: 10), .completed, "The probe found no map view on the large map")
            element(in: app, identifier: exit).click()
            XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: gone, evaluatedWith: probe)], timeout: 5), .completed, "A map view is still alive after \(exit): \(probe.label)")
            XCTAssertTrue(element(in: app, identifier: "map.view").waitForNonExistence(timeout: launchTimeout), "\(exit) did not leave the large map")
        }
    }

    /// "Zoom to photos" and "Whole world" move the camera evenly through the
    /// zoom levels: slow at the start, fastest in the middle, slow at the end,
    /// instead of saving most of the zoom for one jump at the end (or start).
    /// The old SwiftUI animation measured this way did 62 % of the zoom in
    /// the last 15 % of "Zoom to photos" and 58 % in the first 15 % of
    /// "Whole world".
    func testMapButtonsZoomSmoothly() {
        // The runner has Reduce Motion on, which jumps; the move is measured.
        let arguments: [String] = ["-MomentsUITestCameraProbe", "-MomentsUITestForceMotion"]
        let app = launch(language: "en", extraArguments: arguments)
        openLargeMap(app)
        let probe = element(in: app, identifier: "debug.cameraTrace")
        XCTAssertTrue(probe.waitForExistence(timeout: launchTimeout), "The camera probe is missing")
        let fit = element(in: app, identifier: "map.fit")
        XCTAssertTrue(fit.waitForExistence(timeout: launchTimeout))
        // The globe settles and the photos are clustered first.
        Thread.sleep(forTimeInterval: 2.0)

        fit.click()
        let zoomIn: [CameraSample] = cameraTrace(probe, press: 1)
        checkSmoothZoom(zoomIn, named: "zoom to photos")
        capture(app, named: "map-camera-01-photos-evidence")

        element(in: app, identifier: "map.globe").click()
        let zoomOut: [CameraSample] = cameraTrace(probe, press: 2)
        checkSmoothZoom(zoomOut, named: "whole world")
        capture(app, named: "map-camera-02-globe-evidence")
    }

    private struct CameraSample {
        let time: Double
        let distance: Double
    }

    /// Waits for the move after button press `press` to finish, then reads
    /// the camera distances MapKit reported during it.
    private func cameraTrace(_ probe: XCUIElement, press: Int) -> [CameraSample] {
        let prefix: String = "trace#\(press)="
        let started = NSPredicate(format: "label BEGINSWITH %@", prefix)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: started, evaluatedWith: probe)], timeout: 5), .completed, "Press \(press) left no camera trace: \(probe.label)")
        // Longer than any move, plus the probe's quarter-second refresh.
        Thread.sleep(forTimeInterval: 3.0)
        let label: String = probe.label
        let body: Substring = label.dropFirst(prefix.count).prefix { character in
            character != "|"
        }
        let samples: [CameraSample] = body.split(separator: ",").compactMap { entry in
            let parts: [Substring] = entry.split(separator: ":")
            guard parts.count == 2, let milliseconds = Double(parts[0]), let distance = Double(parts[1]), distance > 0 else { return nil }
            return CameraSample(time: milliseconds / 1000, distance: distance)
        }
        print("CAMERA-TRACE press \(press): \(label)")
        return samples
    }

    /// The share of the whole zoom (in zoom levels, not metres) done in the
    /// first and last 15 % of the move must be small, and the move must be
    /// animated, not a cut.
    private func checkSmoothZoom(_ samples: [CameraSample], named name: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let first = samples.first, let last = samples.last, samples.count >= 2 else {
            XCTFail("\(name): too few camera reports (\(samples.count))", file: file, line: line)
            return
        }
        let total: Double = Foundation.log(last.distance / first.distance)
        // The move ends when the distance is within 1 % of where it stopped.
        let endIndex: Int = samples.firstIndex { sample in
            abs(Foundation.log(sample.distance / last.distance)) < 0.01
        } ?? samples.count - 1
        let moving: Int = endIndex
        let end: Double = samples[endIndex].time
        var startShare: Double = 1
        var endShare: Double = 1
        if endIndex >= 1, abs(total) > 0 {
            startShare = Foundation.log(logDistance(samples, at: end * 0.15) / first.distance) / total
            endShare = Foundation.log(last.distance / logDistance(samples, at: end * 0.85)) / total
        }
        print("CAMERA-TRACE \(name): \(moving) reports in \(String(format: "%.2f", end)) s, first 15 % of the time did \(Int((startShare * 100).rounded())) %, last 15 % did \(Int((endShare * 100).rounded())) % of the zoom")
        XCTAssertGreaterThan(abs(total), Foundation.log(4.0), "\(name): the camera barely zoomed (\(first.distance) → \(last.distance) m)", file: file, line: line)
        // Never a frame of the destination before the move, then back: the
        // zoom only goes one way.
        var progress: Double = 0
        for sample in samples {
            let next: Double = Foundation.log(sample.distance / first.distance) / total
            XCTAssertGreaterThan(next, progress - 0.05, "\(name): the zoom went back from \(Int(progress * 100)) % to \(Int(next * 100)) % at \(sample.time) s", file: file, line: line)
            progress = max(progress, next)
        }
        XCTAssertGreaterThanOrEqual(moving, 8, "\(name): only \(moving) camera reports during the move; it jumped instead of moving", file: file, line: line)
        XCTAssertGreaterThan(end, 0.3, "\(name): the move took only \(end) s", file: file, line: line)
        XCTAssertLessThan(startShare, 0.2, "\(name): the first 15 % of the move did \(Int(startShare * 100)) % of the zoom", file: file, line: line)
        XCTAssertLessThan(endShare, 0.2, "\(name): the last 15 % of the move did \(Int(endShare * 100)) % of the zoom", file: file, line: line)
    }

    /// The camera distance at `time`, read between the two reports around it
    /// evenly in zoom levels.
    private func logDistance(_ samples: [CameraSample], at time: Double) -> Double {
        guard let after = samples.firstIndex(where: { $0.time >= time }) else { return samples.last?.distance ?? 1 }
        guard after > 0 else { return samples[0].distance }
        let a: CameraSample = samples[after - 1]
        let b: CameraSample = samples[after]
        let span: Double = b.time - a.time
        let fraction: Double = span > 0 ? (time - a.time) / span : 1
        let logA: Double = Foundation.log(a.distance)
        let logB: Double = Foundation.log(b.distance)
        return exp(logA + (logB - logA) * fraction)
    }

    /// A country on the Map's globe lists its photos in the Library.
    func testMapCountryShowsItsPhotosInLibrary() {
        let app = launch(language: "en")
        let allCount = libraryPhotoCount(app)
        openLargeMap(app)
        let stats = element(in: app, identifier: "map.stats")
        XCTAssertTrue(stats.waitForExistence(timeout: 30), "The globe has no countries card")
        // The card has a Countries and a Cities half; each opens its own list.
        element(in: app, identifier: "map.stats.countries").click()
        let button = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "map.country.photos."))
            .firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: launchTimeout), "Country row has no photos button")
        button.click()
        XCTAssertTrue(element(in: app, identifier: "library.scope").waitForExistence(timeout: launchTimeout))
        let scopedCount = libraryPhotoCount(app)
        XCTAssertGreaterThan(scopedCount, 0)
        XCTAssertLessThanOrEqual(scopedCount, allCount)
        capture(app, named: "map-06-country-in-library-evidence")
    }

    private func libraryPhotoCount(_ app: XCUIApplication) -> Int {
        let count = element(in: app, identifier: "library.photoCount")
        XCTAssertTrue(count.waitForExistence(timeout: launchTimeout))
        // Let a regroup after a scope change publish its count.
        Thread.sleep(forTimeInterval: 0.5)
        return Int(count.value as? String ?? "") ?? -1
    }

    private func navigateAndCapture(_ app: XCUIApplication, prefix: String, settleMap: Bool) {
        let library = element(in: app, identifier: "sidebar.library")
        XCTAssertTrue(library.waitForExistence(timeout: launchTimeout))
        capture(app, named: "\(prefix)-01-library-evidence")

        openLargeMap(app)
        if settleMap { Thread.sleep(forTimeInterval: 2.0) }
        capture(app, named: "\(prefix)-02-map-globe-evidence")

        let fit = element(in: app, identifier: "map.fit")
        XCTAssertTrue(fit.waitForExistence(timeout: launchTimeout))
        fit.click()
        if settleMap { Thread.sleep(forTimeInterval: 2.0) }
        capture(app, named: "\(prefix)-03-map-places-evidence")
        element(in: app, identifier: "window.back").click()

        let trips = element(in: app, identifier: "sidebar.trips")
        XCTAssertTrue(trips.waitForExistence(timeout: launchTimeout))
        trips.click()
        // Locale-independent: a trip cover card proves the screen rendered.
        let tripCard = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "trips.card."))
            .firstMatch
        XCTAssertTrue(tripCard.waitForExistence(timeout: launchTimeout))
        capture(app, named: "\(prefix)-05-trips-evidence")

        // One trip, by day and place.
        tripCard.click()
        let tripMemory = element(in: app, identifier: "trips.memory.trip")
        XCTAssertTrue(tripMemory.waitForExistence(timeout: launchTimeout))
        capture(app, named: "\(prefix)-06-trip-evidence")
        element(in: app, identifier: "trips.dates").click()
        XCTAssertTrue(element(in: app, identifier: "trips.dates.start").waitForExistence(timeout: launchTimeout), "The trip's dates cannot be changed")
        capture(app, named: "\(prefix)-07-trip-dates-evidence")
        app.typeKey(.escape, modifierFlags: [])
        element(in: app, identifier: "window.back").click()
    }

    private func launch(language: String, darkMode: Bool = false, smallWindow: Bool = false, mapProbe: Bool = false, extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-MomentsUITesting", "-AppleLanguages", "(\(language))", "-AppleLocale", language] + extraArguments
        if mapProbe { app.launchArguments += ["-MomentsUITestMapProbe"] }
        if darkMode { app.launchArguments += ["-MomentsUITestDarkMode"] }
        if smallWindow { app.launchArguments += ["-MomentsUITestSmallWindow"] }
        // No window-state arguments: with -MomentsUITesting, both
        // -ApplePersistenceIgnoreState and -NSQuitAlwaysKeepsWindows left
        // SwiftUI's WindowGroup without its initial window on CI.
        app.launch()
        app.activate()
        requireFrontmostWindow(app)
        return app
    }

    /// Fails the test (and, with continueAfterFailure off, stops it) unless
    /// Moments is the frontmost app with a hittable window.
    private func requireFrontmostWindow(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: launchTimeout), "Moments is not the frontmost app", file: file, line: line)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: launchTimeout), "Moments opened no window", file: file, line: line)
        XCTAssertTrue(window.isHittable, "The Moments window is covered or off screen", file: file, line: line)
    }

    private func assertWindowRendersLight(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let image = app.windows.firstMatch.screenshot().image
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            XCTFail("Could not read the window screenshot", file: file, line: line)
            return
        }
        // Average luminance on a 32x32 downsample; the light paper design sits well above 0.6.
        let size = 32
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let context = CGContext(data: &pixels, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
        var total = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            total += 0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1]) + 0.0722 * Double(pixels[index + 2])
        }
        let luminance = total / Double(size * size) / 255
        XCTAssertGreaterThan(luminance, 0.6, "The window rendered dark (luminance \(luminance)) while the app is light only", file: file, line: line)
    }

    private func element(in app: XCUIApplication, identifier: String) -> XCUIElement {
        XCTAssertEqual(app.state, .runningForeground, "Moments lost focus; stopping before clicking another app")
        return app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// The Filter popover, opened by its toolbar button unless it is open.
    private func openFilters(_ app: XCUIApplication, _ button: XCUIElement) -> XCUIElement {
        let popover = app.popovers.firstMatch
        if !popover.exists { button.click() }
        XCTAssertTrue(popover.waitForExistence(timeout: launchTimeout), "Filter did not open the chips")
        return popover
    }

    private func capture(_ app: XCUIApplication, named name: String) {
        // Capture only the app window, never the rest of the desktop.
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
