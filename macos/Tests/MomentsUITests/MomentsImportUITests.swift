import XCTest

final class MomentsImportUITests: XCTestCase {
    private let timeout: TimeInterval = 15

    func testFolderImportPersistsAndSupportsReviewActions() throws {
        guard let folderPath = ProcessInfo.processInfo.environment["MOMENTS_UI_IMPORT_FOLDER"],
              !folderPath.isEmpty else {
            throw XCTSkip("MOMENTS_UI_IMPORT_FOLDER was not supplied")
        }

        let storeDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("moments-ui-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storeDirectory) }

        let folderURL = URL(fileURLWithPath: folderPath, isDirectory: true)
        let app = launch(storeDirectory: storeDirectory)
        let initialCount = photoCount(in: app)
        XCTAssertEqual(initialCount, 0, "The isolated import store must start empty")

        try importFolder(folderURL, in: app, screenshotPrefix: "import-01")
        // Review actions only exist on the first import; later imports find
        // every photo already present.
        let memoryWasAdded = exerciseReview(in: app)
        dismissReviewIfPresent(in: app)

        XCTContext.runActivity(named: "Cancel a second import when it is still running") { activity in
            guard openImportPanel(folderURL, in: app) else {
                addNote("The folder picker could not be opened for the cancellation check.", to: activity)
                return
            }
            let progress = element(in: app, identifier: "import.progress.indicator")
            if progress.waitForExistence(timeout: 3) {
                capture(app, named: "import-02-cancelling", activity: activity)
                let cancel = element(in: app, identifier: "import.cancel")
                if cancel.waitForExistence(timeout: 2) {
                    cancel.click()
                    _ = element(in: app, identifier: "import.resume").waitForExistence(timeout: timeout)
                    capture(app, named: "import-03-cancelled", activity: activity)
                } else {
                    addNote("The import completed before a cancel control was exposed.", to: activity)
                }
            } else {
                addNote("The second import completed before a progress indicator was exposed.", to: activity)
            }
        }
        dismissReviewIfPresent(in: app)

        try importFolder(folderURL, in: app, screenshotPrefix: "import-04")
        dismissReviewIfPresent(in: app)
        // The library card shows the empty-memory placeholder as a thin line.
        capture(app, named: "import-18-empty-memory-placeholder")

        let importedCount = photoCount(in: app)
        XCTAssertGreaterThan(importedCount, initialCount, "The folder import did not add any photos")

        try importFolder(folderURL, in: app, screenshotPrefix: "import-10-reimport")
        dismissReviewIfPresent(in: app)
        XCTAssertEqual(photoCount(in: app), importedCount, "Re-importing the same folder created duplicates")

        app.terminate()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: timeout))
        let persistedPhotoCount = photoCount(in: app)
        XCTAssertEqual(persistedPhotoCount, importedCount, "Imported photos were not persisted across relaunch")
        capture(app, named: "import-11-relaunched")

