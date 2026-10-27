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

    /// Like Photos: zooming the window (Window ▸ Zoom, as a double click on
    /// the top bar does) makes the photos larger or smaller but keeps how
    /// many are in a row; only the toolbar's − and + change that. (The
    /// hosted Mac's screen is 1,024 pt wide, so the window grows from 900 to
    /// about that; the wider steps are covered by the unit tests.)
    func testZoomingTheWindowKeepsPhotosPerRow() throws {
        let app = launch(["-MomentsUITestStartSmall"])
        let window = app.windows.firstMatch
        let zoomOut = app.descendants(matching: .any).matching(identifier: "library.zoom-out").firstMatch
        func zoomWindow() {
            app.menuBars.menuBarItems["Window"].click()
            app.menuBars.menuBarItems["Window"].menuItems["Zoom"].click()
            Thread.sleep(forTimeInterval: 1.5)
        }

        let smallFrame = window.frame
        let small = rows(in: app)
        evidence(app, "photos-per-row-small-evidence")
        XCTAssertEqual(small.perRow, 4, "Default photos per row at the small window \(smallFrame)")

        zoomWindow()
        let largeFrame = window.frame
        let grown = largeFrame.width - smallFrame.width
        XCTAssertGreaterThan(grown, 60, "The window did not zoom: \(smallFrame) → \(largeFrame)")
        let large = rows(in: app)
        evidence(app, "photos-per-row-large-evidence")
        let sizes = "window \(smallFrame.width) → \(largeFrame.width), photo \(small.photoWidth) → \(large.photoWidth)"
        XCTAssertEqual(large.perRow, 4, "Zooming the window changed how many photos are in a row (\(sizes))")
        // Four photos share the extra width.
        XCTAssertGreaterThan(large.photoWidth, small.photoWidth + grown / 8, "The photos did not grow with the window (\(sizes))")

        zoomOut.click()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(rows(in: app).perRow, 5, "− in the large window")
        zoomWindow()
        XCTAssertEqual(window.frame, smallFrame, "The window did not zoom back")
        XCTAssertEqual(rows(in: app).perRow, 5, "Zooming back changed how many photos are in a row")
    }

    /// A count chosen in a wider window shows as the densest step a small
    /// window has room for, 8; − is at its end there and + steps back.
    func testASmallWindowCapsPhotosPerRow() {
        let app = launch(["-MomentsUITestSmallWindow", "-moments.library.photosPerRow", "18"])
        XCTAssertEqual(rows(in: app).perRow, 8, "A 900 pt window should show 8 photos per row")
        evidence(app, "photos-per-row-small-capped-evidence")
        let zoomOut = app.descendants(matching: .any).matching(identifier: "library.zoom-out").firstMatch
        let zoomIn = app.descendants(matching: .any).matching(identifier: "library.zoom-in").firstMatch
        XCTAssertFalse(zoomOut.isEnabled, "− should be at its end in the small window")
        XCTAssertTrue(zoomIn.isEnabled)
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-MomentsUITesting", "-MomentsUITestStressCount", "300", "-AppleLanguages", "(en)", "-AppleLocale", "en"
        ] + arguments
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: launchTimeout))
        XCTAssertTrue(photos(in: app).firstMatch.waitForExistence(timeout: launchTimeout))
        Thread.sleep(forTimeInterval: 1.5)
        return app
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
