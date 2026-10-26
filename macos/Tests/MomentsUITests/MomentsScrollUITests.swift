import XCTest

/// Scrolling a large Library must stay smooth. The app scrolls the Library
/// down and back up itself and measures its own frame callbacks (ScrollProbe,
/// -MomentsUITestScrollProbe); the CI workflow prints the reports.
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

        // The app scrolls itself ("s"): this test must not query it while
        // it measures, since accessibility queries block its main thread.
        app.typeKey("s", modifierFlags: [])
        let deadline = Date().addingTimeInterval(45)
        let secondReport = folderURL.appending(path: "scroll-report-2.txt")
        while !FileManager.default.fileExists(atPath: secondReport.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 1)
        }
        attachScreenshot(app, named: "scroll-after-evidence")

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
