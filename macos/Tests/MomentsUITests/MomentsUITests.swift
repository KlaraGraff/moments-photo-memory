import AppKit
import XCTest

final class MomentsUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Stop at the first failure: a test must never keep clicking once Moments
        // is not the frontmost app, or its clicks land in other apps.
        continueAfterFailure = false
    }

    private let launchTimeout: TimeInterval = 12

    func testNavigationScreenshotsEnglish() {
        let app = launch(language: "en")
        navigateAndCapture(app, prefix: "en", settleMap: true)
    }

    func testNavigationScreenshotsChinese() {
        let app = launch(language: "zh-Hans")
        navigateAndCapture(app, prefix: "zh-Hans", settleMap: true)
    }

    func testNavigationScreenshotsGermanDarkSmallWindow() {
        let app = launch(language: "de", darkMode: true, smallWindow: true)
        // The app is light only: with the Mac in Dark Mode the window must still
        // render the light paper palette, not light text on a light background.
        assertWindowRendersLight(app)
        navigateAndCapture(app, prefix: "de-dark-small", settleMap: true)
    }

    func testMemorySurvivesSidebarNavigation() {
        let app = launch(language: "en")
        let library = element(in: app, identifier: "sidebar.library")
        XCTAssertTrue(library.waitForExistence(timeout: launchTimeout))

        // Sections run newest first, so use the first visible demo photo.
        let photo = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.photo."))
            .firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: launchTimeout))
        let photoID = String(photo.identifier.dropFirst("library.photo.".count))
        photo.click()

        let memory = element(in: app, identifier: "library.memory.\(photoID)")
        XCTAssertTrue(memory.waitForExistence(timeout: launchTimeout))
        let text = "UI smoke memory \(UUID().uuidString)"
        memory.click()
        memory.typeKey("a", modifierFlags: .command)
        memory.typeText(text)

        for destination in ["sidebar.places", "sidebar.timeline", "sidebar.footprints", "sidebar.library"] {
            let item = element(in: app, identifier: destination)
            XCTAssertTrue(item.waitForExistence(timeout: launchTimeout), "Missing sidebar item \(destination)")
            item.click()
        }

        XCTAssertTrue(memory.waitForExistence(timeout: launchTimeout))
        let value = memory.value as? String ?? ""
        XCTAssertTrue(value.contains(text), "Memory field did not retain the typed text")
        capture(app, named: "library-02-memory-persisted")
    }

    func testPlacesMapHasSyntheticMarkers() {
        let app = launch(language: "en")
        element(in: app, identifier: "sidebar.places").click()

        let map = element(in: app, identifier: "places.map")
        XCTAssertTrue(map.waitForExistence(timeout: launchTimeout))
        let firstMarker = element(in: app, identifier: "places.marker.D0001")
        XCTAssertTrue(firstMarker.waitForExistence(timeout: launchTimeout), "Route-start synthetic place marker was not exposed")
        // Record where every marker and label sits, so a failure in CI says why.
        let placeElements = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "places."))
            .allElementsBoundByIndex
        let layout = placeElements.map { "\($0.identifier) \($0.elementType.rawValue) \($0.frame) hittable=\($0.isHittable)" }
        let note = XCTAttachment(string: (["map \(map.frame)"] + layout).joined(separator: "\n"))
        note.name = "places-layout"
        note.lifetime = .keepAlways
        add(note)
        XCTAssertGreaterThanOrEqual(firstMarker.frame.width, 16, "Route-start marker is too narrow to be visible")
        XCTAssertGreaterThanOrEqual(firstMarker.frame.height, 16, "Route-start marker is too short to be visible")
        XCTAssertTrue(map.frame.contains(firstMarker.frame), "Route-start marker is outside the Places map")
        XCTAssertTrue(firstMarker.isHittable, "Route-start marker is not hittable")
        let marker = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "places.marker."))
            .firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: launchTimeout), "Synthetic place marker was not exposed")
        capture(app, named: "places-01-map-and-pin")
    }

    func testPlacesPanelIsCompactAndCloses() {
        let app = launch(language: "en")
        element(in: app, identifier: "sidebar.places").click()
        let map = element(in: app, identifier: "places.map")
        XCTAssertTrue(map.waitForExistence(timeout: launchTimeout))
        let marker = element(in: app, identifier: "places.marker.D0001")
        XCTAssertTrue(marker.waitForExistence(timeout: launchTimeout))
        marker.click()

        let panel = element(in: app, identifier: "places.panel")
        XCTAssertTrue(panel.waitForExistence(timeout: launchTimeout), "Clicking a place did not open its photo panel")
        Thread.sleep(forTimeInterval: 1.0)
        capture(app, named: "places-02-panel-open-evidence")
        let title = element(in: app, identifier: "places.panel.title")
        let titleText = (title.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? title.label
        log("places panel \(panel.frame) map \(map.frame) title '\(titleText)'")
        XCTAssertLessThan(panel.frame.height, map.frame.height * 0.45, "The photo panel covers most of the map (panel \(panel.frame), map \(map.frame))")
        XCTAssertGreaterThan(panel.frame.minY, map.frame.midY, "The photo panel should sit at the bottom of the map")

        element(in: app, identifier: "places.panel.close").click()
        XCTAssertTrue(panel.waitForNonExistence(timeout: launchTimeout), "The close button did not close the photo panel")

        marker.click()
        XCTAssertTrue(panel.waitForExistence(timeout: launchTimeout))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(panel.waitForNonExistence(timeout: launchTimeout), "Escape did not close the photo panel")
        capture(app, named: "places-03-panel-closed")
    }

    func testFootprintsGlobeOpens() {
        let app = launch(language: "en")
        assertGlobeFullyVisible(app, screenshot: "footprints-01-globe-evidence")
    }

    func testFootprintsGlobeFitsSmallWindow() {
        let app = launch(language: "en", smallWindow: true)
        assertGlobeFullyVisible(app, screenshot: "footprints-02-globe-small-window-evidence")
    }

    /// The globe sits on black space: scan the middle row and column of the
    /// map for the first and last bright pixels. A cropped globe touches the
    /// map's edges.
    private func assertGlobeFullyVisible(_ app: XCUIApplication, screenshot name: String, file: StaticString = #filePath, line: UInt = #line) {
        let footprints = element(in: app, identifier: "sidebar.footprints")
        XCTAssertTrue(footprints.waitForExistence(timeout: launchTimeout), file: file, line: line)
        footprints.click()

        // The first MapKit globe of a test run can take longer to appear.
        let globe = element(in: app, identifier: "footprints.globe")
        XCTAssertTrue(globe.waitForExistence(timeout: 30), file: file, line: line)
        Thread.sleep(forTimeInterval: 3.0)
        capture(app, named: name)

        guard let cgImage = globe.screenshot().image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            XCTFail("Could not read the globe screenshot", file: file, line: line)
            return
        }
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        func luminance(_ x: Int, _ y: Int) -> Double {
            let index = (y * width + x) * 4
            return (0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1]) + 0.0722 * Double(pixels[index + 2])) / 255
        }
        let threshold = 0.08
        // Ignore the compass and scale overlays near the corners: scan the middle third.
        let row = height / 2
        let column = width / 2
        // Stars are single bright pixels; the globe is a run of them.
        func runs(_ count: Int, _ value: (Int) -> Double) -> [Int] {
            (0..<count).filter { start in
                start + 4 <= count && (start..<start + 4).allSatisfy { value($0) > threshold }
            }
        }
        let bright = runs(width) { luminance($0, row) }.flatMap { [$0, $0 + 3] }
        let brightRows = runs(height) { luminance(column, $0) }.flatMap { [$0, $0 + 3] }
        let samples = [0.0, 0.25, 0.5, 0.75, 1.0].map { fraction -> String in
            let x = min(width - 1, Int(Double(width - 1) * fraction))
            return String(format: "%.2f", luminance(x, row))
        }
        log("\(name) globe \(globe.frame) px \(width)x\(height) row x=\(bright.first ?? -1)...\(bright.last ?? -1) column y=\(brightRows.first ?? -1)...\(brightRows.last ?? -1) row samples \(samples)")
        guard let left = bright.first, let right = bright.last, let top = brightRows.first, let bottom = brightRows.last else {
            XCTFail("The globe did not render", file: file, line: line)
            return
        }
        let marginX = max(2, width / 100)
        let marginY = max(2, height / 100)
        XCTAssertGreaterThan(left, marginX, "The globe is cut off on the left", file: file, line: line)
        XCTAssertLessThan(right, width - 1 - marginX, "The globe is cut off on the right", file: file, line: line)
        XCTAssertGreaterThan(top, marginY, "The globe is cut off at the top", file: file, line: line)
        XCTAssertLessThan(bottom, height - 1 - marginY, "The globe is cut off at the bottom", file: file, line: line)
        // A globe pushed sideways (the map drawing under the sidebar) is off centre.
        let centreOffset = abs(Double(left + right) / 2 - Double(width) / 2)
        XCTAssertLessThan(centreOffset, Double(width) * 0.08, "The globe is not centred in the map (offset \(centreOffset) px)", file: file, line: line)
    }

    private func log(_ message: String) {
        print("MOMENTS-UI \(message)")
        let note = XCTAttachment(string: message)
        note.name = "note"
        note.lifetime = .keepAlways
        add(note)
    }

    func testTimelinePlaceSelectsLibraryItem() {
        let app = launch(language: "en")
        element(in: app, identifier: "sidebar.timeline").click()

        let place = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "timeline.place.")).firstMatch
        XCTAssertTrue(place.waitForExistence(timeout: launchTimeout), "Timeline place row was not exposed")
        place.click()

        let selectedPhoto = element(in: app, identifier: "library.photo.D0001")
        XCTAssertTrue(selectedPhoto.waitForExistence(timeout: launchTimeout))
        XCTAssertEqual(selectedPhoto.value as? String, "Selected")
        XCTAssertTrue(selectedPhoto.isHittable, "Timeline jump should scroll the selected Library card into view")
        // A sliver at the edge counts as hittable; the whole card must be visible
        // below the filter bar and inside the window.
        let window = app.windows.firstMatch.frame
        let filterBar = element(in: app, identifier: "library.add-filter")
        let visibleTop = filterBar.exists ? filterBar.frame.maxY : window.minY
        let card = selectedPhoto.frame
        XCTAssertGreaterThanOrEqual(card.minY, visibleTop - 1, "The selected card is cut off at the top (card \(card), visible top \(visibleTop))")
        XCTAssertLessThanOrEqual(card.maxY, window.maxY + 1, "The selected card is cut off at the bottom (card \(card), window \(window))")
        capture(app, named: "timeline-01-place-selected-in-library")
    }

    /// Diagnostics for the jump maple sees when clicking the sidebar: the app
    /// logs every geometry change after each click; CI prints the log.
    func testSidebarClicksLayoutProbe() {
        let app = XCUIApplication()
        // A real Dark Mode Mac (maple's) rather than the NSApp.appearance stand-in.
        app.launchArguments = ["-MomentsUITesting", "-MomentsUITestLayoutProbe", "-AppleInterfaceStyle", "Dark", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh-Hans"]
        app.launch()
        app.activate()
        requireFrontmostWindow(app)
        // Scroll the Library down first so returning to it has a position to restore.
        let photo = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.photo."))
            .firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: launchTimeout))
        photo.scroll(byDeltaX: 0, deltaY: -400)
        Thread.sleep(forTimeInterval: 1.0)
        let order = ["review", "places", "footprints", "timeline", "library", "review", "library", "places", "library"]
        for name in order {
            let item = element(in: app, identifier: "sidebar.\(name)")
            XCTAssertTrue(item.waitForExistence(timeout: launchTimeout), "Missing sidebar item \(name)")
            item.click()
            Thread.sleep(forTimeInterval: 1.5)
        }
        // Clicks inside the Library and inside the Settings window.
        photo.click()
        Thread.sleep(forTimeInterval: 1.5)
        app.windows.firstMatch.click()
        Thread.sleep(forTimeInterval: 1.5)
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.element(boundBy: 0)
        XCTAssertTrue(settings.waitForExistence(timeout: launchTimeout))
        Thread.sleep(forTimeInterval: 1.5)
        settings.click()
        Thread.sleep(forTimeInterval: 1.5)
        settings.click()
        Thread.sleep(forTimeInterval: 1.5)
        capture(app, named: "layout-probe-final-evidence")
    }

    private func navigateAndCapture(_ app: XCUIApplication, prefix: String, settleMap: Bool) {
        let library = element(in: app, identifier: "sidebar.library")
        XCTAssertTrue(library.waitForExistence(timeout: launchTimeout))
        capture(app, named: "\(prefix)-01-library-evidence")

        let places = element(in: app, identifier: "sidebar.places")
        XCTAssertTrue(places.waitForExistence(timeout: launchTimeout))
        places.click()
        XCTAssertTrue(element(in: app, identifier: "places.map").waitForExistence(timeout: launchTimeout))
        if settleMap { Thread.sleep(forTimeInterval: 1.0) }
        capture(app, named: "\(prefix)-02-places")

        let footprints = element(in: app, identifier: "sidebar.footprints")
        XCTAssertTrue(footprints.waitForExistence(timeout: launchTimeout))
        footprints.click()
        XCTAssertTrue(element(in: app, identifier: "footprints.globe").waitForExistence(timeout: launchTimeout))
        if settleMap { Thread.sleep(forTimeInterval: 1.0) }
        capture(app, named: "\(prefix)-03-footprints")

        let timeline = element(in: app, identifier: "sidebar.timeline")
        XCTAssertTrue(timeline.waitForExistence(timeout: launchTimeout))
        timeline.click()
        // Locale-independent: a timeline place row proves the screen rendered.
        let placeRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "timeline.place."))
            .firstMatch
        XCTAssertTrue(placeRow.waitForExistence(timeout: launchTimeout))
        capture(app, named: "\(prefix)-04-timeline")
    }

    private func launch(language: String, darkMode: Bool = false, smallWindow: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-MomentsUITesting", "-AppleLanguages", "(\(language))", "-AppleLocale", language]
        if darkMode { app.launchArguments += ["-MomentsUITestDarkMode"] }
        if smallWindow { app.launchArguments += ["-MomentsUITestSmallWindow"] }
        // No window-state arguments: with -MomentsUITesting, both
        // -ApplePersistenceIgnoreState and -NSQuitAlwaysKeepsWindows left
        // SwiftUI's WindowGroup without its initial window on CI.
        app.launch()
        app.activate()
        requireFrontmostWindow(app)
        return app
    }

    /// Fails the test (and, with continueAfterFailure off, stops it) unless
    /// Moments is the frontmost app with a hittable window.
    private func requireFrontmostWindow(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: launchTimeout), "Moments is not the frontmost app", file: file, line: line)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: launchTimeout), "Moments opened no window", file: file, line: line)
        XCTAssertTrue(window.isHittable, "The Moments window is covered or off screen", file: file, line: line)
    }

    private func assertWindowRendersLight(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let image = app.windows.firstMatch.screenshot().image
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            XCTFail("Could not read the window screenshot", file: file, line: line)
            return
        }
        // Average luminance on a 32x32 downsample; the light paper design sits well above 0.6.
        let size = 32
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let context = CGContext(data: &pixels, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
        var total = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            total += 0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1]) + 0.0722 * Double(pixels[index + 2])
        }
        let luminance = total / Double(size * size) / 255
        XCTAssertGreaterThan(luminance, 0.6, "The window rendered dark (luminance \(luminance)) while the app is light only", file: file, line: line)
    }

    private func element(in app: XCUIApplication, identifier: String) -> XCUIElement {
        XCTAssertEqual(app.state, .runningForeground, "Moments lost focus; stopping before clicking another app")
        return app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func capture(_ app: XCUIApplication, named name: String) {
        // Capture only the app window, never the rest of the desktop.
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
