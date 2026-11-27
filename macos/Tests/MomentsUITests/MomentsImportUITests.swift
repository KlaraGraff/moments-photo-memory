import XCTest

final class MomentsImportUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Stop at the first failure: a test must never keep clicking once Moments
        // is not the frontmost app, or its clicks land in other apps.
        continueAfterFailure = false
    }

    private let timeout: TimeInterval = 15

    /// An import ends on the photos: no sheet to work through. The photos
    /// persist, a second import adds nothing, and the video plays.
    func testFolderImportPersistsAndOpensOnThePhotos() throws {
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
        // Straight to the photos: nothing to confirm, no banner asking for work.
        XCTAssertFalse(element(in: app, identifier: "import.review").exists, "The import review sheet is back")
        XCTAssertFalse(element(in: app, identifier: "library.review-banner").exists, "The to-confirm banner is back")
        let importedCount = photoCount(in: app)
        XCTAssertGreaterThan(importedCount, initialCount, "The folder import did not add any photos")
        capture(app, named: "import-05-photos-after-import-evidence")

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

        try importFolder(folderURL, in: app, screenshotPrefix: "import-04")
        // The library card shows the empty-memory placeholder as a thin line.
        capture(app, named: "import-18-empty-memory-placeholder")
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
        XCTAssertTrue(memory.waitForExistence(timeout: timeout), "An imported photo's memory line was not visible after relaunch")

        exerciseVideoPlayback(in: app)
    }

    /// The imported video plays in the large viewer. Showing the player once
    /// aborted the app, because nothing linked AVKit. The video is found by
    /// the mark on its thumbnail.
    private func exerciseVideoPlayback(in app: XCUIApplication) {
        element(in: app, identifier: "sidebar.library").click()
        let mark = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.kind.video."))
            .firstMatch
        // The Library grid is lazy, so scroll until the video's card is built.
        var found = mark.waitForExistence(timeout: 5)
        let grid = app.scrollViews.firstMatch
        for _ in 0..<12 where !found && grid.exists {
            grid.scroll(byDeltaX: 0, deltaY: -500)
            found = mark.waitForExistence(timeout: 1)
        }
        XCTAssertTrue(found, "The imported video has no video mark in the Library")
        let clipID = String(mark.identifier.dropFirst("library.kind.video.".count))
        let clip = element(in: app, identifier: "library.photo.\(clipID)")
        XCTAssertTrue(clip.waitForExistence(timeout: timeout), "The imported video is not in the Library")
        clip.doubleClick()
        XCTAssertTrue(element(in: app, identifier: "viewer").waitForExistence(timeout: timeout), "Double click did not open the video")
        let viewer = element(in: app, identifier: "viewer")
        XCTAssertTrue(
            element(in: app, identifier: "viewer.video").waitForExistence(timeout: timeout),
            "The viewer shows no player for the video. Viewer contents:\n\(viewer.debugDescription)"
        )
        // Give the player time to load and start; the old crash came on first show.
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(app.state, .runningForeground, "Moments quit while showing the video")
        capture(app, named: "import-21-video-playing-evidence")
        let close = element(in: app, identifier: "viewer.close")
        if close.exists { close.click() } else { app.typeKey(.escape, modifierFlags: []) }
    }

    private func launch(storeDirectory: URL) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-MomentsUITestStoreDirectory", storeDirectory.path,
            "-ApplePersistenceIgnoreState", "YES",
            "-NSQuitAlwaysKeepsWindows", "NO"
        ]
        app.launch()
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: timeout), "Moments is not the frontmost app")
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: timeout), "Moments opened no window")
        XCTAssertTrue(window.isHittable, "The Moments window is covered or off screen")
        return app
    }

    private func importFolder(_ folder: URL, in app: XCUIApplication, screenshotPrefix: String) throws {
        // The app counts the folder imports that ran to the end.
        let probe = element(in: app, identifier: "import.finished")
        XCTAssertTrue(probe.waitForExistence(timeout: timeout), "The app does not say when an import ends")
        let before = probe.label
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

        let finished = NSPredicate(format: "label != %@", before)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: finished, evaluatedWith: probe)], timeout: 90), .completed, "The import did not finish (\(probe.label))")
        capture(app, named: "\(screenshotPrefix)-finished")
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

    private func photoCount(in app: XCUIApplication) -> Int {
        let count = element(in: app, identifier: "library.photoCount")
        guard count.waitForExistence(timeout: timeout) else {
            // An empty library shows the first-launch import screen instead of a count.
            return element(in: app, identifier: "library.firstLaunch").exists ? 0 : -1
        }
        let raw = count.value as? String ?? ""
        return Int(raw.filter { $0.isNumber }) ?? -1
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
        XCTAssertEqual(app.state, .runningForeground, "Moments lost focus; stopping before clicking another app")
        return app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
