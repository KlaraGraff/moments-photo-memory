import AppKit
import XCTest

/// Deleting photos: Delete asks, ⌘⌫ doesn't, ⌘Z and the bar's Undo bring
/// them back, Recently Deleted recovers or deletes for good, the viewer's
/// trash button moves on to the next photo, and Settings › Imports removes
/// a whole folder.
final class MomentsDeletionUITests: XCTestCase {
    private let timeout: TimeInterval = 15
    private var app: XCUIApplication?

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// A failure carries a picture of the window, printed in the job log.
    override func record(_ issue: XCTIssue) {
        var issue = issue
        if let app {
            let line = issue.sourceCodeContext.location?.lineNumber ?? 0
            let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            attachment.name = "delete-failure-line-\(line)-evidence"
            attachment.lifetime = .keepAlways
            issue.add(attachment)
        }
        super.record(issue)
    }

    func testDeleteKeyAsksUndoBringsBackAndRecentlyDeletedRecovers() {
        let app = launch(language: "zh-Hans")
        let photo = firstPhoto(app)
        let id = String(photo.identifier.dropFirst("library.photo.".count))
        XCTAssertFalse(element(app, "sidebar.recently-deleted").exists, "Recently Deleted shows before anything was deleted")

        // Delete asks first.
        photo.click()
        app.typeKey(.delete, modifierFlags: [])
        let confirm = alertButton(app, "delete.confirm", title: "删除")
        XCTAssertTrue(confirm.exists, "Delete did not ask")
        capture(app, "delete-01-confirm-evidence")
        confirm.click()
        XCTAssertTrue(photo.waitForNonExistence(timeout: timeout), "The deleted photo is still in the Library")
        XCTAssertTrue(element(app, "delete.bar").waitForExistence(timeout: timeout), "No Undo after deleting")
        capture(app, "delete-02-undo-bar-evidence")

        // ⌘Z puts it back.
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(photo.waitForExistence(timeout: timeout), "⌘Z did not bring the photo back")

        // ⌘⌫ deletes without asking.
        pauseLongerThanADoubleClick()
        photo.click()
        app.typeKey(.delete, modifierFlags: .command)
        XCTAssertTrue(photo.waitForNonExistence(timeout: timeout), "⌘⌫ did not delete")
        XCTAssertFalse(app.sheets.firstMatch.exists || app.dialogs.firstMatch.exists, "⌘⌫ asked anyway")

        // Recently Deleted lists it with its days left; Recover puts it back.
        let trash = element(app, "sidebar.recently-deleted")
        XCTAssertTrue(trash.waitForExistence(timeout: timeout), "No Recently Deleted in the sidebar")
        trash.click()
        let deleted = element(app, "recently-deleted.photo.\(id)")
        XCTAssertTrue(deleted.waitForExistence(timeout: timeout), "The photo is not in Recently Deleted")
        capture(app, "delete-03-recently-deleted-evidence")
        deleted.click()
        element(app, "recently-deleted.recover").click()
        XCTAssertTrue(deleted.waitForNonExistence(timeout: timeout), "Recover left the photo in Recently Deleted")
        element(app, "sidebar.library").click()
        XCTAssertTrue(element(app, "library.photo.\(id)").waitForExistence(timeout: timeout), "The recovered photo is not back in the Library")
    }

    func testViewerTrashMovesOnAndDeleteAllInASmallWindow() {
        let app = launch(language: "en", extra: ["-MomentsUITestSmallWindow"])
        let photo = firstPhoto(app)
        photo.doubleClick()
        let viewer = element(app, "viewer")
        XCTAssertTrue(viewer.waitForExistence(timeout: timeout))
        let counter = element(app, "viewer.counter")
        XCTAssertTrue(counter.waitForExistence(timeout: timeout))
        let before = counter.label + (counter.value as? String ?? "")
        let trashButton = element(app, "viewer.delete")
        XCTAssertTrue(trashButton.waitForExistence(timeout: timeout), "The viewer has no trash button")
        XCTAssertTrue(app.windows.firstMatch.frame.contains(trashButton.frame), "The trash button does not fit a small window")
        clickCentre(trashButton)
        let confirm = alertButton(app, "delete.confirm", title: "Delete")
        XCTAssertTrue(confirm.exists, "The trash button did not ask")
        confirm.click()
        // The viewer stays open on the next photo.
        XCTAssertTrue(viewer.exists, "The viewer closed instead of moving on")
        XCTAssertTrue(element(app, "delete.bar").waitForExistence(timeout: timeout))
        capture(app, "delete-04-viewer-small-window-evidence")
        XCTAssertNotEqual(counter.label + (counter.value as? String ?? ""), before, "The viewer still shows the deleted photo")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(viewer.waitForNonExistence(timeout: timeout))

        // The small window may start with the sidebar folded away.
        let trash = element(app, "sidebar.recently-deleted")
        if !trash.waitForExistence(timeout: 5) {
            app.typeKey("s", modifierFlags: [.command, .control])
        }
        XCTAssertTrue(trash.waitForExistence(timeout: timeout))
        trash.click()
        let deleteAll = element(app, "recently-deleted.delete")
        XCTAssertTrue(deleteAll.waitForExistence(timeout: timeout))
        XCTAssertTrue(app.windows.firstMatch.frame.contains(deleteAll.frame), "Delete All does not fit a small window")
        capture(app, "delete-05-recently-deleted-small-window-evidence")
        deleteAll.click()
        let purge = alertButton(app, "recently-deleted.purge.confirm", title: "Delete")
        XCTAssertTrue(purge.exists, "Delete All did not ask")
        capture(app, "delete-06-delete-for-good-confirm-evidence")
        purge.click()
        XCTAssertTrue(element(app, "recently-deleted.photo.\(String(photo.identifier.dropFirst("library.photo.".count)))").waitForNonExistence(timeout: timeout))
        capture(app, "delete-07-recently-deleted-empty-evidence")
    }

