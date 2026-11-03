import AppKit
import XCTest

/// Rubber-band selection in the Library, the way Photos does it.
final class MomentsMarqueeUITests: XCTestCase {
    private let launchTimeout: TimeInterval = 20

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testDragBetweenPhotosSelectsLikePhotos() {
        let folder: String? = marqueeFolder()
        let arguments: [String] = folder.map { (folder: String) -> [String] in ["-MomentsUITestMarqueeProbe", folder] } ?? []
        exerciseMarquee(launch(extraArguments: arguments), prefix: "marquee-large", folder: folder)
    }

    /// The small window shows about one row of prints, so this one runs on
    /// the dense grid.
    func testDragBetweenPhotosSelectsLikePhotosInASmallWindow() {
        let folder: String? = marqueeFolder()
        let arguments: [String] = folder.map { (folder: String) -> [String] in ["-MomentsUITestMarqueeProbe", folder] } ?? []
        exerciseMarquee(launch(smallWindow: true, photosPerRow: 8, extraArguments: arguments), prefix: "marquee-small", folder: folder)
    }

    /// Held at the bottom edge, the Library keeps scrolling and the
    /// rectangle keeps selecting, on 2,000 photos. The app records every
    /// frame of the drag (-MomentsUITestMarqueeProbe); CI prints the report.
    func testHoldingAtTheBottomEdgeKeepsScrollingAndSelecting() {
        let folder = ProcessInfo.processInfo.environment["MOMENTS_MARQUEE_DIR"].flatMap { $0.hasPrefix("/") ? $0 : nil }
        if let folder { try? FileManager.default.removeItem(atPath: folder) }
        var arguments = ["-MomentsUITestStressCount", "2000"]
        if let folder { arguments += ["-MomentsUITestMarqueeProbe", folder] }
        let app = launch(extraArguments: arguments)
        let visible = visiblePhotos(app)
        guard let first = visible.first else { return XCTFail("No photo on screen") }
        let window = app.windows.firstMatch.frame
        let start = point(app, x: first.frame.minX - 12, y: first.frame.minY - 4)
        // Inside the window, a few points above its bottom edge.
        // Across every column, so each row the grid scrolls in adds photos.
        let lastColumn = visible.map(\.frame.midX).max() ?? first.frame.midX
        let edge = point(app, x: lastColumn, y: window.maxY - 6)
        start.click(forDuration: 0.1, thenDragTo: edge, withVelocity: .default, thenHoldForDuration: 4)

        let count = Int(selectionCount(app)) ?? 0
        XCTAssertGreaterThan(count, visible.count, "Holding at the edge did not keep scrolling and selecting (\(count) selected)")
        let scrolledAway = !first.element.exists || !first.element.isHittable || !window.contains(first.element.frame)
        XCTAssertTrue(scrolledAway, "The Library did not scroll")
        capture(app, named: "marquee-autoscroll-evidence")

        guard let folder else { return }
        let report = URL(fileURLWithPath: folder).appending(path: "marquee-report-1.txt")
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: report.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
        }
        let text = (try? String(contentsOf: report, encoding: .utf8)) ?? "missing marquee report"
        print("MARQUEE-REPORT-BEGIN\n\(text)\nMARQUEE-REPORT-END")
        let note = XCTAttachment(string: text)
        note.name = "marquee-report"
        note.lifetime = .keepAlways
        add(note)
        XCTAssertFalse(text.contains("missing"), text)
    }

    /// Held at the bottom edge in a small window over a short Library of
    /// month sections, the grid keeps scrolling while a section heading
    /// passes the top edge. Seen in a screen recording: from the moment the
    /// first heading reached the top, the grid scrolled a little and jumped
    /// back, about ten times a second, and never got further. The app
    /// reports each time something else moved the grid back.
    func testHoldingAtTheBottomEdgeScrollsPastSectionHeadings() {
        let folder = ProcessInfo.processInfo.environment["MOMENTS_MARQUEE_DIR"].flatMap { $0.hasPrefix("/") ? $0 : nil }
        if let folder { try? FileManager.default.removeItem(atPath: folder) }
        var arguments = [
            "-MomentsUITestStressCount", "26", "-MomentsUITestStressSpacing", "200000",
            "-moments.library.grouping", "month",
        ]
        if let folder { arguments += ["-MomentsUITestMarqueeProbe", folder] }
        let app = launch(smallWindow: true, extraArguments: arguments)
        let visible = visiblePhotos(app)
        guard let first = visible.first else { return XCTFail("No photo on screen") }
        let window = app.windows.firstMatch.frame
        let lastColumn = visible.map(\.frame.midX).max() ?? first.frame.midX
        let start = point(app, x: first.frame.minX - 12, y: first.frame.minY - 4)
        let edge = point(app, x: lastColumn, y: window.maxY - 8)
        start.click(forDuration: 0.1, thenDragTo: edge, withVelocity: .default, thenHoldForDuration: 2.5)

        let count = Int(selectionCount(app)) ?? 0
        XCTAssertGreaterThan(count, visible.count, "Holding at the edge did not keep scrolling and selecting (\(count) selected)")
        guard let folder else { return }
        let report = URL(fileURLWithPath: folder).appending(path: "marquee-report-1.txt")
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: report.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
        }
        let text = (try? String(contentsOf: report, encoding: .utf8)) ?? "missing marquee report"
        XCTAssertTrue(text.contains("scrolled back by something else: 0 times"), String(text.prefix(600)))
    }

    /// Held at the bottom edge over a Library of small month sections, the
    /// rectangle selects every photo it scrolls over: the rows just below
    /// the window too, which the grid may have built before the drag, and
    /// on a second drag over rows built by the first (seen in a screen
    /// recording: the middle rows of a month stayed unselected inside the
    /// rectangle). The drags are short, so those rows are still on screen
    /// when they end.
    func testEveryPhotoScrolledIntoTheRectangleIsSelected() {
        // CI prints the app's report of each drag (-MomentsUITestMarqueeProbe).
        let folder = ProcessInfo.processInfo.environment["MOMENTS_MARQUEE_DIR"].flatMap { $0.hasPrefix("/") ? $0 : nil }
        if let folder { try? FileManager.default.removeItem(atPath: folder) }
        // About 13 photos a month, grouped by month, as in the recording.
        var arguments = [
            "-MomentsUITestStressCount", "600", "-MomentsUITestStressSpacing", "200000",
            "-moments.library.grouping", "month",
        ]
        if let folder { arguments += ["-MomentsUITestMarqueeProbe", folder] }
        let app = launch(extraArguments: arguments)
        let visible = visiblePhotos(app)
        guard let first = visible.first else { return XCTFail("No photo on screen") }
        let window = app.windows.firstMatch.frame
        let lastColumn = visible.map(\.frame.midX).max() ?? first.frame.midX
        let start = point(app, x: first.frame.minX - 12, y: first.frame.minY - 4)
        // Just inside the bottom edge, and past it, where it scrolls fastest.
        let edge = point(app, x: lastColumn, y: window.maxY - 6)
        let belowEdge = point(app, x: lastColumn, y: window.maxY + 60)
        // Any photo, not the first one: the lazy grid lets that one go once
        // a drag has scrolled far enough.
        let scrollView = app.scrollViews.containing(NSPredicate(format: "identifier BEGINSWITH %@", "library.photo.")).firstMatch
        func backAtTheTop() -> Bool { abs(first.element.frame.minY - first.frame.minY) < 2 }

        let drags: [(name: String, to: XCUICoordinate, hold: TimeInterval)] = [
            ("the first drag", edge, 0.5),
            ("a drag over rows built before", edge, 0.5),
            ("a fast drag past the edge", belowEdge, 0.3),
            ("a longer fast drag past the edge", belowEdge, 0.8),
        ]
        for (index, drag) in drags.enumerated() {
            if index > 0 {
                app.typeKey(.escape, modifierFlags: [])
                // Back to the top, where the first photo is where it was.
                for _ in 0..<40 where !backAtTheTop() {
                    scrollView.scroll(byDeltaX: 0, deltaY: 2000)
                }
                XCTAssertTrue(backAtTheTop(), "Could not scroll back to the top (first photo at \(first.element.frame.minY), was \(first.frame.minY))")
                pauseLongerThanADoubleClick()
            }
            start.click(forDuration: 0.1, thenDragTo: drag.to, withVelocity: .default, thenHoldForDuration: drag.hold)
            assertEveryPhotoOnScreenIsSelected(app, after: drag.name, moreThan: visible.count)
            // Photos the drag scrolled past are off screen now; the app's
            // report names any inside the rectangle that it did not select.
            if let folder {
                let report = URL(fileURLWithPath: folder).appending(path: "marquee-report-\(index + 1).txt")
                let deadline = Date().addingTimeInterval(10)
                while !FileManager.default.fileExists(atPath: report.path), Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.5)
                }
                let text = (try? String(contentsOf: report, encoding: .utf8)) ?? "missing marquee report"
                XCTAssertTrue(text.contains("inside the rectangle but not counted: 0\n"), "After \(drag.name): \(text.prefix(600))")
            }
        }
    }

    /// After a drag from above the first photo to the bottom edge, across
    /// every column, every photo on screen is inside the rectangle.
    private func assertEveryPhotoOnScreenIsSelected(_ app: XCUIApplication, after drag: String, moreThan minimum: Int) {
        let count = Int(selectionCount(app)) ?? 0
        XCTAssertGreaterThan(count, minimum, "\(drag) did not scroll and select")
        let onScreen = visiblePhotos(app, scanning: 600)
        XCTAssertFalse(onScreen.isEmpty)
        let missed = onScreen.filter { $0.element.value as? String != "Selected" }.map(\.element.identifier)
        if !missed.isEmpty { capture(app, named: "marquee-missed-evidence") }
        XCTAssertTrue(missed.isEmpty, "After \(drag), inside the rectangle but not selected (\(missed.count) of \(onScreen.count) on screen, \(count) selected): \(missed)")
    }

    private func exerciseMarquee(_ app: XCUIApplication, prefix: String, folder: String?) {
        let visible = visiblePhotos(app)
        guard let first = visible.first else { return XCTFail("No photo on screen") }
        // A photo in a later row and a later column, so the rectangle spans
        // rows and columns (and a section heading, if one is in between).
        guard let target = visible.first(where: { $0.frame.minY > first.frame.maxY && $0.frame.minX > first.frame.maxX })
            ?? visible.first(where: { $0.frame.minY > first.frame.maxY }) else {
            return XCTFail("Only one row of photos on screen")
        }
        // In the margin left of the first photo, just above it.
        let startPoint = CGPoint(x: first.frame.minX - 12, y: first.frame.minY - 4)
        let endPoint = CGPoint(x: target.frame.midX, y: target.frame.midY)
        let start = point(app, x: startPoint.x, y: startPoint.y)
        let band = CGRect(x: startPoint.x, y: startPoint.y, width: endPoint.x - startPoint.x, height: endPoint.y - startPoint.y)
        let expected = visible.filter { touches(band, $0.frame) }
        XCTAssertGreaterThan(expected.count, 1)

        // A plain drag selects every photo the rectangle touches, and only those.
        // The press log's line count now lets the failure messages below show
        // just the lines this drag added.
        let plainPressCount: Int = marqueePressLineCount(folder: folder)
        start.click(forDuration: 0.05, thenDragTo: point(app, x: endPoint.x, y: endPoint.y))
        let plainLog: String = marqueePressLog(folder: folder, since: plainPressCount)
        for photo in visible {
            let shouldBeSelected: Bool = expected.contains { $0.element.identifier == photo.element.identifier }
            let expectedValue: String = shouldBeSelected ? "Selected" : "Not selected"
            XCTAssertEqual(photo.element.value as? String, expectedValue, "\(photo.element.identifier) after the drag\(plainLog)")
        }
        XCTAssertEqual(selectionCount(app), String(expected.count), "The plain drag did not select \(expected.count) photos\(marqueePressLog(folder: folder, since: plainPressCount))")
        capture(app, named: "\(prefix)-01-dragged-evidence")

        // Command-drag over the first photo alone flips just that one.
        let firstCentre = point(app, x: first.frame.midX, y: first.frame.midY)
        // Far enough after the drag above that this press is not read as a
        // second click of it.
        pauseLongerThanADoubleClick()
        // The press log keeps every line for the whole run; its line count
        // says which lines this drag adds.
        let commandPressCount: Int = marqueePressLineCount(folder: folder)
        XCUIElement.perform(withKeyModifiers: .command) {
            start.click(forDuration: 0.05, thenDragTo: firstCentre)
        }
        let flipped: String? = value(of: first.element, becomes: "Not selected")
        XCTAssertEqual(flipped, "Not selected", "Command-drag did not flip the photo\(marqueePressLog(folder: folder, since: commandPressCount))")
        XCTAssertEqual(value(of: target.element, becomes: "Selected"), "Selected", "Command-drag dropped a photo it did not touch\(marqueePressLog(folder: folder, since: commandPressCount))")

        // Shift-drag adds it back and keeps the rest.
        pauseLongerThanADoubleClick()
        let shiftPressCount: Int = marqueePressLineCount(folder: folder)
        XCUIElement.perform(withKeyModifiers: .shift) {
            start.click(forDuration: 0.05, thenDragTo: firstCentre)
        }
        XCTAssertEqual(value(of: first.element, becomes: "Selected"), "Selected", "Shift-drag did not add the photo\(marqueePressLog(folder: folder, since: shiftPressCount))")
        XCTAssertEqual(selectionCount(app), String(expected.count), "Shift-drag changed the selection count\(marqueePressLog(folder: folder, since: shiftPressCount))")

        // Esc clears.
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(selectionCount(app), "0", "Esc did not clear the selection")

        // A click between photos clears too.
        start.click(forDuration: 0.05, thenDragTo: point(app, x: endPoint.x, y: endPoint.y))
        XCTAssertEqual(selectionCount(app), String(expected.count))
        pauseLongerThanADoubleClick()
        start.click()
        XCTAssertEqual(selectionCount(app), "0", "A click between photos did not clear the selection")

        // A drag that starts on a photo moves the photo; it draws no rectangle.
        firstCentre.click(forDuration: 0.2, thenDragTo: point(app, x: endPoint.x, y: endPoint.y))
        XCTAssertEqual(target.element.value as? String, "Not selected", "A drag from a photo selected like a rubber band")
        capture(app, named: "\(prefix)-02-after-photo-drag-evidence")
    }

    // MARK: Helpers

    private struct Photo {
        let element: XCUIElement
        let frame: CGRect
    }

    /// Photos fully inside the window, read before any drag so the test
    /// does not query the app while it works. The grid's built photos come
    /// in order; `limit` is how many of them to look at.
    private func visiblePhotos(_ app: XCUIApplication, scanning limit: Int = 40) -> [Photo] {
        let photos = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.photo."))
        XCTAssertTrue(photos.element(boundBy: 1).waitForExistence(timeout: launchTimeout))
        let window = app.windows.firstMatch.frame
        var visible: [Photo] = []
        for index in 0..<min(photos.count, limit) {
            let element = photos.element(boundBy: index)
            let frame = element.frame
            if window.insetBy(dx: 0, dy: 8).contains(frame), element.isHittable {
                visible.append(Photo(element: element, frame: frame))
            }
        }
        return visible
    }

    private func touches(_ rect: CGRect, _ frame: CGRect) -> Bool {
        let rect = rect.standardized
        return frame.minX <= rect.maxX && frame.maxX >= rect.minX && frame.minY <= rect.maxY && frame.maxY >= rect.minY
    }

    /// The folder CI gives the app's marquee probe (`MOMENTS_MARQUEE_DIR`),
    /// emptied first so a report from an earlier test cannot be read as this
    /// one's; nil when the test runs without it.
    private func marqueeFolder() -> String? {
        let folder: String? = ProcessInfo.processInfo.environment["MOMENTS_MARQUEE_DIR"]
            .flatMap { (value: String) -> String? in value.hasPrefix("/") ? value : nil }
        if let folder { try? FileManager.default.removeItem(atPath: folder) }
        return folder
    }

    /// How many lines `marquee-presses.txt` holds now. Read right before a
    /// drag, so that drag's failure message can show only the lines it
    /// added: the file itself keeps every line of the whole run.
    private func marqueePressLineCount(folder: String?) -> Int {
        guard let folder else { return 0 }
        let path: String = URL(fileURLWithPath: folder).appending(path: "marquee-presses.txt").path
        let lines: [String] = pressLines(atPath: path) ?? []
        return lines.count
    }

    /// The app's log of how each press decided its mode, for a failure
    /// message: only the lines added since `since`, the count read before
    /// this drag. Says so when the folder is unset or the file is missing,
    /// and says plainly when this drag added no line at all.
    private func marqueePressLog(folder: String?, since: Int) -> String {
        guard let folder else { return "\n(no MOMENTS_MARQUEE_DIR, no press log)" }
        let path: String = URL(fileURLWithPath: folder).appending(path: "marquee-presses.txt").path
        guard var lines: [String] = pressLines(atPath: path) else {
            return "\nmarquee-presses.txt: missing (no press reached begin)"
        }
        // The app writes the file on its main thread, so a line can arrive a
        // moment after the drag ends.
        let deadline: Date = Date().addingTimeInterval(1)
        while lines.count <= since, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            if let later: [String] = pressLines(atPath: path) { lines = later }
        }
        guard since < lines.count else {
            return "\nno line since this drag started: the drag never reached the marquee"
        }
        let added: [String] = Array(lines[since...])
        return "\nmarquee-presses.txt, lines since this drag started:\n\(added.joined(separator: "\n"))"
    }

    /// The lines of a press log file, or nil when it does not exist yet.
    private func pressLines(atPath path: String) -> [String]? {
        guard let text: String = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let lines: [String] = text.split(separator: "\n").map { (line: Substring) -> String in String(line) }
        return lines
    }

    /// A screen point as a coordinate in the app's window.
    private func point(_ app: XCUIApplication, x: CGFloat, y: CGFloat) -> XCUICoordinate {
        let window = app.windows.firstMatch
        let origin = window.frame.origin
        return window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x - origin.x, dy: y - origin.y))
    }

    private func selectionCount(_ app: XCUIApplication) -> String {
        let element = app.descendants(matching: .any).matching(identifier: "library.selectionCount").firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: launchTimeout))
        return element.value as? String ?? ""
    }

    private func pauseLongerThanADoubleClick() {
        RunLoop.current.run(until: Date().addingTimeInterval(NSEvent.doubleClickInterval + 0.3))
    }

    /// Waits up to `timeout` for the element's value, so a value the grid sets a
    /// moment after the drag is not read stale. Returns the last value seen.
    private func value(of element: XCUIElement, becomes expected: String, timeout: TimeInterval = 2) -> String? {
        let deadline: Date = Date().addingTimeInterval(timeout)
        var current: String? = element.value as? String
        while current != expected, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            current = element.value as? String
        }
        return current
    }

    /// `photosPerRow` comes in as a launch argument, so it neither depends on
    /// nor changes what other tests leave in the app's defaults.
    private func launch(smallWindow: Bool = false, photosPerRow: Int = 4, extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-MomentsUITesting", "-AppleLanguages", "(en)", "-AppleLocale", "en",
                               "-moments.library.photosPerRow", String(photosPerRow)] + extraArguments
        if smallWindow { app.launchArguments += ["-MomentsUITestSmallWindow"] }
        app.launch()
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: launchTimeout), "Moments is not the frontmost app")
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: launchTimeout), "Moments opened no window")
        XCTAssertTrue(window.isHittable, "The Moments window is covered or off screen")
        return app
    }

    private func capture(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
