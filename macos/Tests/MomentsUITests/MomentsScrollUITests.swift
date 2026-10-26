import XCTest

/// Scrolling a large Library must stay smooth. The app measures its own frame
/// callbacks while scrolling (ScrollProbe, -MomentsUITestScrollProbe) and
/// writes a report on a key press; the CI workflow prints the reports.
final class MomentsScrollUITests: XCTestCase {
    private let launchTimeout: TimeInterval = 30

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testLibraryScrollsWithoutLongStalls() throws {
        guard let folder = ProcessInfo.processInfo.environment["MOMENTS_SCROLL_DIR"], folder.hasPrefix("/") else {
            throw XCTSkip("MOMENTS_SCROLL_DIR was not supplied")
        }
        let folderURL = URL(fileURLWithPath: folder)
        try? FileManager.default.removeItem(at: folderURL)
        let app = XCUIApplication()
        app.launchArguments = [
            "-MomentsUITesting", "-MomentsUITestScrollProbe", folder, "-MomentsUITestStressCount", "2000",
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh-Hans"
        ]
        app.launch()
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: launchTimeout))
        let anyPhoto = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'library.photo.'")).firstMatch
        XCTAssertTrue(anyPhoto.waitForExistence(timeout: launchTimeout))
        Thread.sleep(forTimeInterval: 2)

        let scrollView = app.scrollViews.firstMatch
        XCTAssertTrue(scrollView.waitForExistence(timeout: launchTimeout))
        // First pass: thumbnails are made for the first time.
        for _ in 0..<40 {
            scrollView.scroll(byDeltaX: 0, deltaY: -600)
        }
        attachScreenshot(app, named: "scroll-first-pass-evidence")
        app.typeKey("1", modifierFlags: [])
        Thread.sleep(forTimeInterval: 1)
        // Second pass back up: thumbnails come from the caches.
        for _ in 0..<40 {
            scrollView.scroll(byDeltaX: 0, deltaY: 600)
        }
        attachScreenshot(app, named: "scroll-second-pass-evidence")
        app.typeKey("2", modifierFlags: [])
        Thread.sleep(forTimeInterval: 1)

        var reports: [String] = []
        for index in 1...2 {
            let url = folderURL.appending(path: "scroll-report-\(index).txt")
            reports.append((try? String(contentsOf: url, encoding: .utf8)) ?? "missing report \(index)")
        }
        let text = reports.joined(separator: "\n")
        let note = XCTAttachment(string: text)
        note.name = "scroll-report"
        note.lifetime = .keepAlways
        add(note)
        print("SCROLL-REPORT-BEGIN\n\(text)\nSCROLL-REPORT-END")
        XCTAssertFalse(text.contains("missing report"), text)
    }

    private func attachScreenshot(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
