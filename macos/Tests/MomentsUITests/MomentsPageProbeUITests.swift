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
        // Import duration is independent of the bounded page phases and can
        // take many minutes at library scale. Keep only a hard ceiling below
        // the workflow's 60-minute job timeout; phase timeouts remain measured
        // and reported by PageProbe.
        let deadline = Date().addingTimeInterval(50 * 60)
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
        // A timed-out phase is a failed responsiveness assertion. It remains
        // visible in the attachment so the slow phase can be diagnosed.
        let phases = [
            "first import", "after import (faces, bursts, place names)",
            "People", "Map", "Timeline", "Chapters", "Library",
            "viewer open", "viewer close", "Chapters again",
            "chapter with most photos", "back to chapters", "Timeline again",
            "Library again"
        ]
        for phase in phases {
            XCTAssertTrue(text.contains("page report (\(phase)):"), "Missing \(phase) report")
        }
        XCTAssertEqual(text.components(separatedBy: "longest stall").count - 1, phases.count, "Every phase must report a stall")
        XCTAssertEqual(text.components(separatedBy: "main thread samples:").count - 1, phases.count, "Every phase must report a stack sample")
        XCTAssertEqual(text.components(separatedBy: "memory ").count - 1, phases.count, "Every phase must report memory")
        XCTAssertEqual(text.components(separatedBy: "selection-to-shell ").count - 1, phases.count, "Every phase must report shell timing")
        XCTAssertEqual(text.components(separatedBy: "first-content ").count - 1, phases.count, "Every phase must report first-content timing")
        XCTAssertEqual(text.components(separatedBy: "first-thumbnail ").count - 1, phases.count, "Every phase must report thumbnail timing")
        XCTAssertEqual(text.components(separatedBy: "fully-settled ").count - 1, phases.count, "Every phase must report settled timing")
        // Closing the viewer is a transition, not a new destination. It has
        // no shell or first-content event of its own; the next Chapters phase
        // records the destination that becomes visible after the close.
        let shellPhases = [
            "People", "Map", "Timeline", "Chapters", "Library", "viewer open",
            "Chapters again", "chapter with most photos", "back to chapters",
            "Timeline again", "Library again"
        ]
        let contentPhases = shellPhases
        let pagePhases = phases.dropFirst(2)
        let pageReportLines = text
            .split(separator: "\n")
            .map(String.init)
            .filter { line in
                pagePhases.contains { line.hasPrefix("page report (\($0)):") }
            }
        for phase in shellPhases {
            let line = pageReportLines.first { $0.hasPrefix("page report (\(phase)):") }
            XCTAssertNotNil(line)
            XCTAssertFalse(line?.contains("selection-to-shell not observed") == true, "\(phase) never reported its rendered shell:\n\(text)")
        }
        for phase in contentPhases {
            let line = pageReportLines.first { $0.hasPrefix("page report (\(phase)):") }
            XCTAssertNotNil(line)
            XCTAssertFalse(line?.contains("first-content not observed") == true, "\(phase) never reported its first useful content:\n\(text)")
        }
        let viewerClose = pageReportLines.first { $0.hasPrefix("page report (viewer close):") }
        XCTAssertNotNil(viewerClose)
        XCTAssertTrue(viewerClose?.contains("selection-to-shell not observed") == true)
        XCTAssertTrue(viewerClose?.contains("first-content not observed") == true)
        XCTAssertFalse(text.contains("(timed out)"), "A timed-out responsiveness phase must fail the probe:\n\(text)")

    }
}