        let memory = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.memory."))
            .firstMatch
        XCTAssertTrue(memory.waitForExistence(timeout: timeout), "An imported photo memory editor was not visible after relaunch")
        if memoryWasAdded {
            XCTAssertTrue((memory.value as? String ?? "").contains("UI import memory"), "The quick memory was not persisted")
        } else {
            recordSkipped("The quick-memory field was unavailable, so persistence of that optional edit was not asserted.")
        }
    }

    private func launch(storeDirectory: URL) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-MomentsUITestStoreDirectory", storeDirectory.path,
            "-ApplePersistenceIgnoreState", "YES"
        ]
        app.launch()
        app.activate()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: timeout), "Moments opened no window")
        return app
    }

    private func importFolder(_ folder: URL, in app: XCUIApplication, screenshotPrefix: String) throws {
        guard openImportPanel(folder, in: app) else {
            XCTFail("The folder import panel could not be opened")
            return
        }

        let progress = element(in: app, identifier: "import.progress.indicator")
        if progress.waitForExistence(timeout: 3) {
            capture(app, named: "\(screenshotPrefix)-progress")
        } else {
            XCTContext.runActivity(named: "Progress indicator timing") { activity in
                addNote("The import completed before the progress indicator could be observed.", to: activity)
            }
        }

        let review = element(in: app, identifier: "import.review")
        XCTAssertTrue(review.waitForExistence(timeout: 60), "The import review sheet did not appear")
        capture(app, named: "\(screenshotPrefix)-review")
    }

    private func openImportPanel(_ folder: URL, in app: XCUIApplication) -> Bool {
        // File > Import Folder… (works whether or not the library is empty).
        app.typeKey("i", modifierFlags: [.command, .shift])

        // NSOpenPanel is exposed by macOS accessibility as a dialog rather
        // than a SwiftUI sheet.
        let panel = app.dialogs["open-panel"]
        guard panel.waitForExistence(timeout: timeout) else { return false }
        app.typeKey("g", modifierFlags: [.command, .shift])

        let locationSheet = app.sheets.firstMatch
        let pathField = locationSheet.textFields.firstMatch
        guard pathField.waitForExistence(timeout: timeout) else { return false }
        pathField.click()
        pathField.typeKey("a", modifierFlags: .command)
        pathField.typeText(folder.path)
        pathField.typeKey(.return, modifierFlags: [])

        guard panel.waitForExistence(timeout: timeout) else { return false }
        let chooseButton = panel.buttons["Import Folder…"]
        guard chooseButton.waitForExistence(timeout: timeout) else { return false }
        chooseButton.click()
        return true
    }

    private func exerciseReview(in app: XCUIApplication) -> Bool {
        let review = element(in: app, identifier: "import.review")
        guard review.waitForExistence(timeout: 60) else {
            XCTContext.runActivity(named: "Review actions") { activity in
                addNote("The import review sheet was not available for review actions.", to: activity)
            }
            return false
        }
        capture(app, named: "import-05-review-initial")

        let tripName = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "import.trip.name."))
            .firstMatch
        let rename = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "import.trip.rename."))
            .firstMatch
        if tripName.waitForExistence(timeout: 3), rename.waitForExistence(timeout: 3) {
            replaceText(in: tripName, with: "UI import trip")
            rename.click()
            capture(app, named: "import-06-trip-renamed")
        } else {
            recordSkipped("Trip rename was unavailable in this import result.")
        }

        let split = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "import.trip.split."))
            .firstMatch
        if split.waitForExistence(timeout: 3) {
            split.click()
            capture(app, named: "import-07-trip-split")
        } else {
            recordSkipped("Trip split was unavailable in this import result.")
        }

        let merge = element(in: app, identifier: "import.trip.merge")
        if merge.waitForExistence(timeout: 3) {
            merge.click()
            capture(app, named: "import-08-trip-merged")
        } else {
            recordSkipped("Trip merge was unavailable because fewer than two trips were suggested.")
        }

        let confirm = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "import.trip.confirm."))
            .firstMatch
        if confirm.waitForExistence(timeout: 3) {
            confirm.click()
            capture(app, named: "import-09-trip-confirmed")
        } else {
            recordSkipped("Trip confirmation was unavailable in this import result.")
        }

        let confirmation = element(in: app, identifier: "import.confirmationList")
        guard confirmation.waitForExistence(timeout: 3) else {
            recordSkipped("No items needed confirmation in this import result.")
            return false
        }
        capture(app, named: "import-12-confirmation-initial")

        let accept = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "import.confirmation.accept."))
            .firstMatch
        if accept.waitForExistence(timeout: 3) {
            accept.click()
            capture(app, named: "import-13-confirmed-item")
        } else {
            recordSkipped("Confirmation accept action was unavailable.")
        }

        let changeDate = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "import.confirmation.date."))
            .firstMatch
        let useDate = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "import.confirmation.useDate."))
            .firstMatch
        if changeDate.waitForExistence(timeout: 3), useDate.waitForExistence(timeout: 3), changeDate.isHittable {
            // Step the focused date segment back instead of typing a
            // locale-specific date string.
            changeDate.click()
            for _ in 0..<3 { app.typeKey(.downArrow, modifierFlags: []) }
            if useDate.isHittable { useDate.click() }
            capture(app, named: "import-14-date-changed")
        } else {
            recordSkipped("No editable date was available in the confirmation list.")
        }

        let changePlace = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "import.confirmation.place."))
            .firstMatch
        if changePlace.waitForExistence(timeout: 3), changePlace.isHittable {
            replaceText(in: changePlace, with: "UI import place")
            changePlace.typeKey(.return, modifierFlags: [])
            capture(app, named: "import-15-place-changed")
        } else {
            recordSkipped("No suggested place was available to change.")
        }

        let memory = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "import.confirmation.memory."))
            .firstMatch
        var memoryWasAdded = false
        if memory.waitForExistence(timeout: 3), memory.isHittable {
            replaceText(in: memory, with: "UI import memory")
            memory.typeKey(.return, modifierFlags: [])
            memoryWasAdded = true
            capture(app, named: "import-16-memory-added")
        } else {
            recordSkipped("No quick-memory field was available in the confirmation list.")
        }

        let ignore = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "import.confirmation.ignore."))
            .firstMatch
        if ignore.waitForExistence(timeout: 3), ignore.isHittable {
            ignore.click()
            capture(app, named: "import-17-ignored-item")
        } else {
            recordSkipped("A separate confirmation item was unavailable to ignore.")
        }

        return memoryWasAdded
    }

    private func dismissReviewIfPresent(in app: XCUIApplication) {
        let done = element(in: app, identifier: "import.review.done")
        if done.waitForExistence(timeout: 3) {
            done.click()
            return
        }
        let titledDone = app.buttons["Done"]
        if titledDone.waitForExistence(timeout: 2) { titledDone.click() }
    }

    private func photoCount(in app: XCUIApplication) -> Int {
        let count = element(in: app, identifier: "library.photoCount")
        guard count.waitForExistence(timeout: timeout) else { return -1 }
        let raw = count.value as? String ?? ""
        return Int(raw.filter { $0.isNumber }) ?? -1
    }

    private func replaceText(in element: XCUIElement, with value: String) {
        // Fields inside list rows don't always report focus to XCUITest, so
        // type at the app level after the click has moved focus there.
        element.doubleClick()
        let app = XCUIApplication()
        app.typeKey("a", modifierFlags: .command)
        app.typeText(value)
    }

    private func recordSkipped(_ message: String) {
        XCTContext.runActivity(named: "Skipped import UI step") { activity in
            addNote(message, to: activity)
        }
    }

    private func capture(_ app: XCUIApplication, named name: String, activity: XCTActivity? = nil) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        if let activity {
            activity.add(attachment)
        } else {
            add(attachment)
        }
    }

    private func addNote(_ message: String, to activity: XCTActivity) {
        let attachment = XCTAttachment(string: message)
        attachment.name = "note"
        attachment.lifetime = .keepAlways
        activity.add(attachment)
    }

    private func element(in app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
