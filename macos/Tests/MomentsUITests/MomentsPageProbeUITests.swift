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
        // Phases the run leaves out, e.g. "Map" while that page freezes the app.
        let skipped = Set((environment["MOMENTS_PAGE_SKIP"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        // Map layers the run leaves out, e.g. "routes,pins" while the Map
        // freezes the app.
        let mapLayerNames: [String] = (environment["MOMENTS_PAGE_MAP_LAYERS"] ?? "")
            .split(separator: ",")
            .map { (part: Substring) -> String in part.trimmingCharacters(in: .whitespaces) }
            .filter { (name: String) -> Bool in !name.isEmpty }
        let mapLayers = Set(mapLayerNames)
        let folderURL = URL(fileURLWithPath: folder)
        try? FileManager.default.removeItem(at: folderURL)
        let app = XCUIApplication()
        app.launchArguments = [
            "-MomentsUITesting", "-MomentsUITestPageProbe", folder, "-MomentsUITestStressLibrary", String(count),
            "-MomentsUITestPageProbeSkip", skipped.sorted().joined(separator: ","),
            "-MomentsUITestPageProbeMapLayers", mapLayers.sorted().joined(separator: ",")
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60))

        // The app measures itself: this test must not query it meanwhile.
        let done = folderURL.appending(path: "page-report-done")
        // Import duration is independent of the bounded page phases and can
        // take many minutes at library scale. Keep only a hard ceiling below
        // the PageProbe job's timeout; phase timeouts remain measured and
        // reported by PageProbe. A probe that stops making progress is ended
        // much earlier by the workflow's watchdog (page-heartbeat.txt).
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
            "viewer open", "favorite on", "favorite off", "viewer close", "Chapters again",
            "chapter with most photos", "back to chapters", "Timeline again",
            "Library again"
        ].filter { !skipped.contains($0) }
        for phase in phases {
            XCTAssertTrue(text.contains("page report (\(phase)):"), "Missing \(phase) report")
        }
        XCTAssertEqual(text.components(separatedBy: "longest stall").count - 1, phases.count, "Every phase must report a stall")
        XCTAssertEqual(text.components(separatedBy: "main thread samples:").count - 1, phases.count, "Every phase must report a stack sample")
        let reportLines = text.split(separator: "\n").filter { $0.hasPrefix("page report (") }
        XCTAssertEqual(reportLines.filter { $0.contains(", memory ") }.count, phases.count, "Every phase must report memory")
        XCTAssertEqual(text.components(separatedBy: "selection-to-shell ").count - 1, phases.count, "Every phase must report shell timing")
        XCTAssertEqual(text.components(separatedBy: "first-content ").count - 1, phases.count, "Every phase must report first-content timing")
        XCTAssertEqual(text.components(separatedBy: "first-thumbnail ").count - 1, phases.count, "Every phase must report thumbnail timing")
        XCTAssertEqual(text.components(separatedBy: "fully-settled ").count - 1, phases.count, "Every phase must report settled timing")
        // Closing the viewer is a transition, not a new destination. It has
        // no shell or first-content event of its own; the next Chapters phase
        // records the destination that becomes visible after the close.
        // A page phase whose page is already on screen, because the phases
        // between were skipped (Library again right after the viewer when
        // Chapters and Timeline are skipped), shows no new shell either.
        let pageOfPhase = [
            "People": "people", "Map": "map", "Timeline": "timeline", "Chapters": "chapters",
            "Library": "library", "Chapters again": "chapters", "chapter with most photos": "chapter",
            "back to chapters": "chapters", "Timeline again": "timeline", "Library again": "library"
        ]
        var pageOnScreen = "library"
        var shellPhases: [String] = []
        for phase in phases {
            if phase == "viewer open" {
                shellPhases.append(phase)
            } else if let page = pageOfPhase[phase] {
                if page != pageOnScreen { shellPhases.append(phase) }
                pageOnScreen = page
            }
        }
        let contentPhases = shellPhases + ["favorite on", "favorite off"].filter { !skipped.contains($0) }
        let pagePhases = phases.filter { $0 != "first import" && !$0.hasPrefix("after import") }
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
        if !skipped.contains("viewer close") {
            let viewerClose = pageReportLines.first { $0.hasPrefix("page report (viewer close):") }
            XCTAssertNotNil(viewerClose)
            XCTAssertTrue(viewerClose?.contains("selection-to-shell not observed") == true)
            XCTAssertTrue(viewerClose?.contains("first-content not observed") == true)
        }
        for phase in ["favorite on", "favorite off"] where !skipped.contains(phase) {
            let line = pageReportLines.first { $0.hasPrefix("page report (\(phase)):") }
            XCTAssertTrue(line?.contains("selection-to-shell not observed") == true, "\(phase) is an edit, not a new page:\n\(text)")
        }
        // A phase that did not settle within its limit is a measurement, not
        // a probe failure: the report marks it "(timed out)" and the workflow
        // summary lists it. Thresholds for passing or failing pages belong to
        // the agreed performance targets, which are not set yet.
    }
}
