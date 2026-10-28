import XCTest

/// A first import of a large library must not freeze the app, and every page
/// must open quickly afterwards. The app imports a synthetic library through
/// the real Apple Photos import, then opens each page itself and measures its
/// main thread (PageProbe, -MomentsUITestPageProbe); the CI workflow prints
/// the report. MOMENTS_PAGE_STRESS_COUNT sets the library size.
final class MomentsPageProbeUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testFirstImportAndPagesWithALargeLibrary() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let folder = environment["MOMENTS_PAGE_DIR"], folder.hasPrefix("/") else {
            throw XCTSkip("MOMENTS_PAGE_DIR was not supplied")
        }
        let count = Int(environment["MOMENTS_PAGE_STRESS_COUNT"] ?? "") ?? 5_000
        let folderURL = URL(fileURLWithPath: folder)
        try? FileManager.default.removeItem(at: folderURL)
        let app = XCUIApplication()
        app.launchArguments = [
            "-MomentsUITesting", "-MomentsUITestPageProbe", folder, "-MomentsUITestStressLibrary", String(count)
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60))

        // The app measures itself: this test must not query it meanwhile.
        let done = folderURL.appending(path: "page-report-done")
        // PageProbe has one 600 s post-import phase and thirteen bounded page
        // phases. Give the probe enough time to record every phase, while
        // keeping the bound below the workflow's 60-minute job limit even for
        // the 20,000-item manual run.
        let phaseBudget = 600 + 13 * 45
        let deadline = Date().addingTimeInterval(TimeInterval(phaseBudget + 60 + count / 20))
        while !FileManager.default.fileExists(atPath: done.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 2)
        }
        let text = (try? String(contentsOf: folderURL.appending(path: "page-report.txt"), encoding: .utf8)) ?? "missing page report"
        let note = XCTAttachment(string: text)
        note.name = "page-report"
        note.lifetime = .keepAlways
        add(note)
        print("PAGE-REPORT-BEGIN\n\(text)\nPAGE-REPORT-END")
        XCTAssertTrue(FileManager.default.fileExists(atPath: done.path), "The page probe did not finish:\n\(text)")
    }
}
