import XCTest

/// A save that fails is never silent: the strip at the bottom of the window
/// says so, what was typed stays on screen, and Try Again saves it. And
/// Settings says which version this is.
final class MomentsSaveProblemUITests: XCTestCase {
    private let launchTimeout: TimeInterval = 30

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testAFailedRenameShowsTheStripKeepsTheNameAndTryAgainSaves() {
        // The first save made by the in-place chapter title fails.
        let app = launch(extraArguments: ["-MomentsUITestFailSaveIn", "EditableTripTitle.swift"])
        let title = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "trip.title."))
            .firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: launchTimeout), "The Library has no chapter title")
        let tripID = String(title.identifier.dropFirst("trip.title.".count))
        title.doubleClick()
        let field = element(in: app, identifier: "trip.rename.\(tripID)")
        XCTAssertTrue(field.waitForExistence(timeout: launchTimeout), "Double-click did not start renaming")
        field.typeKey("a", modifierFlags: .command)
        field.typeText("Synthetic unsaved title\r")

        let strip = element(in: app, identifier: "save.problem")
        XCTAssertTrue(strip.waitForExistence(timeout: launchTimeout), "A failed save showed nothing")
        // What was typed is still there.
        let renamed = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND (label CONTAINS %@ OR value CONTAINS %@)", "trip.title.\(tripID)", "Synthetic unsaved title", "Synthetic unsaved title"))
            .firstMatch
        XCTAssertTrue(renamed.waitForExistence(timeout: launchTimeout), "The new name was lost when saving failed")
        capture(app, named: "save-problem-01-strip")

        element(in: app, identifier: "save.problem.retry").click()
        XCTAssertTrue(waitForDisappearance(strip), "Try Again did not save")
        XCTAssertTrue(renamed.exists, "The name went after saving")
    }

    func testAFailedMemoryStaysInItsFieldAndTryAgainSavesIt() {
        // The first save of a memory under a photo fails.
        let app = launch(extraArguments: ["-MomentsUITestFailSaveIn", "LibraryView.swift"])
        let photo = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.photo."))
            .firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: launchTimeout), "The Library has no photo")
        let photoID = String(photo.identifier.dropFirst("library.photo.".count))
        let memory = element(in: app, identifier: "library.memory.\(photoID)")
        XCTAssertTrue(memory.waitForExistence(timeout: launchTimeout))
        memory.click()
        memory.typeText("Synthetic unsaved memory\r")

        let strip = element(in: app, identifier: "save.problem")
        XCTAssertTrue(strip.waitForExistence(timeout: launchTimeout), "A failed save showed nothing")
        XCTAssertTrue((memory.value as? String ?? "").contains("Synthetic unsaved memory"), "The memory was lost when saving failed")
        capture(app, named: "save-problem-03-memory")

        element(in: app, identifier: "save.problem.retry").click()
        XCTAssertTrue(waitForDisappearance(strip), "Try Again did not save")
        XCTAssertTrue((memory.value as? String ?? "").contains("Synthetic unsaved memory"), "The memory went after saving")
    }

    func testTheStripCanBeClosed() {
        let app = launch(extraArguments: ["-MomentsUITestFailSaveIn", "EditableTripTitle.swift"])
        let title = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "trip.title."))
            .firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: launchTimeout))
        let tripID = String(title.identifier.dropFirst("trip.title.".count))
        title.doubleClick()
        let field = element(in: app, identifier: "trip.rename.\(tripID)")
        XCTAssertTrue(field.waitForExistence(timeout: launchTimeout))
        field.typeKey("a", modifierFlags: .command)
        field.typeText("Synthetic closed notice\r")
        let strip = element(in: app, identifier: "save.problem")
        XCTAssertTrue(strip.waitForExistence(timeout: launchTimeout))
        element(in: app, identifier: "save.problem.close").click()
        XCTAssertTrue(waitForDisappearance(strip), "Close left the strip")
    }

    func testSettingsShowsTheVersionAndDiagnostics() {
        let app = launch(extraArguments: [])
        app.typeKey(",", modifierFlags: .command)
        let version = element(in: app, identifier: "settings.about-version")
        // The last section: scroll Settings down to it.
        let page = element(in: app, identifier: "settings.page")
        XCTAssertTrue(page.waitForExistence(timeout: launchTimeout), "Settings did not open")
        // A lazy list may not have built the last section yet: scroll until
        // it exists and can be clicked.
        for _ in 0..<8 where !(version.exists && version.isHittable) {
            page.scroll(byDeltaX: 0, deltaY: -400)
        }
        XCTAssertTrue(version.waitForExistence(timeout: launchTimeout), "Settings has no version")
        let text = (version.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? version.label
        XCTAssertTrue(text.contains("Version"), "Unexpected version text: \(text)")
        XCTAssertTrue(element(in: app, identifier: "settings.about-export-diagnostics").exists, "No Export Diagnostics button")
        XCTAssertTrue(element(in: app, identifier: "settings.about-show-library").exists, "No Show in Finder button")
        capture(app, named: "save-problem-02-settings-about")
    }

    // MARK: Helpers

    private func launch(extraArguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-MomentsUITesting", "-AppleLanguages", "(en)", "-AppleLocale", "en"] + extraArguments
        app.launch()
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: launchTimeout), "Moments is not the frontmost app")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: launchTimeout), "Moments opened no window")
        return app
    }

    private func element(in app: XCUIApplication, identifier: String) -> XCUIElement {
        XCTAssertEqual(app.state, .runningForeground, "Moments lost focus; stopping before clicking another app")
        return app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func waitForDisappearance(_ element: XCUIElement) -> Bool {
        let gone = NSPredicate(format: "exists == false")
        return XCTWaiter().wait(for: [expectation(for: gone, evaluatedWith: element)], timeout: launchTimeout) == .completed
    }

    private func capture(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
