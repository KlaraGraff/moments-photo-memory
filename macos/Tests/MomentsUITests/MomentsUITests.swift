import XCTest

final class MomentsUITests: XCTestCase {
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
        navigateAndCapture(app, prefix: "de-dark-small", settleMap: true)
    }

    func testMemorySurvivesSidebarNavigation() {
        let app = launch(language: "en")
        let library = element(in: app, identifier: "sidebar.library")
        XCTAssertTrue(library.waitForExistence(timeout: launchTimeout))

        let photo = element(in: app, identifier: "library.photo.D0001")
        XCTAssertTrue(photo.waitForExistence(timeout: launchTimeout))
        photo.click()

        let memory = element(in: app, identifier: "library.memory.D0001")
        XCTAssertTrue(memory.waitForExistence(timeout: launchTimeout))
        let text = "UI smoke memory \(UUID().uuidString)"
        memory.click()
        memory.typeKey("a", modifierFlags: .command)
        memory.typeText(text)

        for destination in ["sidebar.places", "sidebar.timeline", "sidebar.footprints", "sidebar.library"] {
            let item = element(in: app, identifier: destination)
            XCTAssertTrue(item.waitForExistence(timeout: launchTimeout), "Missing sidebar item \(destination)")
            item.click()
        }

        XCTAssertTrue(memory.waitForExistence(timeout: launchTimeout))
        let value = memory.value as? String ?? ""
        XCTAssertTrue(value.contains(text), "Memory field did not retain the typed text")
        capture(app, named: "library-02-memory-persisted")
    }

    func testPlacesMapHasSyntheticAnnotation() {
        let app = launch(language: "en")
        element(in: app, identifier: "sidebar.places").click()

        let map = element(in: app, identifier: "places.map")
        XCTAssertTrue(map.waitForExistence(timeout: launchTimeout))
        let annotation = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "places.annotation."))
            .firstMatch
        XCTAssertTrue(annotation.waitForExistence(timeout: launchTimeout), "Synthetic place annotation was not exposed")
        capture(app, named: "places-01-map-and-pin")
    }

    func testFootprintsGlobeOpens() {
        let app = launch(language: "en")
        let footprints = element(in: app, identifier: "sidebar.footprints")
        XCTAssertTrue(footprints.waitForExistence(timeout: launchTimeout))
        footprints.click()

        // The first MapKit globe of a test run can take longer to appear.
        let globe = element(in: app, identifier: "footprints.globe")
        XCTAssertTrue(globe.waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 1.0)
        capture(app, named: "footprints-01-globe")
    }

    func testTimelinePlaceSelectsLibraryItem() {
        let app = launch(language: "en")
        element(in: app, identifier: "sidebar.timeline").click()

        let place = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "timeline.place.")).firstMatch
        XCTAssertTrue(place.waitForExistence(timeout: launchTimeout), "Timeline place row was not exposed")
        place.click()

        let selectedPhoto = element(in: app, identifier: "library.photo.D0001")
        XCTAssertTrue(selectedPhoto.waitForExistence(timeout: launchTimeout))
        XCTAssertEqual(selectedPhoto.value as? String, "Selected")
        XCTAssertTrue(selectedPhoto.isHittable, "Timeline jump should scroll the selected Library card into view")
        capture(app, named: "timeline-01-place-selected-in-library")
    }

    private func navigateAndCapture(_ app: XCUIApplication, prefix: String, settleMap: Bool) {
        let library = element(in: app, identifier: "sidebar.library")
        XCTAssertTrue(library.waitForExistence(timeout: launchTimeout))
        capture(app, named: "\(prefix)-01-library")

        let places = element(in: app, identifier: "sidebar.places")
        XCTAssertTrue(places.waitForExistence(timeout: launchTimeout))
        places.click()
        XCTAssertTrue(element(in: app, identifier: "places.map").waitForExistence(timeout: launchTimeout))
        if settleMap { Thread.sleep(forTimeInterval: 1.0) }
        capture(app, named: "\(prefix)-02-places")

        let footprints = element(in: app, identifier: "sidebar.footprints")
        XCTAssertTrue(footprints.waitForExistence(timeout: launchTimeout))
        footprints.click()
        XCTAssertTrue(element(in: app, identifier: "footprints.globe").waitForExistence(timeout: launchTimeout))
        if settleMap { Thread.sleep(forTimeInterval: 1.0) }
        capture(app, named: "\(prefix)-03-footprints")

        let timeline = element(in: app, identifier: "sidebar.timeline")
        XCTAssertTrue(timeline.waitForExistence(timeout: launchTimeout))
        timeline.click()
        // Locale-independent: a timeline place row proves the screen rendered.
        let placeRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "timeline.place."))
            .firstMatch
        XCTAssertTrue(placeRow.waitForExistence(timeout: launchTimeout))
        capture(app, named: "\(prefix)-04-timeline")
    }

    private func launch(language: String, darkMode: Bool = false, smallWindow: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-MomentsUITesting", "-AppleLanguages", "(\(language))", "-AppleLocale", language]
        if darkMode { app.launchArguments += ["-MomentsUITestDarkMode"] }
        if smallWindow { app.launchArguments += ["-MomentsUITestSmallWindow"] }
        // Ignore saved window state so a previous run that closed its window
        // cannot leave the app running without one.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        app.activate()
        let window = app.windows.firstMatch
        if !window.waitForExistence(timeout: launchTimeout) {
            app.typeKey("n", modifierFlags: .command)
            XCTAssertTrue(window.waitForExistence(timeout: launchTimeout), "Moments opened no window")
        }
        return app
    }

    private func element(in app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func capture(_ app: XCUIApplication, named name: String) {
        // Capture only the app window, never the rest of the desktop.
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
