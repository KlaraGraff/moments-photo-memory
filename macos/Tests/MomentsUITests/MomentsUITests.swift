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

    func testNoteIsSavedWhenLeavingTheField() {
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

        // The ruled line under each photo is the note field. Like a caption in
        // Photos, leaving the field (here: clicking the sidebar) saves it.
        let note = element(in: app, identifier: "library.note.\(photoID)")
        XCTAssertTrue(note.waitForExistence(timeout: launchTimeout))
        let text = "UI smoke note \(UUID().uuidString)"
        note.click()
        note.typeText(text)

        for destination in ["sidebar.map", "sidebar.timeline", "sidebar.people", "sidebar.library"] {
            let item = element(in: app, identifier: destination)
            XCTAssertTrue(item.waitForExistence(timeout: launchTimeout), "Missing sidebar item \(destination)")
            item.click()
        }

        XCTAssertTrue(note.waitForExistence(timeout: launchTimeout))
        let badge = element(in: app, identifier: "library.note.badge.\(photoID)")
        XCTAssertTrue(badge.waitForExistence(timeout: launchTimeout), "Leaving the field did not save the note")
        XCTAssertFalse((note.value as? String ?? "").contains(text), "The note line was not cleared after saving")
        capture(app, named: "library-02-memory-persisted")
    }

    func testSavingANoteKeepsTheWordsUnderThePhoto() {
        let app = launch(language: "en")
        let photo = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.photo."))
            .firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: launchTimeout))
        let photoID = String(photo.identifier.dropFirst("library.photo.".count))

        let note = element(in: app, identifier: "library.note.\(photoID)")
        XCTAssertTrue(note.waitForExistence(timeout: launchTimeout))
        note.click()
        note.typeText("Synthetic note about this spot\r")

        // Return saves: the line clears and a mark appears on the place line.
        let badge = element(in: app, identifier: "library.note.badge.\(photoID)")
        XCTAssertTrue(badge.waitForExistence(timeout: launchTimeout), "Return did not save the note")
        XCTAssertFalse((note.value as? String ?? "").contains("Synthetic note"), "The note line was not cleared after saving")

        // Whatever model is available, the popover keeps the original words.
        badge.click()
        let original = app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "Synthetic note about this spot", "Synthetic note about this spot")).firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: launchTimeout), "The popover did not show the original words")
        capture(app, named: "library-03-note-saved")
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

        // The column edits in place: type over the place, adjust the date.
        // By type: the column's scroll view also answers to its children's identifiers.
        let place = app.textFields["viewer.place"]
        XCTAssertTrue(place.waitForExistence(timeout: launchTimeout))
        // SwiftUI reports the field with its scroll view's frame, which has no
        // hit point; click the place line by its position under the date.
        let date = app.buttons["viewer.date"]
        date.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 1)).withOffset(CGVector(dx: 30, dy: 47)).click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText("Harbour cafe\r")
        expectation(for: NSPredicate(format: "value == %@", "Harbour cafe"), evaluatedWith: place)
        waitForExpectations(timeout: launchTimeout)
        date.click()
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

        // ⌘− twice: the dense grid has photos only, no note lines.
        let photoID = String(first.identifier.dropFirst("library.photo.".count))
        let note = element(in: app, identifier: "library.note.\(photoID)")
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

    /// Two clicks closer together than the double-click interval are a double click.
    private func pauseLongerThanADoubleClick() {
        RunLoop.current.run(until: Date().addingTimeInterval(NSEvent.doubleClickInterval + 0.3))
    }

    /// Opens the Map and zooms from the globe to the photos.
    private func openMapAtPhotos(_ app: XCUIApplication) -> XCUIElement {
        element(in: app, identifier: "sidebar.map").click()
        let map = element(in: app, identifier: "map.view")
        XCTAssertTrue(map.waitForExistence(timeout: 30))
        let fit = element(in: app, identifier: "map.fit")
        XCTAssertTrue(fit.waitForExistence(timeout: launchTimeout))
        // The fitted region needs the clustered snapshot; give it a moment.
        Thread.sleep(forTimeInterval: 1.0)
        fit.click()
        Thread.sleep(forTimeInterval: 2.0)
        return map
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

    /// The AI model settings are reachable from the sidebar, not only via ⌘,.
    func testSidebarOpensAIModelSettings() {
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
        XCTAssertGreaterThan(app.windows.count, windowsBefore, "The AI model settings window did not open")
        capture(app, named: "settings-01-from-sidebar-evidence")
        app.typeKey("w", modifierFlags: .command)
    }

    func testFootprintsGlobeOpens() {
        let app = launch(language: "en")
        assertGlobeFullyVisible(app, screenshot: "map-04-globe-evidence")
    }

    func testFootprintsGlobeFitsSmallWindow() {
        let app = launch(language: "en", smallWindow: true)
        assertGlobeFullyVisible(app, screenshot: "map-05-globe-small-window-evidence")
    }

    /// The globe sits on black space: scan the middle row and column of the
    /// map for the first and last bright pixels. A cropped globe touches the
    /// map's edges.
    private func assertGlobeFullyVisible(_ app: XCUIApplication, screenshot name: String, file: StaticString = #filePath, line: UInt = #line) {
        let mapRow = element(in: app, identifier: "sidebar.map")
        XCTAssertTrue(mapRow.waitForExistence(timeout: launchTimeout), file: file, line: line)
        mapRow.click()

        // The Map opens on the globe. The first MapKit globe of a test run
        // can take longer to appear.
        let globe = element(in: app, identifier: "map.view")
        XCTAssertTrue(globe.waitForExistence(timeout: 30), file: file, line: line)
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

    func testSidebarHasFourDestinations() {
        let app = launch(language: "en")
        for identifier in ["sidebar.library", "sidebar.people", "sidebar.map", "sidebar.timeline"] {
            XCTAssertTrue(element(in: app, identifier: identifier).waitForExistence(timeout: launchTimeout), "Missing \(identifier)")
        }
        for identifier in ["sidebar.review", "sidebar.places", "sidebar.footprints", "sidebar.import"] {
            XCTAssertFalse(element(in: app, identifier: identifier).exists, "\(identifier) should have left the sidebar")
        }
        // Without photos to confirm there is no banner.
        XCTAssertFalse(element(in: app, identifier: "library.review-banner").exists)

        let importButton = element(in: app, identifier: "toolbar.import")
        XCTAssertTrue(importButton.waitForExistence(timeout: launchTimeout), "The toolbar + import button is missing")
        importButton.click()
        // Scoped to the button: the File menu has the same two commands.
        XCTAssertTrue(importButton.menuItems["Import Folder…"].waitForExistence(timeout: launchTimeout), "The + button did not open its menu")
        XCTAssertTrue(importButton.menuItems["Import from Apple Photos…"].exists)
        capture(app, named: "toolbar-01-import-menu-evidence")
        app.typeKey(.escape, modifierFlags: [])
    }

    func testReviewBannerOpensTheReviewList() {
        let app = launch(language: "zh-Hans", reviewItems: true)
        let banner = element(in: app, identifier: "library.review-banner")
        XCTAssertTrue(banner.waitForExistence(timeout: launchTimeout), "Photos to confirm should show a banner in the Library")
        capture(app, named: "library-03-review-banner-evidence")
        banner.click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: launchTimeout), "The banner did not open the review list")
        Thread.sleep(forTimeInterval: 0.6)
        capture(app, named: "library-04-review-sheet-evidence")
        let done = element(in: app, identifier: "review.done")
        XCTAssertTrue(done.waitForExistence(timeout: launchTimeout))
        done.click()
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: launchTimeout))
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
        let back = element(in: app, identifier: "trips.back")
        XCTAssertTrue(back.waitForExistence(timeout: launchTimeout))
        back.click()
        XCTAssertTrue(card.waitForExistence(timeout: launchTimeout), "Back did not return to the trip cards")
        capture(app, named: "trips-04-shelf-with-memory-evidence")
    }

    func testTimelineShowsDaysAndLinksToTheirTrip() {
        let app = launch(language: "en")
        element(in: app, identifier: "sidebar.timeline").click()

        // Every photo by day, each day with its memory line.
        let dayLine = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "trips.memory.day."))
            .firstMatch
        XCTAssertTrue(dayLine.waitForExistence(timeout: launchTimeout), "Timeline days have no memory line")
        let photo = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "trips.photo.")).firstMatch
        XCTAssertTrue(photo.exists, "Timeline days show their photos")

        // A day inside a trip links to that trip.
        let tripLink = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "timeline.trip.")).firstMatch
        XCTAssertTrue(tripLink.waitForExistence(timeout: launchTimeout), "A trip day has no link to its trip")
        capture(app, named: "timeline-01-days-evidence")
        tripLink.click()
        XCTAssertTrue(element(in: app, identifier: "trips.memory.trip").waitForExistence(timeout: launchTimeout), "The trip link did not open the trip")
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

        let chip = element(in: app, identifier: "library.scope-chip")
        XCTAssertTrue(chip.waitForExistence(timeout: launchTimeout), "Library should show the place as a removable chip")
        let scopedCount = libraryPhotoCount(app)
        XCTAssertGreaterThan(scopedCount, 0)
        XCTAssertLessThan(scopedCount, allCount, "Only the place's photos should be listed")

        let photo = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.photo."))
            .firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: launchTimeout))
        XCTAssertTrue(photo.isHittable, "The place's photos should be in view")
        // A sliver at the edge counts as hittable; the whole card must be visible
        // below the filter chips and inside the window.
        let window = app.windows.firstMatch.frame
        let frame = photo.frame
        XCTAssertGreaterThanOrEqual(frame.minY, chip.frame.maxY - 1, "The card is cut off at the top (card \(frame), chip \(chip.frame))")
        XCTAssertLessThanOrEqual(frame.maxY, window.maxY + 1, "The card is cut off at the bottom (card \(frame), window \(window))")
        capture(app, named: "trips-05-place-in-library-evidence")

        chip.click()
        XCTAssertTrue(chip.waitForNonExistence(timeout: 5), "Clicking the chip should remove the scope")
        XCTAssertEqual(libraryPhotoCount(app), allCount)
    }

    /// The Map has the Library's filters, and a filter set there is set in
    /// the Library too.
    func testMapFiltersFollowTheLibrary() {
        let app = launch(language: "en")
        element(in: app, identifier: "sidebar.map").click()
        let filters = element(in: app, identifier: "map.filters")
        XCTAssertTrue(filters.waitForExistence(timeout: 30), "The Map has no filter bar")
        let trip = filters.menuButtons["Trip"].firstMatch
        XCTAssertTrue(trip.waitForExistence(timeout: launchTimeout))
        trip.click()
        let journey = app.menuItems["journeyA"].firstMatch
        XCTAssertTrue(journey.waitForExistence(timeout: launchTimeout))
        journey.click()
        Thread.sleep(forTimeInterval: 1.5)
        capture(app, named: "map-07-filtered-evidence")

        element(in: app, identifier: "sidebar.library").click()
        let chip = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "journeyA")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: launchTimeout), "The trip picked on the Map is not set in the Library")
        capture(app, named: "map-08-filter-in-library-evidence")
        chip.click()
    }

    /// Leaving the Map removes its map view, so MapKit stops drawing frames
    /// while you browse the Library or People.
    func testMapViewIsReleasedAfterLeavingTheMap() {
        let app = launch(language: "en", mapProbe: true)
        let probe = element(in: app, identifier: "debug.mapviews")
        XCTAssertTrue(probe.waitForExistence(timeout: launchTimeout))
        XCTAssertEqual(probe.label, "mapviews=0")
        element(in: app, identifier: "sidebar.map").click()
        XCTAssertTrue(element(in: app, identifier: "map.filters").waitForExistence(timeout: 30))
        let onMap = NSPredicate(format: "label != %@", "mapviews=0")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: onMap, evaluatedWith: probe)], timeout: 10), .completed, "The probe found no map view on the Map")
        for destination in ["sidebar.library", "sidebar.people", "sidebar.timeline"] {
            element(in: app, identifier: destination).click()
            let gone = NSPredicate(format: "label == %@", "mapviews=0")
            XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: gone, evaluatedWith: probe)], timeout: 5), .completed, "A map view is still alive on \(destination): \(probe.label)")
        }
    }

    /// A country on the Map's globe lists its photos in the Library.
    func testMapCountryShowsItsPhotosInLibrary() {
        let app = launch(language: "en")
        let allCount = libraryPhotoCount(app)
        element(in: app, identifier: "sidebar.map").click()
        let stats = element(in: app, identifier: "map.stats")
        XCTAssertTrue(stats.waitForExistence(timeout: 30), "The globe has no countries card")
        stats.click()
        let button = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "map.country.photos."))
            .firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: launchTimeout), "Country row has no photos button")
        button.click()
        XCTAssertTrue(element(in: app, identifier: "library.scope-chip").waitForExistence(timeout: launchTimeout))
        let scopedCount = libraryPhotoCount(app)
        XCTAssertGreaterThan(scopedCount, 0)
        XCTAssertLessThanOrEqual(scopedCount, allCount)
        capture(app, named: "map-06-country-in-library-evidence")
    }

    /// "Save as smart group" is offered only once a filter is set.
    /// The count beside the title never sits under the type picker, and the
    /// picker stays put while the count changes.
    func testLibraryCountNeitherOverlapsNorMovesThePicker() {
        let app = launch(language: "en")
        let picker = element(in: app, identifier: "library.type-filter")
        let count = element(in: app, identifier: "library.photoCount")
        XCTAssertTrue(picker.waitForExistence(timeout: launchTimeout))
        XCTAssertTrue(count.waitForExistence(timeout: launchTimeout))
        let before = picker.frame
        for segment in ["Videos", "Photos", "All"] {
            app.radioButtons[segment].firstMatch.click()
            Thread.sleep(forTimeInterval: 0.5)
            let after = picker.frame
            XCTAssertEqual(after.minX, before.minX, accuracy: 0.5, "The picker moved after choosing \(segment)")
            if abs(after.midY - count.frame.midY) < after.height {
                XCTAssertLessThanOrEqual(count.frame.maxX, after.minX, "The count runs under the picker after choosing \(segment)")
            }
        }
        // The header never makes the window's content wider than the window.
        let window = app.windows.firstMatch.frame
        let grouping = element(in: app, identifier: "library.grouping")
        XCTAssertLessThanOrEqual(grouping.frame.maxX, window.maxX + 0.5, "The header pushes past the window's right edge")
        XCTAssertGreaterThanOrEqual(element(in: app, identifier: "sidebar.library").frame.minX, window.minX - 0.5, "The sidebar was pushed off the window")
        capture(app, named: "library-05-header-evidence")
    }

    func testSmartGroupButtonOnlyWithFilter() {
        let app = launch(language: "en")
        XCTAssertTrue(element(in: app, identifier: "library.type-filter").waitForExistence(timeout: launchTimeout))
        XCTAssertFalse(element(in: app, identifier: "library.save-smart-group").exists)
        XCTAssertFalse(element(in: app, identifier: "library.add-filter").exists, "The dead Add filter stub is gone")
        app.radioButtons["Photos"].firstMatch.click()
        XCTAssertTrue(element(in: app, identifier: "library.save-smart-group").waitForExistence(timeout: launchTimeout))
        app.radioButtons["All"].firstMatch.click()
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

        let map = element(in: app, identifier: "sidebar.map")
        XCTAssertTrue(map.waitForExistence(timeout: launchTimeout))
        map.click()
        XCTAssertTrue(element(in: app, identifier: "map.view").waitForExistence(timeout: 30))
        if settleMap { Thread.sleep(forTimeInterval: 2.0) }
        capture(app, named: "\(prefix)-02-map-globe-evidence")

        let fit = element(in: app, identifier: "map.fit")
        XCTAssertTrue(fit.waitForExistence(timeout: launchTimeout))
        fit.click()
        if settleMap { Thread.sleep(forTimeInterval: 2.0) }
        capture(app, named: "\(prefix)-03-map-places-evidence")

        let timeline = element(in: app, identifier: "sidebar.timeline")
        XCTAssertTrue(timeline.waitForExistence(timeout: launchTimeout))
        timeline.click()
        // Locale-independent: a month header proves the screen rendered.
        let month = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "timeline.month."))
            .firstMatch
        XCTAssertTrue(month.waitForExistence(timeout: launchTimeout))
        capture(app, named: "\(prefix)-04-timeline-evidence")

        let trips = element(in: app, identifier: "sidebar.trips")
        XCTAssertTrue(trips.waitForExistence(timeout: launchTimeout))
        trips.click()
        // Locale-independent: a trip cover card proves the screen rendered.
        let tripCard = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "trips.card."))
            .firstMatch
        XCTAssertTrue(tripCard.waitForExistence(timeout: launchTimeout))
        capture(app, named: "\(prefix)-05-trips-evidence")
    }

    private func launch(language: String, darkMode: Bool = false, smallWindow: Bool = false, reviewItems: Bool = false, mapProbe: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-MomentsUITesting", "-AppleLanguages", "(\(language))", "-AppleLocale", language]
        if mapProbe { app.launchArguments += ["-MomentsUITestMapProbe"] }
        if reviewItems { app.launchArguments += ["-MomentsUITestReviewItems"] }
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

    private func capture(_ app: XCUIApplication, named name: String) {
        // Capture only the app window, never the rest of the desktop.
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