    func testRemovingAnImportedFolderMovesItsPhotos() {
        let app = launch(language: "zh-Hans", extra: ["-MomentsUITestImportSource", "-moments.settings.tab", "imports"])
        _ = firstPhoto(app)
        app.typeKey(",", modifierFlags: .command)
        let remove = element(app, "settings.imports.remove.Synthetic folder")
        XCTAssertTrue(remove.waitForExistence(timeout: timeout), "Settings › Imports does not list the folder")
        let settings = app.windows.containing(.any, identifier: "settings.imports.remove.Synthetic folder").firstMatch
        capture(settings, "delete-08-settings-imports-evidence")
        remove.click()
        let confirm = alertButton(app, "settings.imports.remove.confirm", title: "移除")
        XCTAssertTrue(confirm.exists, "Remove did not ask")
        capture(settings, "delete-09-remove-folder-confirm-evidence")
        confirm.click()
        XCTAssertTrue(element(app, "settings.imports.removed").waitForExistence(timeout: timeout), "No word on what was removed")
        capture(settings, "delete-10-folder-removed-evidence")
        app.typeKey("w", modifierFlags: .command)
        // Exactly the folder's three photos wait in Recently Deleted.
        let trash = element(app, "sidebar.recently-deleted")
        XCTAssertTrue(trash.waitForExistence(timeout: timeout), "No Recently Deleted after removing the folder")
        trash.click()
        let deleted = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "recently-deleted.photo."))
        XCTAssertTrue(deleted.element(boundBy: 2).waitForExistence(timeout: timeout))
        XCTAssertEqual(deleted.count, 3, "Recently Deleted does not hold exactly the folder's three photos")
        capture(app, "delete-11-folder-in-recently-deleted-evidence")
    }

    /// The alert's button by its identifier, or by its title where the
    /// system alert does not carry SwiftUI identifiers.
    private func alertButton(_ app: XCUIApplication, _ identifier: String, title: String) -> XCUIElement {
        let byID = element(app, identifier)
        if byID.waitForExistence(timeout: 5) { return byID }
        let inSheet = app.sheets.buttons[title]
        if inSheet.waitForExistence(timeout: 5) { return inSheet }
        let inDialog = app.dialogs.buttons[title]
        _ = inDialog.waitForExistence(timeout: 5)
        return inDialog
    }

    private func launch(language: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-MomentsUITesting", "-AppleLanguages", "(\(language))", "-AppleLocale", language] + extra
        app.launch()
        app.activate()
        self.app = app
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: timeout))
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: timeout))
        return app
    }

    private func firstPhoto(_ app: XCUIApplication) -> XCUIElement {
        let photo = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.photo.")).element(boundBy: 0)
        XCTAssertTrue(photo.waitForExistence(timeout: timeout), "The Library shows no photos")
        // Pinned by id, so it still means this photo after others move.
        return element(app, photo.identifier)
    }

    /// XCUITest does not count the viewer's header buttons as hittable over
    /// the dimmed window, so they are clicked where they are.
    private func clickCentre(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    private func pauseLongerThanADoubleClick() {
        RunLoop.current.run(until: Date().addingTimeInterval(NSEvent.doubleClickInterval + 0.3))
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        capture(app.windows.firstMatch, name)
    }

    private func capture(_ window: XCUIElement, _ name: String) {
        // Only the app's windows, never the rest of the desktop.
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
