import XCTest

/// Hiding, showing and dragging the sidebar must move the photos smoothly,
/// like Photos. The app runs the sidebar changes itself and measures its own
/// frame callbacks and grid widths (ResizeProbe, -MomentsUITestResizeProbe);
/// the CI workflow prints the report.
final class MomentsResizeUITests: XCTestCase {
    private let launchTimeout: TimeInterval = 30

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testSidebarChangesResizePhotosSmoothly() throws {
        guard let folder = ProcessInfo.processInfo.environment["MOMENTS_RESIZE_DIR"], folder.hasPrefix("/") else {
            throw XCTSkip("MOMENTS_RESIZE_DIR was not supplied")
        }
        let folderURL = URL(fileURLWithPath: folder)
        try? FileManager.default.removeItem(at: folderURL)
        let app = XCUIApplication()
        // maple's window: English, 1111 pt wide.
        app.launchArguments = [
            "-MomentsUITesting", "-MomentsUITestResizeProbe", folder, "-MomentsUITestStressCount", "600",
            "-MomentsUITestWindowWidth", "1111", "-AppleLanguages", "(en)", "-AppleLocale", "en"
        ]
        app.launch()
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: launchTimeout))
        let anyPhoto = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'library.photo.'")).firstMatch
        XCTAssertTrue(anyPhoto.waitForExistence(timeout: launchTimeout))
        Thread.sleep(forTimeInterval: 2)

        // The app drives the sidebar itself ("r"); querying it meanwhile
        // would block its main thread and look like dropped frames.
        app.typeKey("r", modifierFlags: [])
        let reportURL = folderURL.appending(path: "resize-report.txt")
        let deadline = Date().addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: reportURL.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 1)
        }
        let report = (try? String(contentsOf: reportURL, encoding: .utf8)) ?? "missing resize report"
        let note = XCTAttachment(string: report)
        note.name = "resize-report"
        note.lifetime = .keepAlways
        add(note)
        print("RESIZE-REPORT-BEGIN\n\(report)\nRESIZE-REPORT-END")
        XCTAssertFalse(report.hasPrefix("missing"), report)
        // maple's jump: moving the sidebar must never change how many photos
        // are in a row (it went from 4 to 5 mid-animation).
        XCTAssertTrue(report.contains("hide sidebar:"), report)
        let changes = report.components(separatedBy: "column changes ").dropFirst().compactMap { Int($0.prefix { $0.isNumber }) }
        XCTAssertFalse(changes.isEmpty, report)
        XCTAssertEqual(changes.reduce(0, +), 0, "The grid changed its column count while the sidebar moved:\n\(report)")
    }

    /// Like Photos: zooming the window (a double click on its top bar) makes
    /// the photos larger or smaller but keeps how many are in a row; only the
    /// toolbar's − and + change that, at any window size.
    func testZoomingTheWindowKeepsPhotosPerRow() throws {
        let setting = UserDefaults(suiteName: UserDefaults.globalDomain)?.string(forKey: "AppleActionOnDoubleClick")
        if setting == "Minimize" || setting == "None" {
            throw XCTSkip("This Mac is set to \(setting ?? "") on a title bar double click")
        }
        let app = XCUIApplication()
        app.launchArguments = [
            "-MomentsUITesting", "-MomentsUITestSmallWindow", "-MomentsUITestStressCount", "120",
            "-moments.library.thumbnailSize", "2", "-AppleLanguages", "(en)", "-AppleLocale", "en"
        ]
        app.launch()
        app.activate()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: launchTimeout))
        XCTAssertTrue(photos(in: app).firstMatch.waitForExistence(timeout: launchTimeout))
        Thread.sleep(forTimeInterval: 1.5)
        let titleBar = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 260, dy: 26))
        let zoomOut = app.descendants(matching: .any).matching(identifier: "library.zoom-out").firstMatch

        let small = rows(in: app)
        evidence(app, "photos-per-row-small-evidence")
        XCTAssertEqual(small.perRow, 4, "Default zoom at the small window")

        let smallFrame = window.frame
        titleBar.doubleClick()
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertGreaterThan(window.frame.width, smallFrame.width + 100, "The window did not zoom")
        let large = rows(in: app)
        evidence(app, "photos-per-row-large-evidence")
        XCTAssertEqual(large.perRow, 4, "Zooming the window changed how many photos are in a row")
        XCTAssertGreaterThan(large.photoWidth, small.photoWidth + 20, "The photos did not grow with the window")

        // − adds photos to each row, in the large window and after going back.
        XCTAssertTrue(zoomOut.isEnabled)
        zoomOut.click()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(rows(in: app).perRow, 6, "− at the large window")
        titleBar.doubleClick()
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(window.frame, smallFrame, "The window did not zoom back")
        XCTAssertEqual(rows(in: app).perRow, 6, "Zooming back changed how many photos are in a row")
        zoomOut.click()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(rows(in: app).perRow, 8, "The densest level at the small window")
        evidence(app, "photos-per-row-small-densest-evidence")
    }

    private func photos(in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'library.photo.'"))
    }

    /// The most photos side by side in one row on screen, and their width.
    private func rows(in app: XCUIApplication) -> (perRow: Int, photoWidth: CGFloat) {
        XCTAssertEqual(app.state, .runningForeground, "Moments lost focus")
        let window = app.windows.firstMatch.frame
        let frames = photos(in: app).allElementsBoundByIndex.map(\.frame)
            .filter { !$0.isEmpty && window.contains(CGPoint(x: $0.midX, y: $0.midY)) }
        let rows = Dictionary(grouping: frames) { Int($0.minY.rounded()) }
        let fullest = rows.values.max { $0.count < $1.count } ?? []
        return (fullest.count, fullest.first?.width ?? 0)
    }

    private func evidence(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
