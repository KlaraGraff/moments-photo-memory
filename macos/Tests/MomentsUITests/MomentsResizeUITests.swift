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
        XCTAssertFalse(report.contains("column changes 1") || report.contains("column changes 2"),
                       "The grid changed its column count while the sidebar moved:\n\(report)")
    }
}
